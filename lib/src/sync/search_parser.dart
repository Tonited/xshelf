/// 把 X `SearchTimeline` 的响应解析成「一页搜索结果」。
///
/// 为什么不复用 [parseLikesPage]：两者的 data 根不同
/// （搜索是 `data.search_by_raw_query.search_timeline`，喜欢是 `data.user.result`），
/// 而且搜索结果里混着广告条目、People 标签页的用户条目、线程模块 —— 这些都得
/// 挑出来丢掉。但**推文节点本身**和 Likes 一模一样，所以推文解析一律复用
/// [parseTweetNode]，绝不复制第二份（复制了迟早只改一边）。
///
/// 搜索的语法、限流、queryId 候选见 [XClient.fetchSearch] 与 docs/GRAPHQL.md。
library;

import 'dart:isolate';

import '../model/like_item.dart';
import 'likes_parser.dart';

/// 在**后台 isolate** 里解析一页搜索结果（理由同 [parseLikesPageInBackground]）。
Future<SearchResultPage> parseSearchPageInBackground(Object? json) =>
    Isolate.run(() => parseSearchPage(json));

class SearchParseException implements Exception {
  SearchParseException(this.message);
  final String message;
  @override
  String toString() => 'SearchParseException: $message';
}

/// 搜索结果的标签页。取值就是线上 `product` 变量的字面量，
/// 所以这里显式存 wire 值而不是靠 `name` 推断大小写。
enum SearchProduct {
  top('Top'),
  latest('Latest'),
  media('Media'),
  people('People');

  const SearchProduct(this.wireName);
  final String wireName;
}

/// 一条搜索结果：既有的 [LikeItem] + 只有搜索才有的东西。
///
/// 为什么不直接给 [LikeItem] 加字段：`LikeItem` 是**本地喜欢库**的行模型，
/// 带 `feedRank`/`randKey`/`state` 这些「我喜欢过它」的语义。搜索结果是临时视图，
/// 混进去会让 DB 层和 UI 层都开始猜每个字段在两种场景下的含义。组合优于继承。
class SearchHit {
  const SearchHit({
    required this.item,
    this.highlights = const [],
    this.alreadyLiked = false,
    this.favoriteCount,
    this.retweetCount,
    this.replyCount,
  });

  final LikeItem item;

  /// 命中词在 `item.text` 里的区间（UTF-16 偏移）。
  ///
  /// 直接用 X 算好的 `highlights.textHighlights`：自己再匹配一遍会和它的分词/
  /// 同义词规则打架，表现为「高亮了错的位置」。
  final List<({int start, int end})> highlights;

  /// `legacy.favorited`：**请求时刻**的快照。只用来标个「已在喜欢里」，
  /// 不要拿它改本地库（用户可能刚在别处取消/添加）。
  final bool alreadyLiked;
  final int? favoriteCount;
  final int? retweetCount;
  final int? replyCount;
}

class SearchResultPage {
  SearchResultPage({
    required this.items,
    this.topCursor,
    this.bottomCursor,
    this.entryCount = 0,
    this.errors = const [],
    this.terminated = false,
  });

  final List<SearchHit> items;
  final String? topCursor;
  final String? bottomCursor;
  final int entryCount;

  /// X 在 200 里夹带的非致命 errors（部分内容被屏蔽之类），留着给 UI 做轻提示。
  final List<String> errors;

  /// 服务端是否明确说了「下面没有了」。
  final bool terminated;

  /// 搜索的 bottom 游标**翻到最后一页也可能继续返回非空值**（服务端用它标记
  /// 时间线位置，而不是「还有没有」）。所以上层不能只靠这个判断结束，
  /// 还要看本页是否真的解析出了新条目，或者 [terminated]。
  bool get hasMore => bottomCursor != null && bottomCursor!.isNotEmpty;

  int get hitCount => items.length;
}

/// 解析一页搜索结果（同步版，测试用）。
SearchResultPage parseSearchPage(Object? json) {
  if (json is! Map) throw SearchParseException('响应不是 JSON 对象');

  final errors = graphqlErrors(json);
  final data = json['data'];
  if (data is! Map) {
    // 200 且只有 errors：查询语法被拒（code 220 之类）或 queryId/features 失效，
    // 两者都可能，交给上层按 message 决定「提示改查询」还是「重新发现 queryId」。
    throw SearchParseException(
        errors.isEmpty ? '响应缺少 data 字段' : errors.join('; '));
  }

  final root = _dig(data, ['search_by_raw_query', 'search_timeline']);
  if (root is! Map) {
    // 搜索词被整体拒绝 / 被风控时 X 会返回 `search_by_raw_query: null`，
    // 而不是 errors —— 这种情况比「接口变了」常见得多，提示要说人话。
    throw SearchParseException(
        '响应缺少 data.search_by_raw_query.search_timeline（搜索词被拒或 queryId 失效）');
  }

  final instructions = _instructions(root);
  if (instructions == null) {
    throw SearchParseException('响应缺少 timeline.instructions（接口可能已变更）');
  }

  final hits = <SearchHit>[];
  final seen = <String>{}; // 线程模块里同一条推文可能重复出现，按 id 去重
  var entryCount = 0;
  String? topCursor;
  String? bottomCursor;
  var terminated = false;

  for (final ins in instructions) {
    if (ins is! Map) continue;
    if (ins['type'] == 'TimelineTerminateTimeline') {
      // 搜索结果里 terminate 是可信的「没有更多了」，但和 Likes 一样：
      // **不能**丢掉同一页里已经解析到的 Bottom 游标（那样会让上层以为
      // 第一页就到底了）。用标志表达，游标照旧。
      terminated = true;
      continue;
    }
    final entries = ins['entries'];
    if (entries is! List) continue;

    for (final entry in entries) {
      if (entry is! Map) continue;
      entryCount++;
      final entryId = entry['entryId'] as String? ?? '';

      // 广告条目：X 用 `promoted-tweet-<id>` 这类 entryId。里面的推文不是搜索结果，
      // 混进列表会让人以为「搜出来一条莫名其妙的广告」。
      if (entryId.startsWith('promoted-')) continue;

      final content = entry['content'];
      if (content is! Map) continue;

      switch (content['entryType']) {
        case 'TimelineTimelineCursor':
          final value = content['value'] as String?;
          if (value == null || value.isEmpty) break;
          // 搜索里还有 ShowMore / ShowMoreThreads 之类游标，只认上下页这两个。
          final direction = content['cursorType'] as String? ??
              (entryId.startsWith('cursor-top') ? 'Top' : 'Bottom');
          if (direction == 'Top') {
            topCursor ??= value;
          } else if (direction == 'Bottom') {
            bottomCursor = value;
          }
        case 'TimelineTimelineItem':
          _collectTweet(content['itemContent'], entryId, hits, seen);
        case 'TimelineTimelineModule':
          // 线程模块：老响应用 `items`，新响应用 `moduleItems`，两个都试
          // （和 `_timelineInstructions` 三种形态都试是同一个理由）。
          final moduleItems =
              (content['items'] as List?) ?? (content['moduleItems'] as List?);
          if (moduleItems is List) {
            for (final it in moduleItems) {
              if (it is! Map) continue;
              final item = it['item'];
              if (item is! Map) continue;
              _collectTweet(item['itemContent'], entryId, hits, seen);
            }
          }
        default:
          // TimelineReplaceEntry / who-to-follow / messageprompt 等：忽略。
          break;
      }
    }
  }

  return SearchResultPage(
    items: hits,
    topCursor: topCursor,
    bottomCursor: bottomCursor,
    entryCount: entryCount,
    errors: errors,
    terminated: terminated,
  );
}

/// 从 `itemContent` 抠一条推文（不是推文就静默跳过）。
void _collectTweet(
  Object? itemContent,
  String entryId,
  List<SearchHit> out,
  Set<String> seen,
) {
  if (itemContent is! Map) return;

  // People 标签页返回的是 `TimelineUser`；这里只关心推文。
  if (itemContent['itemType'] != 'TimelineTweet') return;

  // 广告推文也走 TimelineTweet，但多带 promotedMetadata —— 和 entryId 前缀双保险。
  if (itemContent['promotedMetadata'] != null) return;

  final result = _dig(itemContent, ['tweet_results', 'result']);
  if (result is! Map) return;

  final typename = result['__typename'] as String?;

  // 搜索里的 tombstone 意思是「内容不可见」（受保护/已删/被限流），
  // 不是 Likes 那种「我取消喜欢了」。所以直接丢弃，不要进 deletedTweetIds。
  if (typename == 'TweetTombstone') return;

  final tweet = typename == 'TweetWithVisibilityResults'
      ? (result['tweet'] as Map?)
      : result;
  if (tweet == null) return;

  // ← 关键复用点：推文节点结构与 Likes 完全一致，一行都不重写。
  final item = parseTweetNode(tweet, entryId: entryId);
  if (item == null || !seen.add(item.tweetId)) return;

  final legacy = tweet['legacy'] is Map ? tweet['legacy'] as Map : const {};
  out.add(SearchHit(
    item: item,
    highlights: _highlights(itemContent),
    alreadyLiked: legacy['favorited'] == true,
    favoriteCount: (legacy['favorite_count'] as num?)?.toInt(),
    retweetCount: (legacy['retweet_count'] as num?)?.toInt(),
    replyCount: (legacy['reply_count'] as num?)?.toInt(),
  ));
}

List<({int start, int end})> _highlights(Map itemContent) {
  final raw = _dig(itemContent, ['highlights', 'textHighlights']);
  if (raw is! List) return const [];
  final out = <({int start, int end})>[];
  for (final h in raw) {
    if (h is! Map) continue;
    final s = (h['startIndex'] as num?)?.toInt();
    final e = (h['endIndex'] as num?)?.toInt();
    if (s == null || e == null || e <= s || s < 0) continue;
    out.add((start: s, end: e));
  }
  return out;
}

/// [root] 即 `data.search_by_raw_query.search_timeline`。
///
/// 搜索这边实测是 `timeline.instructions`；另外两种形态（多一层 `timeline`、
/// 旧的 `timeline_v2`）都试一遍 —— 和 likes_parser 保持同样保守。
List? _instructions(Map root) {
  final candidates = [
    _dig(root, ['timeline', 'instructions']),
    _dig(root, ['timeline', 'timeline', 'instructions']),
    _dig(root, ['timeline_v2', 'timeline', 'instructions']),
  ];
  for (final c in candidates) {
    if (c is List) return c;
  }
  return null;
}

Object? _dig(Object? root, List<String> path) {
  Object? cur = root;
  for (final key in path) {
    if (cur is Map) {
      cur = cur[key];
    } else {
      return null;
    }
  }
  return cur;
}

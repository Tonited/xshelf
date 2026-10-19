/// 把 X `Likes` 接口的响应解析成领域模型。
///
/// 响应结构见 `docs/GRAPHQL.md`。这里刻意不抛异常吞掉一切：
/// 结构对不上时抛 [LikesParseException]，让上层能区分「接口变了」和「没有更多数据」。
library;

import 'dart:isolate';

import '../model/like_item.dart';
import 'twitter_date.dart';

class LikesParseException implements Exception {
  LikesParseException(this.message);
  final String message;
  @override
  String toString() => 'LikesParseException: $message';
}

class LikesPage {
  LikesPage({
    required this.items,
    this.topCursor,
    this.bottomCursor,
    this.deletedTweetIds = const [],
    this.entryCount = 0,
    this.terminatedBottom = false,
    this.instructionTypes = const [],
  });

  final List<LikeItem> items;
  final String? topCursor;
  final String? bottomCursor;

  /// 已删除（tombstone）的推文 id：本地应保留记录但标记为 deleted。
  final List<String> deletedTweetIds;
  final int entryCount;

  /// 服务端是否明确说「下面没有了」。
  ///
  /// 这个标志和 [bottomCursor] 是两件事：真实响应里出现过「既有 Bottom 游标、
  /// 又有 TimelineTerminateTimeline」的页，早期版本据此把游标置空，回填于是在
  /// 1000 条左右被误判成全量完成，并且把续传游标也清掉了。
  final bool terminatedBottom;

  /// 诊断用：本页出现过的 instruction 类型（排查「接口变了」时很有用）。
  final List<String> instructionTypes;

  bool get hasMore => bottomCursor != null && bottomCursor!.isNotEmpty;
}

/// X 在 `errors` 里返回的错误信息，供上层展示。
List<String> graphqlErrors(Object? json) {
  if (json is! Map) return const [];
  final errors = json['errors'];
  if (errors is! List) return const [];
  return [
    for (final e in errors)
      if (e is Map) (e['message']?.toString() ?? e.toString()),
  ];
}

/// 在**后台 isolate** 里解析一页喜欢。
///
/// 一页 100 条喜欢的响应有几百 KB 到几 MB，`jsonDecode` + 遍历在 UI 线程上要
/// 几十上百毫秒 —— 回填时列表正在滚动，这几十毫秒就是一次肉眼可见的卡顿。
/// 解析只依赖入参、产出的又都是纯 Dart 对象，天然适合丢到后台线程。
Future<LikesPage> parseLikesPageInBackground(Object? json) =>
    Isolate.run(() => parseLikesPage(json));

LikesPage parseLikesPage(Object? json) {
  if (json is! Map) throw LikesParseException('响应不是 JSON 对象');

  final errors = graphqlErrors(json);
  if (errors.isNotEmpty && json['data'] == null) {
    throw LikesParseException(errors.join('; '));
  }

  final data = json['data'];
  if (data is! Map) throw LikesParseException('响应缺少 data 字段');

  final user = _dig(data, ['user', 'result']);
  if (user is! Map) throw LikesParseException('响应缺少 data.user.result');

  final instructions = _timelineInstructions(user);
  if (instructions == null) {
    throw LikesParseException('响应缺少 timeline.instructions（接口可能已变更）');
  }

  final items = <LikeItem>[];
  final deleted = <String>[];
  String? topCursor;
  String? bottomCursor;
  var entryCount = 0;
  var terminatedBottom = false;
  final instructionTypes = <String>[];

  for (final ins in instructions) {
    if (ins is! Map) continue;
    final type = ins['type'];
    instructionTypes.add(type is String ? type : '$type');
    if (type == 'TimelineTerminateTimeline') {
      // 不能在这里把 bottomCursor 置空 —— 真实响应里存在「同一页既有 Bottom
      // 游标、又有 terminate 指令」的情况，置空会让上层误判成「全量抓完了」
      // 并且清掉续传游标（历史 bug：喜欢永远停在 1000 条左右）。
      // 只记录标志，游标一律以实际解析到的为准。
      final dir = ins['direction'] as String?;
      if (dir == null || dir == 'Bottom') terminatedBottom = true;
      continue;
    }
    final entries = ins['entries'];
    if (entries is! List) continue;

    for (final entry in entries) {
      if (entry is! Map) continue;
      entryCount++;
      final entryId = entry['entryId'] as String? ?? '';
      final content = entry['content'];
      if (content is! Map) continue;

      switch (content['entryType']) {
        case 'TimelineTimelineCursor':
          final value = content['value'] as String?;
          if (value == null || value.isEmpty) break;
          final direction = content['cursorType'] as String? ??
              (entryId.startsWith('cursor-top') ? 'Top' : 'Bottom');
          if (direction == 'Top') {
            topCursor ??= value;
          } else {
            bottomCursor = value;
          }
        case 'TimelineTimelineItem':
          final itemContent = content['itemContent'];
          if (itemContent is! Map) break;
          final result = _dig(itemContent, ['tweet_results', 'result']);
          if (result is! Map) break;

          final typename = result['__typename'] as String?;
          if (typename == 'TweetTombstone') {
            final id = _tweetIdFromEntryId(entryId);
            if (id != null) deleted.add(id);
            break;
          }

          final tweet = typename == 'TweetWithVisibilityResults'
              ? (result['tweet'] as Map?)
              : result;
          if (tweet == null) break;

          final item = _parseTweet(tweet, entryId);
          if (item != null) items.add(item);
        default:
          // TimelineTimelineModule / TimelineReplaceEntry 等：忽略。
          break;
      }
    }
  }

  return LikesPage(
    items: items,
    topCursor: topCursor,
    bottomCursor: bottomCursor,
    deletedTweetIds: deleted,
    entryCount: entryCount,
    terminatedBottom: terminatedBottom,
    instructionTypes: instructionTypes,
  );
}

/// [result] 即 `data.user.result`（已解包一层）。
///
/// 2026-10 实测的 Likes 响应里，指令挂在 `user.timeline.timeline.instructions`
/// （多了一层 `timeline`，且不再有 `timeline_v2`）。三种形态都试一遍，
/// 免得 X 改一次就得跟着改。
List? _timelineInstructions(Map result) {
  final candidates = [
    _dig(result, ['timeline', 'timeline', 'instructions']),
    _dig(result, ['timeline_v2', 'timeline', 'instructions']),
    _dig(result, ['timeline', 'instructions']),
  ];
  for (final c in candidates) {
    if (c is List) return c;
  }
  return null;
}

/// 供 `SearchTimeline`（以及将来的 `UserTweets` / `TweetDetail`）复用的推文解析入口。
///
/// 为什么只开一个包装而不直接改名：`_parseTweet` 是 Likes 的私有实现，直接对外
/// 会把「Likes 的解析细节」变成公共契约；而复制第二份的代价更糟 —— 两个模块
/// 迟早只改一边（改成只支持一种媒体结构之类）。包装一层，语义就此固定。
LikeItem? parseTweetNode(Map tweet, {String? entryId}) =>
    _parseTweet(tweet, entryId ?? '');

LikeItem? _parseTweet(Map tweet, String entryId) {
  final tweetId = (tweet['rest_id'] as String?) ?? _tweetIdFromEntryId(entryId);
  if (tweetId == null || tweetId.isEmpty) return null;

  final legacy = tweet['legacy'];
  final legacyMap = legacy is Map ? legacy : const {};

  var text = '';
  final noteText = _dig(tweet, [
    'note_tweet',
    'note_tweet_results',
    'result',
    'text',
  ]);
  if (noteText is String && noteText.isNotEmpty) {
    text = noteText;
  } else {
    text = legacyMap['full_text'] as String? ?? '';
  }

  return LikeItem(
    tweetId: tweetId,
    text: text,
    createdAt: parseTwitterDate(legacyMap['created_at'] as String?),
    lang: legacyMap['lang'] as String?,
    author: _parseAuthor(tweet),
    media: _parseMedia(legacyMap),
    sensitive: legacyMap['possibly_sensitive'] == true,
    replyTo: legacyMap['in_reply_to_status_id_str'] as String?,
    quoteOf: _dig(legacyMap, ['quoted_status_result', 'result', 'rest_id'])
        as String?,
    retweetOf:
        _dig(legacyMap, ['retweeted_status_result', 'result', 'rest_id'])
            as String?,
    raw: Map<String, Object?>.from(tweet),
  );
}

Author? _parseAuthor(Map tweet) {
  final user = _dig(tweet, ['core', 'user_results', 'result']);
  if (user is! Map) return null;
  final userLegacy = user['legacy'] is Map ? user['legacy'] as Map : const {};
  final id = user['rest_id'] as String? ?? '';
  if (id.isEmpty) return null;
  final screenName = _dig(user, ['core', 'screen_name']) as String? ??
      userLegacy['screen_name'] as String? ??
      '';
  final name = _dig(user, ['core', 'name']) as String? ??
      userLegacy['name'] as String? ??
      '';
  var avatar = _dig(user, ['avatar', 'image_url']) as String? ??
      userLegacy['profile_image_url_https'] as String?;
  if (avatar != null) avatar = avatar.replaceAll('_normal', '_bigger');
  return Author(
    id: id,
    screenName: screenName,
    name: name,
    avatarUrl: avatar,
  );
}

List<MediaItem> _parseMedia(Map legacy) {
  final rawMedia = _dig(legacy, ['extended_entities', 'media']) ??
      _dig(legacy, ['entities', 'media']);
  if (rawMedia is! List) return const [];

  final out = <MediaItem>[];
  for (final raw in rawMedia) {
    if (raw is! Map) continue;
    final type = raw['type'] as String? ?? 'photo';
    final url = raw['media_url_https'] as String?;
    if (url == null) continue;
    final info = raw['original_info'] is Map ? raw['original_info'] as Map : const {};
    final alt = raw['ext_alt_text'] as String?;

    if (type == 'photo') {
      out.add(MediaItem(
        kind: MediaKind.image,
        url: _imageVariant(url, 'large'),
        width: (info['width'] as num?)?.toInt(),
        height: (info['height'] as num?)?.toInt(),
        altText: alt,
      ));
      continue;
    }

    final videoInfo = raw['video_info'] is Map ? raw['video_info'] as Map : const {};
    final variants = <MediaVariant>[];
    final rawVariants = videoInfo['variants'];
    if (rawVariants is List) {
      for (final v in rawVariants) {
        if (v is! Map) continue;
        final vUrl = v['url'] as String?;
        if (vUrl == null || vUrl.isEmpty) continue;
        variants.add(MediaVariant(
          url: vUrl,
          contentType: v['content_type'] as String? ?? '',
          bitRate: (v['bit_rate'] as num?)?.toInt(),
        ));
      }
    }

    out.add(MediaItem(
      kind: type == 'animated_gif' ? MediaKind.gif : MediaKind.video,
      url: _imageVariant(url, 'large'),
      variants: variants,
      width: (info['width'] as num?)?.toInt(),
      height: (info['height'] as num?)?.toInt(),
      durationMs: (videoInfo['duration_millis'] as num?)?.toInt(),
      altText: alt,
    ));
  }
  return out;
}

String _imageVariant(String base, String name) {
  final clean = base.split('?').first;
  return '$clean?name=$name';
}

String? _tweetIdFromEntryId(String entryId) {
  if (entryId.startsWith('tweet-')) return entryId.substring(6);
  final m = RegExp(r'(\d{10,})').firstMatch(entryId);
  return m?.group(1);
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

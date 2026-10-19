/// 搜索模块的单测：`XSearchQuery`（查询串拼装）+ `parseSearchPage`（结果解析）。
///
/// 为什么单独一个文件：搜索这两个部件都是**纯 Dart、无 IO**，是最该被钉住的一层。
/// 它们出错时的表现都极其隐蔽 —— X 对写错的查询语法不报错、只会返回不相干的结果；
/// 解析层漏掉一条广告/线程重复项，用户只会觉得「搜出来的东西怪怪的」。
/// 所以这里的断言都写成**具体的最终值**（整串查询、id 列表），
/// 而不是「没抛异常」这种测了等于没测的东西。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:xlikemanage/src/sync/search_parser.dart';
import 'package:xlikemanage/src/sync/search_query.dart';

// ---------------------------------------------------------------------------
// 构造响应 JSON 的助手。字段名一律按线上响应写（不是按模型字段写）：
// 哪天 X 挪了字段，这些助手和被测代码之间的差异才会暴露出来。
// ---------------------------------------------------------------------------

/// 一条推文节点（即 `tweet_results.result`）。
///
/// 结构对齐 `likes_parser.parseTweetNode` 的实际所需：
/// `rest_id`、`core.user_results.result.core.screen_name|name`、
/// `legacy.full_text|created_at|favorite_count|retweet_count|reply_count|favorited`、
/// `legacy.extended_entities.media`。
Map<String, Object?> _tweet({
  required String id,
  String text = 'hello world',
  String screenName = 'alice',
  String name = 'Alice',
  String? createdAt = 'Wed Oct 10 20:19:24 +0000 2018',
  int favoriteCount = 12,
  int retweetCount = 3,
  int replyCount = 1,
  bool favorited = false,
  List<Map<String, Object?>> media = const [],
}) =>
    {
      'rest_id': id,
      '__typename': 'Tweet',
      'core': {
        'user_results': {
          'result': {
            'rest_id': 'u-$screenName',
            'core': {'screen_name': screenName, 'name': name},
            'legacy': {
              'profile_image_url_https': 'https://pbs.twimg.com/$screenName.jpg',
            },
          },
        },
      },
      'legacy': {
        'full_text': text,
        'created_at': createdAt,
        'favorite_count': favoriteCount,
        'retweet_count': retweetCount,
        'reply_count': replyCount,
        'favorited': favorited,
        if (media.isNotEmpty) 'extended_entities': {'media': media},
      },
    };

/// 一条照片媒体（`legacy.extended_entities.media` 的元素）。
Map<String, Object?> _photo(String url) => {
      'type': 'photo',
      'media_url_https': url,
      'original_info': {'width': 1200, 'height': 800},
    };

/// 一个 `TimelineTimelineItem` 条目（普通推文）。
Map<String, Object?> _tweetEntry(String entryId, Map<String, Object?> result) => {
      'entryId': entryId,
      'content': {
        'entryType': 'TimelineTimelineItem',
        'itemContent': {
          'itemType': 'TimelineTweet',
          'tweet_results': {'result': result},
        },
      },
    };

/// 一个自定义 `itemContent` 的条目（用来塞 People 用户条目、广告标记、highlights）。
Map<String, Object?> _rawEntry(
  String entryId,
  Map<String, Object?> itemContent,
) =>
    {
      'entryId': entryId,
      'content': {
        'entryType': 'TimelineTimelineItem',
        'itemContent': itemContent,
      },
    };

/// 一个游标条目。
Map<String, Object?> _cursorEntry(
  String entryId,
  String cursorType,
  String value,
) =>
    {
      'entryId': entryId,
      'content': {
        'entryType': 'TimelineTimelineCursor',
        'cursorType': cursorType,
        'value': value,
      },
    };

/// 线程模块条目：老响应用 `items`、新响应用 `moduleItems`，两种都要能展开。
Map<String, Object?> _moduleEntry(
  String entryId, {
  required String itemsKey,
  required List<Map<String, Object?>> tweets,
}) =>
    {
      'entryId': entryId,
      'content': {
        'entryType': 'TimelineTimelineModule',
        itemsKey: [
          for (final t in tweets)
            {
              'item': {
                'itemContent': {
                  'itemType': 'TimelineTweet',
                  'tweet_results': {'result': t},
                },
              },
            },
        ],
      },
    };

Map<String, Object?> _addEntries(List<Object?> entries) =>
    {'type': 'TimelineAddEntries', 'entries': entries};

/// 完整的一页 SearchTimeline 响应：`data.search_by_raw_query.search_timeline.timeline.instructions`。
Map<String, Object?> _payload(List<Object?> instructions) => {
      'data': {
        'search_by_raw_query': {
          'search_timeline': {
            'timeline': {'instructions': instructions},
          },
        },
      },
    };

List<String> _ids(SearchResultPage page) =>
    [for (final h in page.items) h.item.tweetId];

void main() {
  // =========================================================================
  // A. XSearchQuery.build()
  //
  // 这一组防的回归是：查询串被静默拼坏。X 不会因为 `min_faves：100`
  // （全角冒号）或 `or`（小写）报错，只会安静地搜不到东西。
  // =========================================================================
  group('XSearchQuery.build()', () {
    test('A1 空条件 → 空字符串（调用方靠它拦下空查询）', () {
      // 空查询发给 X 只会拿到 400 / 风控，所以 build() 必须返回空串让上层拦。
      expect(const XSearchQuery().build(), '');
      // 只有空白的 text 等价于没填 —— 否则会拼出 `"   "` 这种畸形查询。
      expect(const XSearchQuery(text: '   ').build(), '');
      // 同时全空时 isEmpty 必须为 true（UI 用它判断「有没有条件可发」）。
      expect(const XSearchQuery().isEmpty, isTrue);
    });

    test('A2 纯关键词 → 原样（不加多余的引号/括号）', () {
      // 单个词不该被加引号：加引号会改变 X 的分词与同义词匹配行为。
      expect(const XSearchQuery(text: 'flutter').build(), 'flutter');
      expect(const XSearchQuery(text: '  flutter  ').build(), 'flutter');
    });

    test('A3 from/to 去掉 @ 前缀', () {
      // 期望 `from:alice`。漏掉 @ 剥离就会拼成 `from:@alice`（X 不报错，
      // 但 `from:@@alice` 这种手误连写就直接搜不到人了）。
      expect(
        const XSearchQuery(from: '@alice', to: '@bob').build(),
        'from:alice to:bob',
      );
      expect(const XSearchQuery(from: '@@alice').build(), 'from:alice');
    });

    test('A4 全角冒号归一化后，含冒号的 text 会被整体加引号', () {
      // 中文输入法下最容易打出全角冒号：`alice：bob`。归一成半角后它含有 ':'，
      // 若原样输出会被 X 解析成 `alice:` 这个不存在的操作符 + 关键词，静默搜错。
      expect(const XSearchQuery(text: 'alice：bob').build(), '"alice:bob"');
      // 带空格的短语同理：不加引号会被拆成隐式 AND。
      expect(const XSearchQuery(text: 'hello world').build(), '"hello world"');
      // from 的值是全角冒号时会被 `_bare` 清成裸用户名（不带引号、不带冒号）。
      expect(const XSearchQuery(from: 'alice：bob').build(), 'from:alicebob');
    });

    test('A5 媒体筛选互斥，只输出一个 filter:（同一页里拼两个会搜出空集）', () {
      expect(
        const XSearchQuery(media: SearchMediaFilter.images).build(),
        'filter:images',
      );
      expect(
        const XSearchQuery(media: SearchMediaFilter.videos).build(),
        'filter:videos',
      );
      // 默认 any 不产生任何输出，否则会凭空缩小结果集。
      expect(const XSearchQuery(media: SearchMediaFilter.any).build(), '');
      // images 时绝不能同时出现 videos（交集为空 = 永远搜不到）。
      expect(
        const XSearchQuery(media: SearchMediaFilter.images).build(),
        isNot(contains('filter:videos')),
      );
    });

    test('A6 排除项用取反形式 -filter:', () {
      // 写成 `exclude:replies` 之类的别名在冷门操作符上不通用，
      // 取反形式才是各处都认的写法。
      expect(
        const XSearchQuery(excludeReplies: true).build(),
        '-filter:replies',
      );
      expect(
        const XSearchQuery(excludeRetweets: true).build(),
        '-filter:retweets',
      );
      // 两个同时开：顺序固定，方便上层把它当字符串比较/缓存。
      expect(
        const XSearchQuery(excludeReplies: true, excludeRetweets: true).build(),
        '-filter:replies -filter:retweets',
      );
    });

    test('A7 minFaves 非正数不输出，正数拼成 min_faves:N', () {
      // 0 / 负数没有任何筛选意义；输出 `min_faves:0` 只会让人以为在筛什么。
      expect(const XSearchQuery(minFaves: 0).build(), '');
      expect(const XSearchQuery(minFaves: -5).build(), '');
      expect(const XSearchQuery(minFaves: 100).build(), 'min_faves:100');
      // 三个下限各自独立，别互相覆盖。
      expect(
        const XSearchQuery(minFaves: 100, minRetweets: 10, minReplies: 5).build(),
        'min_faves:100 min_retweets:10 min_replies:5',
      );
    });

    test('A8 anyOf 拼成大写 OR 的括号组', () {
      // X 只认大写 `OR`；小写 `or` 会变成普通关键词，结果完全跑偏。
      expect(const XSearchQuery(anyOf: ['a', 'b']).build(), '(a OR b)');
      expect(
        const XSearchQuery(text: 'flutter', anyOf: ['dart', 'swift']).build(),
        'flutter (dart OR swift)',
      );
      // 短语成员也要加引号，否则 `(hello world OR x)` 会被拆错。
      expect(
        const XSearchQuery(anyOf: ['hello world', 'x']).build(),
        '("hello world" OR x)',
      );
    });

    test('A9 noneOf 拼成 -word', () {
      // 排除词丢了负号就变成「必须包含」，正好反了。
      expect(const XSearchQuery(noneOf: ['spam']).build(), '-spam');
      expect(
        const XSearchQuery(text: 'flutter', noneOf: ['spam', 'ads']).build(),
        'flutter -spam -ads',
      );
      // 空白项不能产出裸的 `-`（那会让整个查询语法失效）。
      expect(const XSearchQuery(noneOf: ['  ']).build(), '');
    });

    test('A10 since / until 原样拼（不转日期格式、不改写）', () {
      // 用户/UI 传的就是 X 的 wire 格式，这一层只负责拼，不负责猜。
      expect(
        const XSearchQuery(since: '2024-01-01', until: '2024-02-01').build(),
        'since:2024-01-01 until:2024-02-01',
      );
      expect(
        const XSearchQuery(since: '2024-01-01_00:00:00_UTC').build(),
        'since:2024-01-01_00:00:00_UTC',
      );
    });
  });

  // =========================================================================
  // B. parseSearchPage()
  //
  // 这一组防的回归是：搜索页里混进来的非推文条目（广告、People 用户、
  // 线程重复项、tombstone）被当成结果展示，或者游标/终止标志被丢。
  // =========================================================================
  group('parseSearchPage()', () {
    test('B1 正常一页：2 条推文 + 上下游标 → 字段与游标都对', () {
      final page = parseSearchPage(_payload([
        _addEntries([
          _tweetEntry('tweet-111', _tweet(id: '111')),
          _cursorEntry('cursor-top-1', 'Top', 'TOP_CURSOR'),
          _tweetEntry(
            'tweet-222',
            _tweet(
              id: '222',
              text: 'second tweet',
              screenName: 'bob',
              favorited: true,
              media: [_photo('https://pbs.twimg.com/media/x.jpg')],
            ),
          ),
          _cursorEntry('cursor-bottom-1', 'Bottom', 'BOTTOM_CURSOR'),
        ]),
      ]));

      expect(_ids(page), ['111', '222']);
      expect(page.topCursor, 'TOP_CURSOR');
      expect(page.bottomCursor, 'BOTTOM_CURSOR');
      // hasMore 只看底部游标：非空就还能翻（搜索的游标翻到底也可能非空，
      // 所以这里断言的是「游标被保住了」，不是「还有一页」）。
      expect(page.hasMore, isTrue);
      expect(page.entryCount, 4);
      expect(page.hitCount, 2);
      expect(page.terminated, isFalse);

      final first = page.items.first;
      expect(first.item.text, 'hello world');
      // 作者信息在真实响应里位于 core.user_results.result.core.screen_name，
      // 读成 legacy.screen_name 会静默得到空用户名。
      expect(first.item.author?.screenName, 'alice');
      expect(first.item.author?.name, 'Alice');
      // created_at 走手写的 twitter_date 解析（DateTime.parse 不认这个格式）。
      expect(first.item.createdAt, DateTime.utc(2018, 10, 10, 20, 19, 24));
      // 这三个计数只来自 legacy，缺失时应该是 null 而不是 0（0 是「没人点赞」）。
      expect(first.favoriteCount, 12);
      expect(first.retweetCount, 3);
      expect(first.replyCount, 1);
      expect(first.alreadyLiked, isFalse);

      // 媒体走 legacy.extended_entities.media，图片统一升到 name=large。
      final second = page.items[1];
      expect(second.item.hasImage, isTrue);
      expect(second.item.media.first.url, endsWith('?name=large'));
      // favorited 是请求时刻的快照，只用来标记「已在我的喜欢里」。
      expect(second.alreadyLiked, isTrue);
    });

    test('B2 广告条目被剔除（entryId 前缀 + promotedMetadata 双路）', () {
      final page = parseSearchPage(_payload([
        _addEntries([
          // 线上广告的 entryId 形如 promoted-tweet-<id>。
          _tweetEntry('promoted-tweet-999', _tweet(id: '999', text: 'sponsored')),
          _tweetEntry('tweet-111', _tweet(id: '111')),
          // 广告推文也走 TimelineTweet，只是多带 promotedMetadata。
          _rawEntry('tweet-222', {
            'itemType': 'TimelineTweet',
            'promotedMetadata': {'impressionId': 'imp-1'},
            'tweet_results': {'result': _tweet(id: '222', text: 'also ad')},
          }),
        ]),
      ]));

      // 两条广告一条都不能漏进结果列表。
      expect(_ids(page), ['111']);
      expect(page.hitCount, 1);
      // entryCount 统计的是原始条目数（含被丢弃的），用于诊断「这页怎么这么少」。
      expect(page.entryCount, 3);
    });

    test('B3 itemType != TimelineTweet（People 标签页的用户条目）被忽略', () {
      final page = parseSearchPage(_payload([
        _addEntries([
          _rawEntry('user-777', {
            'itemType': 'TimelineUser',
            'user_results': {
              'result': {'rest_id': 'u777', 'core': {'screen_name': 'carol'}},
            },
          }),
          _tweetEntry('tweet-111', _tweet(id: '111')),
        ]),
      ]));

      // 用户条目没有推文节点，硬解析会抛异常或塞进一条空推文。
      expect(_ids(page), ['111']);
      expect(page.items.single.item.author?.screenName, 'alice');
    });

    test('B4 TweetTombstone 被丢弃，且不影响同一页的其它条目', () {
      final page = parseSearchPage(_payload([
        _addEntries([
          _tweetEntry('tweet-111', _tweet(id: '111')),
          // 搜索里的 tombstone 是「内容不可见」（已删/受保护/被限流），不是取消喜欢，
          // 所以它既不能进 items，也不该进「已删除」名单。
          _tweetEntry('tweet-222', {'__typename': 'TweetTombstone'}),
          _tweetEntry('tweet-333', _tweet(id: '333', text: 'third')),
        ]),
      ]));

      expect(_ids(page), ['111', '333']);
      expect(page.entryCount, 3);
      expect(page.items.map((h) => h.item.text), ['hello world', 'third']);
    });

    test('B5 TimelineTimelineModule 的 items / moduleItems 两种形态都能展开', () {
      final page = parseSearchPage(_payload([
        _addEntries([
          _moduleEntry('module-old', itemsKey: 'items', tweets: [_tweet(id: '111')]),
          _moduleEntry('module-new', itemsKey: 'moduleItems', tweets: [
            _tweet(id: '222', text: 'from moduleItems'),
          ]),
        ]),
      ]));

      // 只认一种形态的话，线程里的推文会整段消失（新老响应切换时的经典回归）。
      expect(_ids(page), ['111', '222']);
      expect(page.items[1].item.text, 'from moduleItems');
    });

    test('B6 TimelineTerminateTimeline → terminated=true，但不吞掉本页游标', () {
      final page = parseSearchPage(_payload([
        _addEntries([
          _tweetEntry('tweet-111', _tweet(id: '111')),
          _cursorEntry('cursor-bottom-1', 'Bottom', 'CURSOR_2'),
        ]),
        {'type': 'TimelineTerminateTimeline', 'direction': 'Bottom'},
      ]));

      expect(page.terminated, isTrue);
      expect(page.items, hasLength(1));
      // 关键：terminate 只置标志。早期版本顺手把游标清空，上层会误判成
      // 「第一页就到底」并把续传游标丢掉（Likes 侧出过完全一样的 bug）。
      expect(page.bottomCursor, 'CURSOR_2');
      expect(page.hasMore, isTrue);
    });

    test('B7 线程模块里重复出现的同一推文按 tweet_id 去重，保留第一条', () {
      final page = parseSearchPage(_payload([
        _addEntries([
          _tweetEntry('tweet-111', _tweet(id: '111', text: 'root')),
          _moduleEntry('module-thread', itemsKey: 'items', tweets: [
            // 线程模块会把「根推文」再带一遍，内容相同但位置不同。
            _tweet(id: '111', text: 'root (again)'),
            _tweet(id: '222', text: 'reply'),
            _tweet(id: '222', text: 'reply (again)'),
          ]),
        ]),
      ]));

      expect(_ids(page), ['111', '222']);
      // 保留的是先解析到的那条，内容不能被后来者的版本覆盖成怪东西。
      expect(page.items.first.item.text, 'root');
      expect(page.items[1].item.text, 'reply');
    });

    test('B8 data 为空 / search_by_raw_query 为 null → 抛 SearchParseException', () {
      // 这两种都是「结构不对」，必须抛类型化异常让上层区分于「没有更多数据」。
      expect(
        () => parseSearchPage({'data': {}}),
        throwsA(isA<SearchParseException>()),
      );
      // X 在查询被整体拒绝/风控时正是返回 search_by_raw_query: null（而不是 errors）。
      expect(
        () => parseSearchPage({
          'data': {'search_by_raw_query': null},
        }),
        throwsA(isA<SearchParseException>()),
      );
      // 非 JSON 对象同样要抛，而不是在某处 null 崩溃。
      expect(
        () => parseSearchPage(const []),
        throwsA(isA<SearchParseException>()),
      );
      // 只有 errors 没有 data：异常 message 要带上服务端原因，方便 UI 直接提示。
      expect(
        () => parseSearchPage({
          'errors': [
            {'message': 'query rejected'},
          ],
        }),
        throwsA(
          isA<SearchParseException>()
              .having((e) => e.message, 'message', contains('query rejected')),
        ),
      );
    });

    test('B9 highlights（itemContent.highlights.textHighlights）解析进 SearchHit', () {
      final page = parseSearchPage(_payload([
        _addEntries([
          _rawEntry('tweet-111', {
            'itemType': 'TimelineTweet',
            'highlights': {
              'textHighlights': [
                {'startIndex': 0, 'endIndex': 5},
                {'startIndex': 6, 'endIndex': 11},
                // 空区间必须丢掉：end<=start 的高亮区间会让 UI 画出 0 宽的怪标记。
                {'startIndex': 20, 'endIndex': 20},
              ],
            },
            'tweet_results': {'result': _tweet(id: '111')},
          }),
        ]),
      ]));

      final hit = page.items.single;
      expect(hit.highlights, hasLength(2));
      expect(hit.highlights.first.start, 0);
      expect(hit.highlights.first.end, 5);
      expect(hit.highlights[1].start, 6);
      expect(hit.highlights[1].end, 11);
      // 没有 highlights 字段的推文应该是空列表而不是 null（UI 直接遍历）。
      final plain = parseSearchPage(_payload([
        _addEntries([
          _tweetEntry('tweet-222', _tweet(id: '222')),
        ]),
      ]));
      expect(plain.items.single.highlights, isEmpty);
    });
  });
}

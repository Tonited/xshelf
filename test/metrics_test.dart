import 'package:flutter_test/flutter_test.dart';
import 'package:xlikemanage/src/model/like_item.dart';
import 'package:xlikemanage/src/sync/metrics.dart';

/// 互动数据的来源是 `raw_json`（同步时带回来的快照），不是网络。
/// 这里把「X 的几种数字形态」都钉死：int、字符串、包在 `{count: …}` 里。
void main() {
  group('TweetMetrics.fromRaw', () {
    test('从 legacy 里抠出四个计数', () {
      final m = TweetMetrics.fromRaw({
        'legacy': {
          'reply_count': 3,
          'retweet_count': 12,
          'favorite_count': 345,
          'quote_count': 1,
          'bookmark_count': 7,
        },
      });
      expect(m, isNotNull);
      expect(m!.replies, 3);
      expect(m.retweets, 12);
      expect(m.likes, 345);
      expect(m.quotes, 1);
      expect(m.bookmarks, 7);
      // 没有浏览量时热度用加权估算
      expect(m.views, isNull);
      expect(m.heat, 345 + 12 * 2 + 1 * 2);
    });

    test('数字是字符串 / 包在 count 里也能解', () {
      final m = TweetMetrics.fromRaw({
        'legacy': {
          'reply_count': '8',
          'favorite_count': 1000,
        },
        'views': {'count': '12345'},
      });
      expect(m!.replies, 8);
      expect(m.views, 12345);
      // 有浏览量就优先用它当热度
      expect(m.heat, 12345);
    });

    test('TweetWithVisibilityResults 多包一层也能解', () {
      final m = TweetMetrics.fromRaw({
        '__typename': 'TweetWithVisibilityResults',
        'tweet': {
          'legacy': {'favorite_count': 5, 'reply_count': 0},
        },
      });
      expect(m!.likes, 5);
      expect(m.replies, 0);
    });

    test('什么都没有时返回 null（整行不显示，而不是显示一排 0）', () {
      expect(TweetMetrics.fromRaw(null), isNull);
      expect(TweetMetrics.fromRaw({'legacy': {}}), isNull);
    });
  });

  group('MetricsStore', () {
    test('同一条只解析一次，且不影响别人', () {
      final store = MetricsStore();
      final a = LikeItem(
        tweetId: 'a',
        text: '',
        raw: {
          'legacy': {'favorite_count': 9},
        },
      );
      const b = LikeItem(tweetId: 'b', text: '');
      expect(store.of(a)!.likes, 9);
      expect(store['a']!.likes, 9);
      expect(store.of(b), isNull);
      store.clear();
      expect(store['a'], isNull);
    });
  });
}

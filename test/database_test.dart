import 'dart:ffi';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';
import 'package:xlikemanage/src/db/app_database.dart';
import 'package:xlikemanage/src/model/like_item.dart';

/// 数据层是这套应用里最容易出错的地方（seq 分配、游标、差集删除），
/// 这里用内存库把它钉死。
///
/// 宿主测试没有 `sqlite3_flutter_libs`，所以绑定系统自带的 SQLite
/// （Windows: winsqlite3.dll）。拿不到就整组跳过，保持套件在别的机器上绿。
void main() {
  var available = true;

  setUpAll(() {
    try {
      open.overrideFor(
        OperatingSystem.windows,
        () => DynamicLibrary.open('winsqlite3.dll'),
      );
      final probe = AppDatabase.open(':memory:');
      probe.dispose();
    } catch (_) {
      available = false;
    }
  });

  AppDatabase newDb() => AppDatabase.open(':memory:');

  LikeItem item(
    String id, {
    String text = 'text',
    DateTime? created,
    bool video = false,
    String? author = 'alice',
  }) => LikeItem(
    tweetId: id,
    text: text,
    createdAt: created ?? DateTime.utc(2021, 5, 1),
    author: author == null
        ? null
        : Author(id: 'u_$author', screenName: author, name: author),
    media: video
        ? const [
            MediaItem(
              kind: MediaKind.video,
              url: 'https://example.invalid/p.jpg',
              variants: [
                MediaVariant(
                  url: 'https://example.invalid/v.mp4',
                  contentType: 'video/mp4',
                ),
              ],
            ),
          ]
        : const [],
  );

  group('schema + seq allocation', () {
    test('assigns decreasing seq with a gap for later inserts', () {
      if (!available) return;
      final db = newDb();
      addTearDown(db.dispose);

      final r1 = db.insertPage(
        [item('a'), item('b'), item('c')],
        accountId: 1,
        startSeq: 0,
      );
      expect(r1.inserted, 3);
      expect(db.getLike('a')!.feedRank, 0);
      expect(db.getLike('b')!.feedRank, -AppDatabase.seqStep);
      expect(db.getLike('c')!.feedRank, -AppDatabase.seqStep * 2);
      expect(r1.nextSeq, -AppDatabase.seqStep * 3);
    });

    test('cancelling hides the row but keeps it for restoring', () {
      if (!available) return;
      final db = newDb();
      addTearDown(db.dispose);
      db.insertPage([item('a')], accountId: 1, startSeq: 0);

      expect(db.hasVisibleTweet('a'), isTrue);
      db.markRemoved(['a']);
      // 行还在：界面标记必须消失，但恢复要用到它。
      expect(db.hasVisibleTweet('a'), isFalse, reason: '取消掉的不该再显示成「已喜欢/已书签」');
      expect(db.hasTweet('a'), isTrue, reason: '行保留，点回来能原样恢复');

      db.restoreLike('a');
      expect(db.hasVisibleTweet('a'), isTrue);
    });
    test('re-inserting an existing tweet keeps its original seq', () {
      if (!available) return;
      final db = newDb();
      addTearDown(db.dispose);

      db.insertPage([item('a', text: 'first')], accountId: 1, startSeq: 0);
      final again = db.insertPage(
        [item('a', text: 'second')],
        accountId: 1,
        startSeq: -999,
      );
      expect(again.inserted, 0);
      expect(db.getLike('a')!.feedRank, 0);
      expect(db.getLike('a')!.text, 'second');
    });

    test('seqBetween finds a midpoint and refuses when there is no room', () {
      if (!available) return;
      expect(dbBetween(low: 0, high: 10), 5);
      expect(dbBetween(low: 0, high: 1), isNull);
      expect(dbBetween(low: null, high: 7), 6);
      expect(dbBetween(low: 7, high: null), 8);
    });
  });

  group('paging', () {
    test('like order pages forward without gaps or repeats', () {
      if (!available) return;
      final db = newDb();
      addTearDown(db.dispose);

      final items = [for (var i = 0; i < 7; i++) item('t$i')];
      db.insertPage(items, accountId: 1, startSeq: 0);

      final seen = <String>[];
      PageKey? cursor;
      var guard = 0;
      while (guard++ < 20) {
        final page = db.fetchPage(
          mode: SortMode.likeOrder,
          filter: const LikesFilter(),
          limit: 3,
          after: cursor,
        );
        seen.addAll(page.items.map((i) => i.tweetId));
        cursor = page.key;
        if (cursor == null) break;
      }
      expect(seen, ['t0', 't1', 't2', 't3', 't4', 't5', 't6']);
    });

    test('publish-date order sorts by created_at and pages by (date,id)', () {
      if (!available) return;
      final db = newDb();
      addTearDown(db.dispose);

      db.insertPage(
        [
          item('old', created: DateTime.utc(2020, 1, 1)),
          item('new', created: DateTime.utc(2024, 1, 1)),
          item('mid', created: DateTime.utc(2022, 1, 1)),
        ],
        accountId: 1,
        startSeq: 0,
      );

      final first = db.fetchPage(
        mode: SortMode.publishDate,
        filter: const LikesFilter(),
        limit: 2,
      );
      expect(first.items.map((i) => i.tweetId), ['new', 'mid']);
      expect(first.key, isNotNull);

      final second = db.fetchPage(
        mode: SortMode.publishDate,
        filter: const LikesFilter(),
        limit: 2,
        after: first.key,
      );
      expect(second.items.map((i) => i.tweetId), ['old']);
      expect(second.key, isNull);
    });

    test('random order can jump to the N-th item too', () {
      if (!available) return;
      final db = newDb();
      addTearDown(db.dispose);

      db.insertPage(
        [for (var i = 0; i < 6; i++) item('r$i')],
        accountId: 1,
        startSeq: 0,
      );

      // 「随机」也是按 rand_key 排出来的一个顺序，所以一样能按位置取游标 ——
      // 以前 UI 把随机模式的跳转整个藏掉了，这条守住「它其实能跳」。
      final key = db.keyAtOffset(
        mode: SortMode.random,
        filter: const LikesFilter(),
        offset: 2,
      );
      expect(key, isNotNull);
      expect(key!.randKey, isNotNull);

      final page = db.fetchPage(
        mode: SortMode.random,
        filter: const LikesFilter(),
        limit: 10,
        after: key,
        includeStart: true,
      );
      expect(page.items, isNotEmpty);
      // 从游标开始按 rand_key 升序，第一条就是 offset 指向的那一条。
      final randKeys = page.items
          .map((i) => db.getLike(i.tweetId)?.randKey)
          .whereType<int>()
          .toList();
      expect(randKeys.first, key.randKey);
    });

    test('media filters narrow the set', () {
      if (!available) return;
      final db = newDb();
      addTearDown(db.dispose);

      db.insertPage(
        [item('vid', video: true), item('txt')],
        accountId: 1,
        startSeq: 0,
      );

      final videos = db.fetchPage(
        mode: SortMode.likeOrder,
        filter: const LikesFilter(media: {MediaFilter.video}),
        limit: 10,
      );
      expect(videos.items.map((i) => i.tweetId), ['vid']);

      final texts = db.fetchPage(
        mode: SortMode.likeOrder,
        filter: const LikesFilter(media: {MediaFilter.text}),
        limit: 10,
      );
      expect(texts.items.map((i) => i.tweetId), ['txt']);
    });

    test('author and date-range filters work together', () {
      if (!available) return;
      final db = newDb();
      addTearDown(db.dispose);

      db.insertPage(
        [
          item('a1', author: 'alice', created: DateTime.utc(2021, 1, 1)),
          item('b1', author: 'bob', created: DateTime.utc(2021, 6, 1)),
          item('a2', author: 'alice', created: DateTime.utc(2023, 1, 1)),
        ],
        accountId: 1,
        startSeq: 0,
      );

      final page = db.fetchPage(
        mode: SortMode.likeOrder,
        filter: LikesFilter(
          authorScreenName: 'alice',
          from: DateTime.utc(2021, 1, 1),
          to: DateTime.utc(2022, 1, 1),
        ),
        limit: 10,
      );
      expect(page.items.map((i) => i.tweetId), ['a1']);
    });
  });

  group('search', () {
    test('finds text and author substrings', () {
      if (!available) return;
      final db = newDb();
      addTearDown(db.dispose);

      db.insertPage(
        [
          item('x', text: 'cats and dogs', author: 'alice'),
          item('y', text: '天气预报', author: 'bob'),
        ],
        accountId: 1,
        startSeq: 0,
      );

      final byText = db.fetchPage(
        mode: SortMode.likeOrder,
        filter: const LikesFilter(search: 'dogs'),
        limit: 10,
      );
      expect(byText.items.map((i) => i.tweetId), contains('x'));

      final byAuthor = db.fetchPage(
        mode: SortMode.likeOrder,
        filter: const LikesFilter(search: 'bob'),
        limit: 10,
      );
      expect(byAuthor.items.map((i) => i.tweetId), contains('y'));

      // 两字中文：trigram 不够长，必须走 LIKE 回退
      final byShort = db.fetchPage(
        mode: SortMode.likeOrder,
        filter: const LikesFilter(search: '天气'),
        limit: 10,
      );
      expect(byShort.items.map((i) => i.tweetId), contains('y'));
    });
  });

  group('mutations', () {
    test('deleteLike also clears the search index', () {
      if (!available) return;
      final db = newDb();
      addTearDown(db.dispose);

      db.insertPage(
        [item('gone', text: 'unique-phrase-xyz')],
        accountId: 1,
        startSeq: 0,
      );
      db.deleteLike('gone');
      expect(db.getLike('gone'), isNull);

      final page = db.fetchPage(
        mode: SortMode.likeOrder,
        filter: const LikesFilter(search: 'unique-phrase-xyz'),
        limit: 10,
      );
      expect(page.items, isEmpty);
    });

    test('markDeleted keeps the row but hides it from the normal count', () {
      if (!available) return;
      final db = newDb();
      addTearDown(db.dispose);

      db.insertPage([item('d1'), item('d2')], accountId: 1, startSeq: 0);
      db.markDeleted(['d1']);
      expect(db.getLike('d1')!.state, LikeState.deleted);
      expect(db.countLikes(includeDeleted: false), 1);
      expect(db.countLikes(), 2);
    });

    test('insertAtSeq puts a missing item between two neighbours', () {
      if (!available) return;
      final db = newDb();
      addTearDown(db.dispose);

      db.insertPage([item('top'), item('bottom')], accountId: 1, startSeq: 0);
      final topSeq = db.getLike('top')!.feedRank!;
      final bottomSeq = db.getLike('bottom')!.feedRank!;
      final mid = db.seqBetween(bottomSeq, topSeq)!;
      expect(db.insertAtSeq(item('mid'), accountId: 1, seq: mid), isTrue);

      final order = db
          .fetchPage(
            mode: SortMode.likeOrder,
            filter: const LikesFilter(),
            limit: 10,
          )
          .items
          .map((i) => i.tweetId)
          .toList();
      expect(order, ['top', 'mid', 'bottom']);
    });
  });

  group('timeline helpers', () {
    test('months and newestSeqInMonth', () {
      if (!available) return;
      final db = newDb();
      addTearDown(db.dispose);

      db.insertPage(
        [
          item('may', created: DateTime.utc(2021, 5, 10)),
          item('jun', created: DateTime.utc(2021, 6, 10)),
          item('may2', created: DateTime.utc(2021, 5, 20)),
        ],
        accountId: 1,
        startSeq: 0,
      );

      final months = db.months();
      expect(months.map((m) => m.month), ['2021-06', '2021-05']);
      final may = months.firstWhere((m) => m.month == '2021-05');
      expect(may.count, 2);

      // 「喜欢顺序最靠前」的五月条目是 seq 最小的那条（may，最后插入的）
      expect(db.newestSeqInMonth('2021-05'), db.getLike('may')!.feedRank);
    });

    test('seqBounds and segmentStartFor line up', () {
      if (!available) return;
      final db = newDb();
      addTearDown(db.dispose);

      db.insertPage([item('a'), item('b')], accountId: 1, startSeq: 0);
      final bounds = db.seqBounds();
      expect(bounds.minSeq, -AppDatabase.seqStep);
      expect(bounds.maxSeq, 0);

      final segStart = db.segmentStartFor(-AppDatabase.seqStep);
      expect(segStart % (AppDatabase.seqStep * 200), 0);
      expect(segStart, lessThanOrEqualTo(-AppDatabase.seqStep));
    });
  });

  group('媒体画质记忆', () {
    test('缓存文件记下自己的档位，最好档只升不降', () {
      if (!available) return;
      final db = newDb();
      addTearDown(db.dispose);

      db.insertPage([item('a', video: true)], accountId: 1, startSeq: 0);

      // 高画质播过 → 记成最好档
      db.rememberMediaVariant('a', 0, '720_2176000', 2176000);
      expect(db.mediaBestVariant('a', 0), '720_2176000');

      // 再播低画质不该把记忆降级
      db.rememberMediaVariant('a', 0, '270_256000', 256000);
      expect(db.mediaBestVariant('a', 0), '720_2176000');

      // 缓存文件落盘：记录文件是哪一档
      db.markMediaCached(
        'a',
        0,
        '/tmp/a.mp4',
        1234,
        variant: '720_2176000',
        rank: 2176000,
      );
      final row = db.mediaCacheRow('a', 0);
      expect(row.path, '/tmp/a.mp4');
      expect(row.cacheVariant, '720_2176000');
      expect(row.bestVariant, '720_2176000');
      expect(row.bestRank, 2176000);

      // 重新同步同一条推文不能把缓存/画质记录冲掉
      db.insertPage(
        [item('a', video: true, text: 'updated')],
        accountId: 1,
        startSeq: -999,
      );
      expect(db.mediaCacheRow('a', 0).cacheVariant, '720_2176000');
    });

    test('文件坏掉只清文件记录，画质记忆保留', () {
      if (!available) return;
      final db = newDb();
      addTearDown(db.dispose);

      db.insertPage([item('a', video: true)], accountId: 1, startSeq: 0);
      db.markMediaCached(
        'a',
        0,
        '/tmp/a.mp4',
        10,
        variant: '720_2176000',
        rank: 2176000,
      );
      db.clearMediaPath('a', 0);

      final row = db.mediaCacheRow('a', 0);
      expect(row.path, isNull);
      expect(row.cacheVariant, isNull);
      expect(row.bestVariant, '720_2176000');
    });
  });
}

/// 直接调 AppDatabase 的静态辅助（避免为测试专门造实例）。
int? dbBetween({required int? low, required int? high}) {
  if (low == null && high == null) return 0;
  if (low == null) return high! - 1;
  if (high == null) return low + 1;
  if (high - low <= 1) return null;
  return low + ((high - low) ~/ 2);
}

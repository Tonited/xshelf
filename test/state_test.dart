import 'dart:ffi';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';
import 'package:xlikemanage/src/core/settings.dart';
import 'package:xlikemanage/src/db/app_database.dart';
import 'package:xlikemanage/src/model/like_item.dart';
import 'package:xlikemanage/src/state/browse_state.dart';

/// 浏览层的行为约定（分页方向、锚点、时间轴分桶）都在这里钉死。
void main() {
  var available = true;

  setUpAll(() {
    try {
      open.overrideFor(
        OperatingSystem.windows,
        () => DynamicLibrary.open('winsqlite3.dll'),
      );
      final probe = AppDatabase.openInMemory();
      probe.dispose();
    } catch (_) {
      available = false;
    }
  });

  LikeItem item(String id, {DateTime? created, String? imageUrl}) => LikeItem(
    tweetId: id,
    text: 'text $id',
    createdAt: created ?? DateTime.utc(2021, 5, 1),
    author: const Author(id: 'u1', screenName: 'alice', name: 'Alice'),
    media: imageUrl == null
        ? const []
        : [
            MediaItem(
              kind: MediaKind.image,
              url: imageUrl,
              width: 1200,
              height: 900,
            ),
          ],
  );

  group('image variants', () {
    test('grid thumbnails ask the CDN for a small rendition', () {
      final it = item(
        '1',
        imageUrl: 'https://pbs.twimg.com/media/abc.jpg?format=jpg&name=large',
      );
      expect(
        it.thumbnailUrl,
        'https://pbs.twimg.com/media/abc.jpg?format=jpg&name=small',
      );
      expect(
        it.fullImageUrl,
        'https://pbs.twimg.com/media/abc.jpg?format=jpg&name=orig',
      );
    });

    test('urls without a name parameter are left alone', () {
      expect(
        withImageVariant('https://example.invalid/a.jpg', 'small'),
        'https://example.invalid/a.jpg',
      );
    });
  });

  group('random sort keys', () {
    test('consecutive calls do not collide', () {
      // 以前用「当前微秒」当键：同一微秒内的调用完全相同，
      // 洗牌 5 万条会产生大量重复键，随机分页会整段跳过。
      final keys = {for (var i = 0; i < 20000; i++) randomSortKey()};
      expect(keys.length, 20000);
      expect(keys.any((k) => k <= 0), isFalse);
    });
  });

  group('estimated timeline', () {
    test('buckets every seqStep*200 window in one pass', () {
      if (!available) return;
      final db = AppDatabase.openInMemory();
      addTearDown(db.dispose);

      final base = DateTime.utc(2020, 1, 1);
      db.insertPage(
        [
          for (var i = 0; i < 250; i++)
            item('t$i', created: base.add(Duration(days: i))),
        ],
        accountId: 1,
        startSeq: 0,
      );

      final buckets = db.estimatedBuckets();
      // seq 从 0 往下递减：第 1 条独占 [0,2e8)，第 2..201 条落 [-2e8,0)，
      // 余下 49 条落 [-4e8,-2e8)。顺序与列表一致：新的在前。
      expect(buckets.map((b) => b.count), [1, 200, 49]);
      expect(buckets.first.fromSeq, 0);
      expect(buckets[1].fromSeq, -AppDatabase.seqStep * 200);

      // 中位数取自该桶内 created_at 排序后的中间值（含 1 基偏移）。
      expect(buckets[1].approxDate, base.add(const Duration(days: 101)));
      expect(buckets.last.count, 49);
    });

    test('empty database yields no buckets', () {
      if (!available) return;
      final db = AppDatabase.openInMemory();
      addTearDown(db.dispose);
      expect(db.estimatedBuckets(), isEmpty);
    });
  });

  group('browse state', () {
    Future<BrowseState> loaded(dynamic db) async {
      final browse = BrowseState(db: db, persistView: (kind, v) async {});
      await browse.reload(reset: true);
      return browse;
    }

    test('lists newest first and pages without repeats', () async {
      if (!available) return;
      final db = AppDatabase.openInMemory();
      addTearDown(db.dispose);
      db.insertPage(
        [for (var i = 0; i < 7; i++) item('t$i')],
        accountId: 1,
        startSeq: 0,
      );

      final browse = await loaded(db);
      expect(browse.items.map((i) => i.tweetId), [
        't0',
        't1',
        't2',
        't3',
        't4',
        't5',
        't6',
      ]);
      expect(browse.hasMore, isFalse);
      expect(browse.totalCount, 7);
    });

    test('jumpToSeq includes the anchor itself', () async {
      if (!available) return;
      final db = AppDatabase.openInMemory();
      addTearDown(db.dispose);
      db.insertPage(
        [for (var i = 0; i < 7; i++) item('t$i')],
        accountId: 1,
        startSeq: 0,
      );

      final browse = await loaded(db);
      final anchor = browse.items[3].feedRank!;
      await browse.jumpToSeq(anchor);
      // 差一错误会直接跳过被点的那个月份的第一条。
      expect(browse.items.first.tweetId, 't3');
      expect(browse.items.map((i) => i.tweetId), ['t3', 't4', 't5', 't6']);
    });

    test('refresh after sync keeps the visible anchor', () async {
      if (!available) return;
      final db = AppDatabase.openInMemory();
      addTearDown(db.dispose);
      db.insertPage(
        [for (var i = 0; i < 7; i++) item('t$i')],
        accountId: 1,
        startSeq: 0,
      );

      final browse = await loaded(db);
      await browse.jumpToSeq(browse.items[2].feedRank!);
      expect(browse.items.first.tweetId, 't2');

      // 同步插入了更新的一条（seq 在最大处之上）
      db.insertPage(
        [item('fresh')],
        accountId: 1,
        startSeq: db.maxSeqOverall()! + AppDatabase.seqStep,
      );
      await browse.refresh();

      // center 那一条是用户当前看的位置，刷新不能把它顶走；新同步进来的条目
      // 排在它**上方**（`_older`），所以 `items.first` 会变，但 center 不变。
      expect(
        browse.items[browse.olderCount].tweetId,
        't2',
        reason: '刷新不应把用户弹回顶部',
      );
      expect(
        browse.items.first.tweetId,
        'fresh',
        reason: '新同步的条目应出现在 center 上方',
      );
      expect(browse.totalCount, 8);

      await browse.reload(reset: true);
      expect(browse.items.first.tweetId, 'fresh');
    });

    test('dropLocal clears the selection and the cached count', () async {
      if (!available) return;
      final db = AppDatabase.openInMemory();
      addTearDown(db.dispose);
      db.insertPage(
        [for (var i = 0; i < 3; i++) item('t$i')],
        accountId: 1,
        startSeq: 0,
      );

      final browse = await loaded(db);
      browse.select('t1');
      expect(browse.selectedItem?.tweetId, 't1');

      db.deleteLike('t1');
      browse.dropLocal('t1');
      expect(browse.items.map((i) => i.tweetId), ['t0', 't2']);
      expect(browse.selectedItem, isNull);
      expect(browse.totalCount, 2);
    });

    test('view snapshots round-trip through the persister', () async {
      if (!available) return;
      final db = AppDatabase.openInMemory();
      addTearDown(db.dispose);
      db.insertPage(
        [for (var i = 0; i < 3; i++) item('t$i')],
        accountId: 1,
        startSeq: 0,
      );

      final saved = <ViewSnapshot>[];
      final browse = BrowseState(
        db: db,
        persistView: (kind, v) async => saved.add(v),
      );
      browse.restoreFrom(const ViewSnapshot(mode: SortMode.publishDate));
      await browse.reload(reset: true);
      await browse.saveView(scrollOffset: 120);

      expect(browse.mode, SortMode.publishDate);
      expect(saved.single.anchorSeq, browse.items.first.feedRank);
      expect(saved.single.scrollOffset, 120);
    });
  });
}

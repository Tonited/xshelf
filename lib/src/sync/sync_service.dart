/// 同步服务：全量回填、增量更新、取消喜欢。
///
/// 单个「巡边器」的简化版先落地两条主线（回填 + 增量），
/// 视口核对 / 陈段轮转在 M7 接到同一个 `budget` 上。
library;

import 'dart:math' as math;

import '../db/app_database.dart';
import 'x_client.dart';

class SyncCancel {
  bool _cancelled = false;
  bool get cancelled => _cancelled;
  void cancel() => _cancelled = true;
}

class SyncProgress {
  const SyncProgress({
    required this.pages,
    required this.fetched,
    required this.inserted,
    this.done = false,
    this.message,
  });

  final int pages;
  final int fetched;
  final int inserted;
  final bool done;
  final String? message;
}

class SyncService {
  SyncService({
    required this.db,
    required this.client,
    this.pace = const Duration(milliseconds: 1500),
  });

  final AppDatabase db;
  final XClient client;

  /// 请求间隔（秒级节流，降低风控概率）。
  final Duration pace;

  /// 全量回填：从最旧没抓过的位置继续。
  ///
  /// [maxItems] 单次最多抓多少条（软上限）；[since] 只抓推文发布时间晚于它的。
  Future<SyncProgress> backfill({
    required int accountId,
    int? maxItems,
    DateTime? since,
    void Function(SyncProgress)? onProgress,
    SyncCancel? cancel,
  }) async {
    var state = db.loadSyncState(accountId);
    var cursor = state.backfillCursor;
    var seqCursor = (state.minSeq ?? AppDatabase.seqStep) - AppDatabase.seqStep;
    var pages = 0;
    var fetched = 0;
    var inserted = 0;
    int? lastAligned;

    while (true) {
      if (cancel?.cancelled == true) {
        onProgress?.call(SyncProgress(
          pages: pages,
          fetched: fetched,
          inserted: inserted,
          message: '已暂停（下次会从这里继续）',
        ));
        return SyncProgress(pages: pages, fetched: fetched, inserted: inserted);
      }
      if (maxItems != null && fetched >= maxItems) break;

      final page = await client.fetchLikes(cursor: cursor);
      final items = since == null
          ? page.items
          : page.items
              .where((i) => i.createdAt == null || !i.createdAt!.isBefore(since))
              .toList();

      if (page.deletedTweetIds.isNotEmpty) {
        db.markDeleted(page.deletedTweetIds);
      }

      if (items.isNotEmpty) {
        final res = db.insertPage(
          items,
          accountId: accountId,
          startSeq: seqCursor,
        );
        inserted += res.inserted;
        fetched += items.length;
        pages++;

        // 登记区段与它的起点游标，供巡边器将来重新翻到这一段。
        final aligned = db.segmentStartFor(seqCursor);
        if (aligned != lastAligned) {
          db.upsertSegment(
            accountId: accountId,
            startSeq: aligned,
            endSeq: aligned + AppDatabase.seqStep * 200,
            cursor: page.topCursor,
          );
          lastAligned = aligned;
        }
        seqCursor = res.nextSeq;
      }

      // 时间范围到底：说明再翻也没有比 since 更新的了
      final reachedSince = since != null &&
          page.items.isNotEmpty &&
          page.items.every((i) => i.createdAt != null && i.createdAt!.isBefore(since));

      cursor = page.bottomCursor;
      state = state.copyWith(
        minSeq: seqCursor + AppDatabase.seqStep,
        maxSeq: state.maxSeq == null
            ? seqCursor + AppDatabase.seqStep
            : math.min(state.maxSeq!, seqCursor + AppDatabase.seqStep),
        backfillCursor: cursor,
      );
      db.saveSyncState(accountId, state);

      onProgress?.call(SyncProgress(
        pages: pages,
        fetched: fetched,
        inserted: inserted,
      ));

      if (!page.hasMore || reachedSince) break;

      await Future<void>.delayed(pace);
    }

    state = state.copyWith(
      backfillDone: true,
      backfillCursor: null,
      minSeq: db.minSeqOverall(),
      maxSeq: db.maxSeqOverall(),
    );
    db.saveSyncState(accountId, state);
    final done = SyncProgress(
      pages: pages,
      fetched: fetched,
      inserted: inserted,
      done: true,
    );
    onProgress?.call(done);
    return done;
  }

  /// 增量：从最新往回翻，翻到已有条目就停。
  Future<SyncProgress> syncNew({
    required int accountId,
    int? maxItems,
    void Function(SyncProgress)? onProgress,
    SyncCancel? cancel,
  }) async {
    var state = db.loadSyncState(accountId);
    var cursor = <String?>[null][0];
    var seqCursor = (state.minSeq ?? AppDatabase.seqStep) - AppDatabase.seqStep;
    var pages = 0;
    var fetched = 0;
    var inserted = 0;
    var hitExisting = false;

    while (true) {
      if (cancel?.cancelled == true) break;
      if (maxItems != null && fetched >= maxItems) break;

      final page = await client.fetchLikes(cursor: cursor);
      final fresh = <String>{};
      for (final item in page.items) {
        if (!db.hasTweet(item.tweetId)) fresh.add(item.tweetId);
      }
      if (fresh.length < page.items.length) hitExisting = true;

      final newItems =
          page.items.where((i) => fresh.contains(i.tweetId)).toList();
      if (newItems.isNotEmpty) {
        final res = db.insertPage(
          newItems,
          accountId: accountId,
          startSeq: seqCursor,
        );
        inserted += res.inserted;
        seqCursor = res.nextSeq;
        fetched += newItems.length;
      }
      pages++;

      state = state.copyWith(minSeq: seqCursor + AppDatabase.seqStep);
      db.saveSyncState(accountId, state);

      onProgress?.call(SyncProgress(
        pages: pages,
        fetched: fetched,
        inserted: inserted,
      ));

      cursor = page.bottomCursor;
      if (hitExisting || !page.hasMore) break;
      await Future<void>.delayed(pace);
    }

    return SyncProgress(pages: pages, fetched: fetched, inserted: inserted, done: true);
  }

  /// 取消喜欢：调接口 + 删本地记录。
  Future<void> unlike(String tweetId) async {
    await client.unlike(tweetId);
    db.deleteLike(tweetId);
  }
}

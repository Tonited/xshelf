/// 同步服务：全量回填、增量更新、取消喜欢。
///
/// 单个「巡边器」的简化版先落地两条主线（回填 + 增量），
/// 视口核对 / 陈段轮转在 M7 接到同一个 `budget` 上。
library;

import 'dart:math' as math;

import '../db/app_database.dart';
import '../model/like_item.dart';
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
    var exhausted = false;
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
        // seq 越大越新：回填过程中 maxSeq 必须保持第一页那个值，不能往下掉。
        maxSeq: state.maxSeq == null
            ? seqCursor + AppDatabase.seqStep
            : math.max(state.maxSeq!, seqCursor + AppDatabase.seqStep),
        backfillCursor: cursor,
        // copyWith 里 null 表示「不改」，所以末页要显式清空。
        clearBackfillCursor: cursor == null,
      );
      db.saveSyncState(accountId, state);

      onProgress?.call(SyncProgress(
        pages: pages,
        fetched: fetched,
        inserted: inserted,
      ));

      if (!page.hasMore || reachedSince) {
        exhausted = true;
        break;
      }

      await Future<void>.delayed(pace);
    }

    // 只有真正翻到底才算「回填完成」；被 maxItems 截断/用户暂停时保持未完成，
    // 否则下次启动会以为没事可做。
    state = state.copyWith(
      backfillDone: exhausted,
      // 翻到底才清游标；被截断/暂停时保留，下次从这里继续。
      clearBackfillCursor: exhausted,
      minSeq: db.minSeqOverall(),
      maxSeq: db.maxSeqOverall(),
    );
    db.saveSyncState(accountId, state);
    final done = SyncProgress(
      pages: pages,
      fetched: fetched,
      inserted: inserted,
      done: exhausted,
      message: exhausted ? null : '已暂停（下次会从这里继续）',
    );
    onProgress?.call(done);
    return done;
  }

  /// 增量：从最新往回翻，翻到已有条目就停。
  ///
  /// seq 约定「越大越新」，新增的喜欢必须排到现有最大 seq 之上。
  /// 因为整批条目是「新→旧」顺序、而 `insertPage` 是递减分配，
  /// 所以先把整批收集齐，再从 `maxSeq + n * step` 往下分配。
  Future<SyncProgress> syncNew({
    required int accountId,
    int? maxItems,
    void Function(SyncProgress)? onProgress,
    SyncCancel? cancel,
  }) async {
    final state = db.loadSyncState(accountId);
    String? cursor;
    var pages = 0;
    var fetched = 0;
    var hitExisting = false;
    final collected = <LikeItem>[];
    final seen = <String>{};

    while (true) {
      if (cancel?.cancelled == true) break;
      if (maxItems != null && fetched >= maxItems) break;

      final page = await client.fetchLikes(cursor: cursor);
      var pageHasNew = false;
      for (final item in page.items) {
        if (db.hasTweet(item.tweetId)) {
          hitExisting = true;
          continue;
        }
        if (seen.add(item.tweetId)) {
          collected.add(item);
          pageHasNew = true;
        }
      }
      if (page.deletedTweetIds.isNotEmpty) {
        db.markDeleted(page.deletedTweetIds);
      }
      pages++;
      fetched = collected.length;

      onProgress?.call(SyncProgress(
        pages: pages,
        fetched: fetched,
        inserted: 0,
      ));

      cursor = page.bottomCursor;
      // 没有新条目、或已经撞上本地已有数据，就没必要继续翻
      if (!pageHasNew || hitExisting || !page.hasMore) break;
      await Future<void>.delayed(pace);
    }

    var inserted = 0;
    if (collected.isNotEmpty) {
      final base = state.maxSeq ?? 0;
      final startSeq = base + collected.length * AppDatabase.seqStep;
      final res = db.insertPage(
        collected,
        accountId: accountId,
        startSeq: startSeq,
      );
      inserted = res.inserted;
      db.saveSyncState(
        accountId,
        state.copyWith(
          maxSeq: db.maxSeqOverall(),
          minSeq: db.minSeqOverall(),
        ),
      );
    }

    onProgress?.call(SyncProgress(
      pages: pages,
      fetched: collected.length,
      inserted: inserted,
      done: true,
    ));
    return SyncProgress(
      pages: pages,
      fetched: collected.length,
      inserted: inserted,
      done: true,
    );
  }

  /// 取消喜欢：调接口 + 删本地记录。
  Future<void> unlike(String tweetId) async {
    await client.unlike(tweetId);
    db.deleteLike(tweetId);
  }
}

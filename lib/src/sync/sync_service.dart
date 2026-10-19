/// 同步服务：全量回填、增量更新、取消喜欢。
///
/// ## 这里踩过的坑（别再踩一次）
/// 1. **「本页没有 Bottom 游标」不等于「全量抓完了」**。X 的真实响应里出现过
///    「同一页既有 Bottom 游标、又有 TimelineTerminateTimeline」以及「游标被放在
///    我们不认识的 entry 类型里」两种情况。早期版本把 terminate 直接当成到底，
///    于是回填在 1000 条左右就标记完成、还顺手清掉续传游标 —— 用户每次点回填
///    都从头顶重走一遍，永远停在同一处。
/// 2. **续传游标只前进、不清空**。除非服务端连续几页都给不出可推进的游标，
///    否则一律保留，保证「点继续」永远真的接着上次的位置。
/// 3. **seq 锚点从数据库真实极值算**，不要信 `sync_state` 里存的值：中断、取消、
///    崩溃都会让它落后或错位，而 `feed_seq` 一旦分配重复，分页就会跳条。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../db/app_database.dart';
import '../model/like_item.dart';
import 'likes_parser.dart';
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
    this.note,
  });

  final int pages;
  final int fetched;
  final int inserted;

  /// 是否真的「服务端已经没有更多了」。暂停/被截断/限流都是 false。
  final bool done;
  final String? message;

  /// 诊断信息（每页条数、游标是否继续推进、terminate 标志），只在需要排查时用。
  final String? note;
}

class SyncService {
  SyncService({
    required this.db,
    required this.client,
    this.pace = const Duration(milliseconds: 1500),
    this.retryDelay,
    this.pageSize = 100,
  });

  final AppDatabase db;
  final XClient client;

  /// 请求间隔（秒级节流，降低风控概率）。
  final Duration pace;

  /// 被限流时的等待时间；null 表示按响应里的 `x-rate-limit-reset` 算。
  /// 测试里注入 `Duration.zero` 以免真的等。
  final Duration? retryDelay;

  /// 每页请求条数。X 实际返回可能少于这个数，不影响游标推进。
  final int pageSize;

  /// 最多重试几次（限流是暂时性的，值得等几次）。
  ///
  /// 注意：用尽之后**不算失败**，而是「本轮暂停」—— 游标已经落库，下次点继续
  /// 就从这里接着抓。早期版本 rethrow 出去，用户只看到一个红色错误，体验很差。
  static const int _maxRateLimitRetries = 2;

  /// 连续多少页「游标没推进」才认定真的到底（防止死循环，也不至于一次抖动就停）。
  static const int _staleCursorPages = 2;

  /// 连续多少页「解析出 0 条且没有游标」才认定到底。
  static const int _emptyPageLimit = 3;

  /// 取一页，遇到限流会退避重试。
  Future<LikesPage> _fetchPage(
    String? cursor, {
    void Function(String message)? onNotice,
  }) async {
    var attempt = 0;
    while (true) {
      try {
        return await client.fetchLikes(cursor: cursor, count: pageSize);
      } on XRequestException catch (e) {
        if (e.kind != XErrorKind.rateLimited ||
            attempt >= _maxRateLimitRetries) {
          rethrow;
        }
        attempt++;
        final wait =
            retryDelay ??
            _resetIn(e.resetAt) ??
            Duration(seconds: 15 * attempt);
        onNotice?.call('被 X 限流，${wait.inSeconds}s 后重试（第 $attempt 次）');
        await Future<void>.delayed(wait);
      }
    }
  }

  /// 从响应的 reset 时间推算要等多久（夹在 5 秒到 15 分钟之间）。
  Duration? _resetIn(DateTime? resetAt) {
    if (resetAt == null) return null;
    final delta = resetAt.difference(DateTime.now().toUtc());
    if (delta.isNegative) return const Duration(seconds: 5);
    if (delta > const Duration(minutes: 15)) {
      return const Duration(minutes: 15);
    }
    return delta < const Duration(seconds: 5)
        ? const Duration(seconds: 5)
        : delta;
  }

  /// 全量回填：从最旧没抓过的位置继续。
  ///
  /// [maxItems] 单次最多抓多少条（软上限）；[since] 只抓推文发布时间晚于它的。
  ///
  /// 返回值里的 [SyncProgress.done] 只有在「服务端确实没有更多」时才为 true。
  Future<SyncProgress> backfill({
    required int accountId,
    int? maxItems,
    DateTime? since,
    void Function(SyncProgress)? onProgress,
    SyncCancel? cancel,
  }) async {
    var state = db.loadSyncState(accountId);
    var cursor = state.backfillCursor;

    // seq 锚点一律从数据库真实极值推，避免脏掉的 sync_state 造成 seq 重复。
    final existingMin = db.minSeqOverall();
    var seqCursor = (existingMin ?? AppDatabase.seqStep) - AppDatabase.seqStep;

    var pages = 0;
    var fetched = 0;
    var inserted = 0;
    var exhausted = false;
    var paused = false;
    int? lastAligned;
    var staleCursorPages = 0;
    var emptyPages = 0;
    String? lastNote;

    while (true) {
      if (cancel?.cancelled == true) {
        paused = true;
        break;
      }
      if (maxItems != null && fetched >= maxItems) {
        paused = true;
        break;
      }

      final LikesPage page;
      try {
        page = await _fetchPage(
          cursor,
          onNotice: (msg) => onProgress?.call(
            SyncProgress(
              pages: pages,
              fetched: fetched,
              inserted: inserted,
              message: msg,
            ),
          ),
        );
      } on XRequestException catch (e) {
        // 限流用尽：本轮先收工，游标留着重来，别把「暂时抓不动」变成「报错」。
        if (e.kind == XErrorKind.rateLimited) {
          paused = true;
          lastNote = '限流：${e.message}';
          break;
        }
        rethrow;
      }

      final allItems = page.items;
      final items = since == null
          ? allItems
          : allItems
                .where(
                  (i) => i.createdAt == null || !i.createdAt!.isBefore(since),
                )
                .toList();

      if (page.deletedTweetIds.isNotEmpty) {
        db.markDeleted(page.deletedTweetIds);
      }

      if (items.isNotEmpty) {
        final pageStartSeq = seqCursor;
        final res = db.insertPage(
          items,
          accountId: accountId,
          startSeq: pageStartSeq,
        );
        inserted += res.inserted;
        fetched += items.length;
        pages++;

        // 本页占用的 seq 是 [res.nextSeq + step, pageStartSeq]，最小的是前者。
        final pageMinSeq = res.nextSeq + AppDatabase.seqStep;

        // 登记区段与它的起点游标，供巡边器将来重新翻到这一段。
        final aligned = db.segmentStartFor(pageStartSeq);
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

        state = state.copyWith(
          minSeq: pageMinSeq,
          // seq 越大越新：maxSeq 只在第一页确定下来（= 第一页的最大 seq），
          // 之后不能跟着往回填的进度往下掉。
          maxSeq: state.maxSeq ?? pageStartSeq,
        );
      }

      // ---- 游标推进判定 ----
      final next = page.bottomCursor;
      final advanced = next != null && next.isNotEmpty && next != cursor;
      staleCursorPages = advanced ? 0 : staleCursorPages + 1;

      // 有可推进的游标就记下来（连续两页同一个游标不再覆盖）。
      if (advanced) {
        cursor = next;
        state = state.copyWith(backfillCursor: cursor);
        db.saveSyncState(accountId, state);
      }

      if (allItems.isEmpty && items.isEmpty) {
        emptyPages++;
      } else {
        emptyPages = 0;
      }

      lastNote =
          '第 ${pages + 1} 页：${allItems.length} 条 '
          '(entry ${page.entryCount})，'
          'terminate=${page.terminatedBottom}，'
          '游标${advanced ? "前进" : "未前进"}';

      onProgress?.call(
        SyncProgress(
          pages: pages,
          fetched: fetched,
          inserted: inserted,
          note: lastNote,
        ),
      );

      // ---- 终止判定 ----
      if (!advanced) {
        // 拿到了内容但没有可推进的游标：这就是正常的「最后一页」。
        // 注意判据是「本页有没有东西」，而不是「有没有 terminate 指令」——
        // 真实响应里两者经常同时出现，早期版本只看 terminate 就清了游标。
        if (allItems.isNotEmpty || items.isNotEmpty || page.terminatedBottom) {
          exhausted = true;
          break;
        }
        // 空页：可能是服务端降级/抖动，多试几页再认到底。
        if (emptyPages >= _emptyPageLimit ||
            staleCursorPages >= _staleCursorPages) {
          exhausted = true;
          break;
        }
      }

      await Future<void>.delayed(pace);
    }

    state = state.copyWith(
      // 只有真到底才记「完成」；暂停/截断都保持未完成，让「继续回填」有意义。
      backfillDone: exhausted,
      // 游标**不清空**：万一这次是误判（或 X 后来又放开了深度限制），
      // 下次点「继续回填」还能从断点接着抓，而不是从头顶重走一遍。
      minSeq: db.minSeqOverall(),
      maxSeq: db.maxSeqOverall(),
    );
    db.saveSyncState(accountId, state);

    final result = SyncProgress(
      pages: pages,
      fetched: fetched,
      inserted: inserted,
      done: exhausted,
      message: exhausted ? null : (paused ? '已暂停（下次从这里继续）' : null),
      note: lastNote,
    );
    onProgress?.call(result);
    return result;
  }

  /// 增量：从最新往回翻，翻到已有条目就停。
  ///
  /// [since] 给它一个时间窗：早于它的条目既不收也不继续往下翻。
  /// 「从 X 网页回来补最近一天」用它 —— 不能为了补一天把几千条历史重新扫一遍。
  ///
  /// seq 约定「越大越新」，新增的喜欢必须排到现有最大 seq 之上。
  /// 因为整批条目是「新→旧」顺序、而 `insertPage` 是递减分配，
  /// 所以先把整批收集齐，再从 `maxSeq + n * step` 往下分配。
  Future<SyncProgress> syncNew({
    required int accountId,
    int? maxItems,
    DateTime? since,
    void Function(SyncProgress)? onProgress,
    SyncCancel? cancel,
  }) async {
    final state = db.loadSyncState(accountId);
    String? cursor;
    var pages = 0;
    var fetched = 0;
    var hitExisting = false;
    var hitSince = false;
    final collected = <LikeItem>[];
    final seen = <String>{};

    while (true) {
      if (cancel?.cancelled == true) break;
      if (maxItems != null && fetched >= maxItems) break;

      final LikesPage page;
      try {
        page = await _fetchPage(
          cursor,
          onNotice: (msg) => onProgress?.call(
            SyncProgress(
              pages: pages,
              fetched: fetched,
              inserted: 0,
              message: msg,
            ),
          ),
        );
      } on XRequestException catch (e) {
        if (e.kind == XErrorKind.rateLimited) break;
        rethrow;
      }

      var pageHasNew = false;
      final known = db.existingTweetIds(page.items.map((i) => i.tweetId));
      for (final item in page.items) {
        // 时间窗外的老条目：不收，并且整轮到此为止（X 按时间倒序返回）。
        final created = item.createdAt;
        if (since != null && created != null && created.isBefore(since)) {
          hitSince = true;
          continue;
        }
        if (known.contains(item.tweetId)) {
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

      onProgress?.call(
        SyncProgress(pages: pages, fetched: fetched, inserted: 0),
      );

      cursor = page.bottomCursor;
      // 没有新条目、撞上本地已有数据、或已经翻出时间窗，就没必要继续翻
      if (!pageHasNew ||
          hitExisting ||
          hitSince ||
          cursor == null ||
          cursor.isEmpty) {
        break;
      }
      if (page.terminatedBottom) break;
      await Future<void>.delayed(pace);
    }

    var inserted = 0;
    if (collected.isNotEmpty) {
      // 锚点用数据库真实极值：中断过的会话里 sync_state.maxSeq 可能是错的，
      // 用错值会让新喜欢插到列表中间（feed_seq 重复 → 分页跳条）。
      final base = db.maxSeqOverall() ?? state.maxSeq ?? 0;
      final startSeq = base + collected.length * AppDatabase.seqStep;
      final res = db.insertPage(
        collected,
        accountId: accountId,
        startSeq: startSeq,
      );
      inserted = res.inserted;
      db.saveSyncState(
        accountId,
        state.copyWith(maxSeq: db.maxSeqOverall(), minSeq: db.minSeqOverall()),
      );
    }

    final result = SyncProgress(
      pages: pages,
      fetched: collected.length,
      inserted: inserted,
      done: true,
    );
    onProgress?.call(result);
    return result;
  }

  /// 取消喜欢：调接口 + **标记**本地记录（不物理删除）。
  ///
  /// 标记成 `removed`（「我取消了喜欢」）而不是 `deleted`（「作者删了」）：
  /// - `removed` 的行不进任何列表（`fetchPage` 过滤），所以取消后立刻消失；
  /// - 整行数据（含已缓存媒体）保留，`like()` 能原样恢复过来。
  Future<void> unlike(String tweetId) async {
    await client.unlike(tweetId);
    db.markRemoved([tweetId]);
  }

  /// 重新喜欢（取消之后又点回来）。
  Future<void> like(String tweetId) async {
    await client.like(tweetId);
    db.restoreLike(tweetId);
  }
}

/// 只在调试时打一行进度（正式包里也留着，方便用户贴日志）。
void logSync(String message) {
  if (kDebugMode) debugPrint('[sync] $message');
}

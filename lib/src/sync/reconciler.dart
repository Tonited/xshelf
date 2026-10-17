/// 巡边器：把所有「同步」诉求收敛成一个带预算的队列。
///
/// 任务源（按优先级）：
///  1. 顶部新增 —— 由 SyncService.syncNew 实现，这里不重复。
///  2. 视口核对 —— 用户滚到哪儿停住，就把那一段标脏，插队核对 1 页。
///  3. 陈段轮转 —— 最久没核对过的区段，每次 tick 顺带处理一个。
///  4. 计数探针 —— 需要服务端总数，等 X 提供稳定字段后接上（TODO）。
///
/// 预算：任意两次请求间隔 ≥ [minInterval]，每分钟 ≤ [maxPerMinute] 次。
library;

import 'dart:async';
import 'dart:math' as math;

import '../db/app_database.dart';
import 'x_client.dart';

class ReconcileReport {
  const ReconcileReport({
    required this.source,
    required this.fetched,
    required this.removed,
    required this.inserted,
  });

  final String source;
  final int fetched;
  final int removed;
  final int inserted;
}

class Reconciler {
  Reconciler({
    required this.db,
    required this.client,
    required this.accountId,
    this.minInterval = const Duration(milliseconds: 1500),
    this.maxPerMinute = 4,
  });

  final AppDatabase db;
  final XClient client;
  final int accountId;
  final Duration minInterval;
  final int maxPerMinute;

  final List<int> _dirtySegments = [];
  DateTime? _lastRequest;
  final List<DateTime> _recent = [];

  /// 用户在某一段停留 → 标脏（已按区段起点去重）。
  void markViewportDirty(int startSeq, int endSeq) {
    final start = db.segmentStartFor(startSeq);
    if (_dirtySegments.contains(start)) return;
    _dirtySegments.add(start);
    if (_dirtySegments.length > 20) _dirtySegments.removeAt(0);
  }

  bool get _budgetAvailable {
    final now = DateTime.now();
    if (_lastRequest != null && now.difference(_lastRequest!) < minInterval) {
      return false;
    }
    _recent.removeWhere((t) => now.difference(t) > const Duration(minutes: 1));
    return _recent.length < maxPerMinute;
  }

  /// 跑一个任务。没有可做的返回 null。
  Future<ReconcileReport?> tick() async {
    if (!_budgetAvailable) return null;

    // 优先视口
    if (_dirtySegments.isNotEmpty) {
      final start = _dirtySegments.removeAt(0);
      return _verifySegment(start, 'viewport');
    }

    // 其次陈段轮转
    final stale = db.stalestSegments(accountId, limit: 1);
    if (stale.isNotEmpty) {
      final s = stale.first;
      final report = await _verifySegment(s.startSeq, 'rotate');
      return report;
    }
    return null;
  }

  Future<ReconcileReport?> _verifySegment(int startSeq, String source) async {
    final segWidth = AppDatabase.seqStep * 200;
    final endSeq = startSeq + segWidth;

    // 只有本地有货才值得核对
    final localIds = db.tweetIdsInSeqRange(startSeq, endSeq);
    if (localIds.isEmpty) return null;

    final cursor = _cursorFor(startSeq);
    if (cursor == null) return null;

    _lastRequest = DateTime.now();
    _recent.add(_lastRequest!);

    final page = await client.fetchLikes(cursor: cursor);
    final remoteIds = {for (final i in page.items) i.tweetId};

    // 1) 本地有、服务端没有 → 已在别处取消喜欢
    var removed = 0;
    for (final id in localIds.difference(remoteIds)) {
      db.deleteLike(id);
      removed++;
    }

    // 2) 服务端有、本地没有 → 漏抓，按顺序插回（seq 取相邻中点）
    var inserted = 0;
    if (page.items.isNotEmpty) {
      // 先标出每条在本地是否已有 seq，便于把「未知条目」放进两个已知锚点之间
      final seqs = [
        for (final item in page.items) localIds.contains(item.tweetId)
            ? db.seqOf(item.tweetId)
            : null,
      ];
      // 段顶部边界：比 startSeq 更「新」的条目的 seq
      var upper = db.neighborsOf(startSeq).above ?? startSeq + AppDatabase.seqStep;

      for (var i = 0; i < page.items.length; i++) {
        final known = seqs[i];
        if (known != null) {
          upper = known;
          continue;
        }
        int? lower;
        for (var j = i + 1; j < page.items.length; j++) {
          if (seqs[j] != null) {
            lower = seqs[j];
            break;
          }
        }
        final seq = db.seqBetween(
          lower ?? upper - AppDatabase.seqStep * 2,
          upper,
        );
        if (seq == null) continue;
        if (db.insertAtSeq(page.items[i], accountId: accountId, seq: seq)) {
          seqs[i] = seq;
          upper = seq;
          inserted++;
        }
      }
    }

    db.upsertSegment(
      accountId: accountId,
      startSeq: startSeq,
      endSeq: endSeq,
      cursor: cursor,
      verifiedAt: DateTime.now(),
    );

    return ReconcileReport(
      source: source,
      fetched: page.items.length,
      removed: removed,
      inserted: inserted,
    );
  }

  /// 找到能重新翻到 [startSeq] 所在区段的游标（由回填时登记）。
  String? _cursorFor(int startSeq) {
    final exact = db.segmentCursor(accountId, startSeq);
    if (exact != null) return exact;
    // 没登记过：退回到最近一个更「新」的区段游标（多翻几页也能对上）
    final segs = db.stalestSegments(accountId, limit: 500);
    final newer = segs.where((s) => s.startSeq < startSeq).toList()
      ..sort((a, b) => b.startSeq.compareTo(a.startSeq));
    return newer.isEmpty ? null : newer.first.cursor;
  }

  /// 后台循环：每 20 秒尝试一个任务（内部仍受预算限制）。
  Timer? _timer;
  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 20), (_) {
      unawaited(tick().catchError((_) => null));
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// 预算耗尽时最早可再请求的时间（给 UI 显示用）。
  Duration? get throttleRemaining {
    if (_lastRequest == null) return null;
    final elapsed = DateTime.now().difference(_lastRequest!);
    if (elapsed >= minInterval) return null;
    return minInterval - elapsed;
  }

  int get pendingViewportCount => _dirtySegments.length;

  static int clampInt(int v, int lo, int hi) => math.min(math.max(v, lo), hi);
}

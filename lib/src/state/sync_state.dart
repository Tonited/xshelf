/// 同步状态：回填/增量/取消喜欢 —— 也就是「数据怎么变多或变少」。
///
/// 只有真正关心进度的组件（顶部横幅、刷新按钮、设置页）监听这里；
/// 网格与时间轴监听 [BrowseState]，两者互不牵连。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/settings.dart';
import '../db/app_database.dart';
import '../sync/sync_service.dart';
import '../sync/x_client.dart';

class SyncController extends ChangeNotifier {
  SyncController({
    required this.db,
    required this.serviceOf,
    required this.accountIdOf,
    required this.autoSyncOf,
    required this.onDataChanged,
  });

  final AppDatabase db;
  final SyncService? Function() serviceOf;
  final int? Function() accountIdOf;
  final AutoSyncSettings Function() autoSyncOf;

  /// 同步改动数据之后回调（让浏览层刷新）。
  final Future<void> Function() onDataChanged;

  SyncProgress? progress;

  /// 上一次同步的结果（跑完之后展示一句，文案由 UI 决定）。
  SyncProgress? lastResult;
  String? error;
  SyncCancel? _cancel;

  bool get busy => _cancel != null;
  bool get backfillDone {
    final acc = accountIdOf();
    if (acc == null) return false;
    return db.loadSyncState(acc).backfillDone;
  }

  Future<void> startBackfill({int? maxItems}) => _run(
        (svc, acc, progress) =>
            svc.backfill(accountId: acc, maxItems: maxItems, onProgress: progress),
      );

  Future<void> syncNew() => _run(
        (svc, acc, progress) =>
            svc.syncNew(accountId: acc, maxItems: autoSyncOf().maxItems, onProgress: progress),
      );

  /// 上一次 [syncRecent] 的时间，用于节流。
  DateTime? _lastRecentAt;

  /// 从内嵌 X 网页回到 App 时补一次「最近一天」的喜欢。
  ///
  /// 网页里的喜欢是直接写进 X 服务器的，本地库完全不知情；不补的话，用户刚在
  /// 网页里点的心，回到列表里根本找不到。
  ///
  /// 两个约束：
  /// - **时间窗**：只收 [window] 内的，翻到更早的条目就停；
  /// - **节流**：20 秒内重复调用直接忽略 —— 进进出出几个网页不该反复拉同一批。
  Future<void> syncRecent({Duration window = const Duration(days: 1)}) {
    final now = DateTime.now();
    final last = _lastRecentAt;
    if (last != null && now.difference(last) < const Duration(seconds: 20)) {
      return Future<void>.value();
    }
    _lastRecentAt = now;
    return _run(
      (svc, acc, progress) => svc.syncNew(
        accountId: acc,
        since: now.toUtc().subtract(window),
        // 一天内不可能喜欢几百条；到了这个量说明游标有问题，别一直翻下去。
        maxItems: 300,
        onProgress: progress,
      ),
    );
  }

  Future<void> _run(
    Future<SyncProgress> Function(
      SyncService service,
      int accountId,
      void Function(SyncProgress) onProgress,
    ) action,
  ) async {
    final svc = serviceOf();
    final acc = accountIdOf();
    if (svc == null || acc == null || busy) return;

    final cancel = SyncCancel();
    _cancel = cancel;
    error = null;
    lastResult = null;
    progress = const SyncProgress(pages: 0, fetched: 0, inserted: 0);
    notifyListeners();

    try {
      final result = await action(svc, acc, (p) {
        progress = p;
        notifyListeners();
      });
      // 跑完就把进度条收掉：以前 done 的横幅会一直挂在顶上，
      // 停止按钮也变成无效按钮。
      progress = null;
      lastResult = result;
      await onDataChanged();
    } on XRequestException catch (e) {
      progress = null;
      error = e.message;
    } catch (e) {
      progress = null;
      error = '$e';
    } finally {
      _cancel = null;
      notifyListeners();
    }
    // 结果横幅只是「告诉你这次干了什么」，看到就够了 —— 4 秒后自动收掉，
    // 不用再手动点关闭（错误信息多留一会儿，方便看清原因）。
    _autoClear?.cancel();
    _autoClear = Timer(Duration(seconds: error != null ? 6 : 4), () {
      if (progress != null || busy) return;
      if (lastResult == null && error == null) return;
      lastResult = null;
      error = null;
      notifyListeners();
    });
  }

  /// 自动收掉结果横幅的定时器。
  Timer? _autoClear;

  void cancel() => _cancel?.cancel();

  /// 取消喜欢：调接口 + 删本地记录。成功返回 null，失败返回可展示的文案。
  ///
  /// 本地列表的移除由调用方（AppController）转给 [BrowseState]，避免一次
  /// 网络操作引发整页重新查库。
  Future<String?> unlike(String tweetId) async {
    final svc = serviceOf();
    if (svc == null) return '未登录';
    try {
      await svc.unlike(tweetId);
      return null;
    } on XRequestException catch (e) {
      return e.message;
    } catch (e) {
      return '$e';
    }
  }

  /// 重新喜欢（取消之后又点回来）。
  Future<String?> like(String tweetId) async {
    final svc = serviceOf();
    if (svc == null) return '未登录';
    try {
      await svc.like(tweetId);
      return null;
    } on XRequestException catch (e) {
      return e.message;
    } catch (e) {
      return '$e';
    }
  }

  void clear() {
    _autoClear?.cancel();
    if (error == null && progress == null && lastResult == null) return;
    error = null;
    progress = null;
    lastResult = null;
    notifyListeners();
  }

  void reset() {
    _autoClear?.cancel();
    _cancel?.cancel();
    _cancel = null;
    progress = null;
    lastResult = null;
    error = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _autoClear?.cancel();
    super.dispose();
  }
}

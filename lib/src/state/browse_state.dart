/// 浏览状态：列表内容、排序模式、筛选、选中项 —— 也就是「看什么」。
///
/// 从 [AppController] 里拆出来的原因：
/// - 同步进度每抓一页就 `notifyListeners()` 一次，以前整个页面（含上千张卡片）
///   跟着重建；现在关心进度的组件只监听 [SyncController]，网格只监听这里。
/// - 时间轴要「扫全表」的聚合（桶、月份、seq 区间），以前散在 UI 和 DB 里各查一次；
///   现在统一在这里缓存，数据变了才失效。
library;

import 'package:flutter/foundation.dart';

import '../core/settings.dart';
import '../db/app_database.dart';
import '../model/like_item.dart';

typedef ViewPersister = Future<void> Function(ViewSnapshot snapshot);

/// 时间轴上的一个估算桶（模式 A）。
typedef TimelineBucket = ({
  int fromSeq,
  int toSeq,
  int count,
  DateTime? approxDate,
});

class BrowseState extends ChangeNotifier {
  BrowseState({required this.db, required this.persistView});

  final AppDatabase db;

  /// 把「上次看到哪」写进设置。
  final ViewPersister persistView;

  /// 每页加载多少条。60 在 4 列桌面网格上大约两屏，滚动时不容易看见空档。
  static const int pageSize = 60;

  SortMode mode = SortMode.likeOrder;
  LikesFilter filter = const LikesFilter();

  final List<LikeItem> _items = [];
  List<LikeItem> get items => _items;

  PageKey? _nextKey;
  bool loadingPage = false;
  bool hasMore = true;
  int totalCount = 0;
  LikedStats stats = const LikedStats(total: 0, videos: 0, images: 0, deleted: 0);
  String? selectedTweetId;

  bool get isEmpty => _items.isEmpty;

  // ------------------------------------------------------------ 派生数据缓存
  List<TimelineBucket>? _estimated;
  List<MonthBucket>? _months;
  ({int? minSeq, int? maxSeq})? _bounds;
  List<AuthorCount>? _authors;

  /// 选中项（网格高亮 + 详情栏共用）。列表变动时置空，下次访问重算。
  LikeItem? _selected;
  bool _selectedStale = true;

  LikeItem? get selectedItem {
    final id = selectedTweetId;
    if (id == null) return null;
    if (!_selectedStale) return _selected;
    _selectedStale = false;
    _selected = null;
    for (final item in _items) {
      if (item.tweetId == id) {
        _selected = item;
        break;
      }
    }
    return _selected;
  }

  /// 数据变了：时间轴/作者列表/选中项缓存全部作废。
  void invalidate() {
    _estimated = null;
    _months = null;
    _bounds = null;
    _authors = null;
    _selectedStale = true;
  }

  List<TimelineBucket> estimatedTimeline() => _estimated ??= db.estimatedBuckets();

  List<MonthBucket> months() => _months ??= db.months();

  ({int? minSeq, int? maxSeq}) bounds() => _bounds ??= db.seqBounds();

  List<AuthorCount> topAuthors({int limit = 100}) =>
      _authors ??= db.topAuthors(limit: limit);

  // ---------------------------------------------------------------- 加载与分页

  void restoreFrom(ViewSnapshot v) {
    mode = v.mode;
    filter = v.filter;
    selectedTweetId = v.selectedTweetId;
    _selectedStale = true;
  }

  Future<void> saveView({double? scrollOffset}) => persistView(ViewSnapshot(
        mode: mode,
        filter: filter,
        anchorSeq: _items.isNotEmpty ? _items.first.feedRank : null,
        selectedTweetId: selectedTweetId,
        scrollOffset: scrollOffset ?? 0,
      ));

  Future<void> reload({bool reset = false}) async {
    if (reset) {
      _items.clear();
      _nextKey = null;
      hasMore = true;
      invalidate();
    }
    stats = db.stats();
    totalCount = stats.normal;
    await loadMore();
  }

  /// 同步结束后刷新：尽量留在原地，而不是把用户弹回顶部。
  ///
  /// 刷新后仍有 5 万条的列表，回到顶部是纯损失；用「当前第一条」当锚点
  /// 重新取一页，滚动位置和上下文都保住了。
  Future<void> refresh({bool keepPosition = true}) async {
    invalidate();
    stats = db.stats();
    totalCount = stats.normal;
    final anchor = keepPosition && _items.isNotEmpty ? _items.first.feedRank : null;
    if (anchor == null) {
      await reload(reset: true);
      notifyListeners();
      return;
    }
    _items.clear();
    hasMore = true;
    _nextKey = PageKey(seq: anchor + 1);
    await loadMore();
    notifyListeners();
  }

  Future<void> loadMore() async {
    if (loadingPage || !hasMore) return;
    loadingPage = true;
    notifyListeners();
    try {
      final page = db.fetchPage(
        mode: mode,
        filter: filter,
        limit: pageSize,
        after: _nextKey,
      );
      _items.addAll(page.items);
      _nextKey = page.key;
      hasMore = page.key != null;
      // 注意：这里**不**清时间轴缓存。翻页只是把已有行读出来，聚合结果没变；
      // 清掉的话每次滚到底部都要重算一遍月份/分桶（5 万条要几十毫秒）。
      _selectedStale = true;
    } finally {
      loadingPage = false;
      notifyListeners();
    }
  }

  Future<void> setMode(SortMode m) async {
    if (m == mode) return;
    mode = m;
    await reload(reset: true);
    await saveView();
  }

  Future<void> setFilter(LikesFilter f) async {
    filter = f;
    await reload(reset: true);
    await saveView();
  }

  Future<void> reshuffle() async {
    db.reshuffle();
    if (mode == SortMode.random) {
      await reload(reset: true);
    } else {
      notifyListeners();
    }
  }

  /// 时间轴跳转：把列表锚定到某个 seq（喜欢顺序）。
  Future<void> jumpToSeq(int seq) async {
    _items.clear();
    hasMore = true;
    _nextKey = PageKey(seq: seq + 1);
    invalidate();
    notifyListeners();
    await loadMore();
    await saveView();
  }

  /// 时间轴跳转：跳到某个发布月份（`YYYY-MM`）。
  Future<void> jumpToMonth(String month) async {
    if (mode == SortMode.random) await setMode(SortMode.publishDate);
    final seq = db.newestSeqInMonth(month);
    if (seq == null) return;
    await jumpToSeq(seq);
  }

  void select(String? tweetId) {
    selectedTweetId = tweetId;
    _selectedStale = true;
    notifyListeners();
  }

  /// 本地移除一条（取消喜欢之后）。
  void dropLocal(String tweetId) {
    _items.removeWhere((i) => i.tweetId == tweetId);
    if (selectedTweetId == tweetId) selectedTweetId = null;
    totalCount = db.countLikes(includeDeleted: false);
    invalidate();
    notifyListeners();
  }

  /// 退出登录：清空一切。
  void resetAll() {
    _items.clear();
    _nextKey = null;
    hasMore = true;
    totalCount = 0;
    stats = const LikedStats(total: 0, videos: 0, images: 0, deleted: 0);
    selectedTweetId = null;
    invalidate();
    notifyListeners();
  }
}

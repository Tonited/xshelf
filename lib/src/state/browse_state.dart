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
import 'feed_source.dart';

typedef ViewPersister = Future<void> Function(ViewSnapshot snapshot);

/// 时间轴上的一个估算桶（模式 A）。
typedef TimelineBucket = ({
  int fromSeq,
  int toSeq,
  int count,
  DateTime? approxDate,
});

class BrowseState extends ChangeNotifier implements FeedSource {
  BrowseState({required this.db, required this.persistView});

  final AppDatabase db;

  /// 把「上次看到哪」写进设置。
  final ViewPersister persistView;

  /// 每页加载多少条。60 在 4 列桌面网格上大约两屏，滚动时不容易看见空档。
  static const int pageSize = 60;

  SortMode mode = SortMode.likeOrder;
  LikesFilter filter = const LikesFilter();

  /// 列表被拆成两段，原因见 [loadPrev]：
  /// - [_older]：「当前位置」以上的条目（更新的），往前翻时往里塞；
  /// - [_items]：「当前位置」及以下（默认从这里开始往后翻）。
  ///
  /// UI 用 `center` sliver 把它们拼成一个连续列表，于是「往上补一页」时
  /// 滚动位置 0 对应的那条**原地不动**，新内容自然地出现在滚动条上方。
  final List<LikeItem> _older = [];
  final List<LikeItem> _items = [];

  /// `_older + _items` 的缓存。每次改动重建一次，getter 不重新分配。
  List<LikeItem> _all = const [];

  /// 本次会话里取消过喜欢的 id（列表视图要滤掉这些）。
  final Set<String> _removed = {};

  /// 给**列表**用的视图（已经滤掉 [_removed]）。播放页仍用 [items]，
  /// 这样取消喜欢之后还能在当前页点回去。
  List<LikeItem> _listAll = const [];
  int _listOlderCount = 0;

  @override
  List<LikeItem> get items => _all;

  /// [_items] 在 [items] 里的起始下标（也就是「center」那一条的位置）。
  int get olderCount => _older.length;

  /// 列表页要显示的条目（滤掉了本次取消的喜欢）。
  List<LikeItem> get listItems => _listAll;

  /// [listItems] 里 [_items] 的起始下标。
  int get listOlderCount => _listOlderCount;

  /// 取消喜欢后记一笔：列表立刻不再显示它（播放页仍保留，方便点回喜欢）。
  void markRemoved(String tweetId) {
    if (_removed.add(tweetId)) {
      _rebuildAll();
      totalCount = db.countLikes(includeDeleted: false);
      notifyListeners();
    }
  }

  /// 又点回来了：把记录撤掉，列表重新显示。
  void unmarkRemoved(String tweetId) {
    if (_removed.remove(tweetId)) {
      _rebuildAll();
      totalCount = db.countLikes(includeDeleted: false);
      notifyListeners();
    }
  }

  void _rebuildAll() {
    if (_older.isEmpty) {
      _all = List.unmodifiable(_items);
    } else {
      _all = List.unmodifiable([..._older, ..._items]);
    }
    // 本次会话里「取消了喜欢」的条目：播放页还留着它（方便点回喜欢），
    // 但列表里要立刻消失。所以这里单独算一份给列表用的视图 + 对应的锚点位置。
    if (_removed.isEmpty) {
      _listAll = _all;
      _listOlderCount = _older.length;
      return;
    }
    final visible = [
      for (final item in _older)
        if (!_removed.contains(item.tweetId)) item,
    ];
    final visibleItems = [
      for (final item in _items)
        if (!_removed.contains(item.tweetId)) item,
    ];
    _listOlderCount = visible.length;
    _listAll = List.unmodifiable([...visible, ...visibleItems]);
  }

  PageKey? _nextKey;
  bool loadingPage = false;
  bool hasMore = true;

  /// 下一次 [loadMore] 是否要从 `_nextKey` 指向的那条**本身**开始。
  ///
  /// 「跳到第 N 条」之后，列表的第一条就应该是那一条，而不是它的下一条。
  bool _nextInclusive = false;

  /// 往「前」（更新的方向）翻的游标 + 那个方向还有没有。
  ///
  /// 平时是 null：从最新开始看时上面没有更新的东西。只有跳转到中间之后，
  /// 才会记下当前第一条，用来「上拉加载上一页」。
  PageKey? _prevKey;
  bool hasOlder = false;
  bool loadingPrev = false;

  int totalCount = 0;
  LikedStats stats = const LikedStats(total: 0, videos: 0, images: 0, deleted: 0);
  String? selectedTweetId;

  bool get isEmpty => _all.isEmpty;

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
    for (final item in _all) {
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
      _older.clear();
      _rebuildAll();
      _nextKey = null;
      _nextInclusive = false;
      _prevKey = null;
      hasOlder = false;
      hasMore = true;
      invalidate();
    }
    stats = db.stats();
    totalCount = stats.normal;
    await loadMore();
  }

  /// 同步结束后刷新：尽量留在原地，同时把**新同步进来的条目**放到正确位置。
  ///
  /// 以前只是「按锚点重新取一页」，于是刚拉下来的新喜欢一条都进不了列表 ——
  /// 用户看到的就是「刷新了但什么也没多」。现在多一步：取完锚点那一页，
  /// 再把「比锚点新」的补到 center 上方（[_older]），当前位置仍然不动。
  Future<void> refresh({bool keepPosition = true}) async {
    invalidate();
    stats = db.stats();
    totalCount = stats.normal;

    final anchorKey =
        (keepPosition && _items.isNotEmpty) ? _keyOf(_items.first) : null;
    if (anchorKey == null) {
      await reload(reset: true);
      notifyListeners();
      return;
    }

    _items.clear();
    _older.clear();
    _rebuildAll();
    hasMore = true;
    _nextKey = anchorKey;
    _nextInclusive = true;
    await loadMore();

    if (_items.isNotEmpty) {
      _prevKey = _keyOf(_items.first);
      hasOlder = _prevKey != null;
      if (hasOlder) await loadPrev();
    }
    notifyListeners();
  }

  @override
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
        includeStart: _nextInclusive,
      );
      _nextInclusive = false;
      _items.addAll(page.items);
      _rebuildAll();
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

  /// 往「更新的方向」补一页，放到「当前位置」**上方**。
  ///
  /// 关键：插入的是 [_older] 而不是 [_items]。UI 用 `center` sliver 把两段
  /// 拼起来，所以往 [_older] 里加东西不会挪动当前位置 —— 新的一页出现在
  /// 滚动条上方，用户继续往上滚就能看到，而不是被顶下去。
  Future<void> loadPrev() async {
    if (loadingPrev || !hasOlder) return;
    final before = _prevKey;
    if (before == null) {
      hasOlder = false;
      notifyListeners();
      return;
    }
    loadingPrev = true;
    notifyListeners();
    try {
      final page = db.fetchPage(
        mode: mode,
        filter: filter,
        limit: pageSize,
        before: before,
      );
      if (page.items.isEmpty) {
        hasOlder = false;
      } else {
        // page.items 是正序（新→旧），它们比当前所有条目都更新，
        // 所以整体插到 _older 的最前面。
        _older.insertAll(0, page.items);
        _rebuildAll();
        _prevKey = page.key;
        hasOlder = page.key != null;
        _selectedStale = true;
      }
    } finally {
      loadingPrev = false;
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

  /// 把列表锚定到某个游标：第一条就是它（`includeStart`）。
  ///
  /// 跳转之后 `_prevKey` 记下这条，于是下拉可以「加载上一页」。
  /// [fromTop] 表示跳到的其实就是最顶上那一条 —— 那时上面没有更新的东西，
  /// 不该让用户下拉时白跑一次空查询。
  Future<void> _jumpToKey(PageKey key, {bool fromTop = false}) async {
    _items.clear();
    _older.clear();
    _rebuildAll();
    hasMore = true;
    _nextKey = key;
    _nextInclusive = true;
    _prevKey = null;
    hasOlder = false;
    invalidate();
    notifyListeners();
    await loadMore();
    if (!fromTop && _items.isNotEmpty) {
      _prevKey = _keyOf(_items.first);
      hasOlder = _prevKey != null;
    }
    notifyListeners();
    await saveView();
  }

  PageKey? _keyOf(LikeItem item) => switch (mode) {
        SortMode.likeOrder =>
          item.feedRank == null ? null : PageKey(seq: item.feedRank),
        SortMode.publishDate => item.createdAt == null
            ? null
            : PageKey(
                publishedAt: item.createdAt!.millisecondsSinceEpoch,
                tweetId: item.tweetId,
              ),
        SortMode.random =>
          item.randKey == null ? null : PageKey(randKey: item.randKey),
      };

  /// 时间轴跳转：把列表锚定到某个 seq（喜欢顺序）。
  Future<void> jumpToSeq(int seq) => _jumpToKey(PageKey(seq: seq));

  /// 把列表锚定到**某一条**（三种排序各用各的游标）。
  ///
  /// 播放页返回时用它：用户在播放页里上下滑到了第 N 条，回到列表不该还停在
  /// 进来时那一条上，应该跟着落回刚才看的那条。
  ///
  /// 定位完目标条目就是列表第一条，调用方再把滚动位置归零即可（和
  /// [jumpToOffset] 的用法一致）。游标取不到的条目（没有时间/没有 seq）不动。
  Future<void> jumpToItem(LikeItem item) async {
    final key = _keyOf(item);
    if (key == null) return;
    await _jumpToKey(key);
  }

  /// 跳到「当前排序 + 筛选下的第 N 条」（0 基）。
  ///
  /// 这是「顺序位置跳转」：给一个滑块或输入框，直接落到那一条。
  Future<void> jumpToOffset(int offset) async {
    final key = db.keyAtOffset(
      mode: mode,
      filter: filter,
      offset: offset.clamp(0, (totalCount - 1).clamp(0, 1 << 30)),
    );
    if (key == null) return;
    await _jumpToKey(key, fromTop: offset == 0);
  }

  /// 跳到某个**发布日期**。
  ///
  /// 不再按月份猜：直接按 `created_at <= 日期…` 找到那天最新的一条，
  /// 再落到它在当前排序里的位置。
  /// - 发布日期模式：用 (created_at, tweet_id) 游标；
  /// - 喜欢顺序模式：拿那条的 `feed_seq` 定位（喜欢顺序与发布时间无关，
  ///   所以「跳到日期」在这里的含义是「跳到那天最新那条的位置」）；
  /// - 随机模式：没有顺序可言，不支持。
  Future<void> jumpToDate(DateTime date) async {
    if (mode == SortMode.random) return;
    if (mode == SortMode.publishDate) {
      final key = db.keyAtOrBeforeDate(filter: filter, date: date);
      if (key == null) return;
      await _jumpToKey(key);
      return;
    }
    final seq = db.seqAtOrBeforeDate(filter: filter, date: date);
    if (seq == null) return;
    await jumpToSeq(seq);
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
  @override
  void dropLocal(String tweetId) {
    _items.removeWhere((i) => i.tweetId == tweetId);
    _older.removeWhere((i) => i.tweetId == tweetId);
    _rebuildAll();
    if (selectedTweetId == tweetId) selectedTweetId = null;
    totalCount = db.countLikes(includeDeleted: false);
    invalidate();
    notifyListeners();
  }

  /// 退出登录：清空一切。
  void resetAll() {
    _items.clear();
    _older.clear();
    _rebuildAll();
    _nextKey = null;
    hasMore = true;
    hasOlder = false;
    _prevKey = null;
    totalCount = 0;
    stats = const LikedStats(total: 0, videos: 0, images: 0, deleted: 0);
    selectedTweetId = null;
    invalidate();
    notifyListeners();
  }
}

/// 按任意筛选条件分页的一份列表（作者空间、搜索结果都用它）。
///
/// 主列表有自己的 [BrowseState]（带模式/时间轴/锚点），而这两处只需要「按条件
/// 翻页」这一个能力 —— 共用一个实现比复制两遍分页代码稳。
library;

import 'package:flutter/foundation.dart';

import '../db/app_database.dart';
import '../model/like_item.dart';
import 'feed_source.dart';

class QueryFeedSource extends ChangeNotifier implements FeedSource {
  QueryFeedSource({
    required this.db,
    required this.filter,
    this.mode = SortMode.publishDate,
    this.pageSize = 40,
  });

  final AppDatabase db;
  LikesFilter filter;
  final SortMode mode;
  final int pageSize;

  final List<LikeItem> _items = [];
  PageKey? _nextKey;
  bool _loading = false;
  bool _hasMore = true;
  int _generation = 0;

  /// 页面可能在请求飞在路上时被销毁：`notifyListeners` 在 dispose 之后会 assert。
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  @override
  List<LikeItem> get items => _items;

  bool get loading => _loading;
  bool get hasMore => _hasMore;

  /// 换条件：作废当前结果并重新取第一页。
  Future<void> reset(LikesFilter next) async {
    filter = next;
    _items.clear();
    _nextKey = null;
    _hasMore = true;
    _generation++;
    _emit();
    await loadMore();
  }

  @override
  Future<void> loadMore() async {
    if (_loading || !_hasMore) return;
    final gen = _generation;
    _loading = true;
    _emit();
    try {
      final page = db.fetchPage(
        mode: mode,
        filter: filter,
        limit: pageSize,
        after: _nextKey,
      );
      // reset() 在 await 期间被调用过：这批结果已经过期，直接丢掉。
      if (gen != _generation) return;
      _items.addAll(page.items);
      _nextKey = page.key;
      _hasMore = page.key != null;
    } finally {
      if (gen == _generation) {
        _loading = false;
        _emit();
      }
    }
  }

  @override
  void dropLocal(String tweetId) {
    _items.removeWhere((i) => i.tweetId == tweetId);
    _emit();
  }
}

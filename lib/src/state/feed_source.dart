/// 播放页的数据来源。
///
/// 主列表（[BrowseState]）和作者空间都需要喂同一个全屏播放页，但两者的分页规则
/// 完全不同。抽一个最小接口，播放页就只关心「有哪些条、还能不能更多、删一条」。
library;

import 'package:flutter/foundation.dart';

import '../model/like_item.dart';

abstract interface class FeedSource implements Listenable {
  List<LikeItem> get items;
  Future<void> loadMore();
  void dropLocal(String tweetId);
}

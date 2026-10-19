/// 打开内嵌 X 网页的页面，并在**返回时**自动补一次「最近一天」的喜欢。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../app_controller.dart';

/// 打开一个 X 网页页面；用户从它回到 App 后，后台同步最近一天的喜欢。
///
/// 为什么要统一在这里做：X 网页里点出的喜欢/取消喜欢只发生在 X 的服务器上，
/// 本地库完全不知道。以前要等下拉刷新或下一次自动同步，「刚在网页里点的心
/// 回到列表却没有」，看起来就像同步坏了。
///
/// [page] 必须是自建路由的整页（`XWebPage`、`XSearchPage`、`SwipeFeedPage`），
/// 不要传已经由别处 push 过的实例。
Future<void> openXPage(BuildContext context, Widget page) async {
  final app = AppScope.read(context);
  await Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => page),
  );
  // 这里不再摸 context：回来的可能是 App 真要退出的时刻，而同步只需要 app 本身。
  unawaited(app.sync.syncRecent());
}

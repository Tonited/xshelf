/// 主界面：X 风格的一列图文列表（手机单列、宽屏居中收窄）。
///
/// 和上一版最大的区别：
/// - 网格被**列表**整体替换 —— 喜欢里大量是纯文字，网格只能看到一个色块，
///   正文、作者、时间全丢了；
/// - 右侧那条竖向时间轴删掉了（在小屏上它挡住内容、又不好点），只留顶部的
///   年月下拉，精确跳转；
/// - 点任意一条进全屏滑播页，点头像进作者空间；
/// - 底部导航的「搜索」以前点了没反应（回调里只处理了设置），现在有独立搜索页。
///
/// 重建范围仍然收得很紧：列表只订阅 [BrowseState]，同步横幅只订阅
/// [SyncController]，同步每抓一页刷进度时列表不重建。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../core/l10n.dart';
import '../db/app_database.dart';
import '../model/like_item.dart';
import '../state/browse_state.dart';
import '../state/sync_state.dart';
import 'author_page.dart';
import 'feed_page.dart';
import 'post_card.dart';
import 'search_page.dart';
import 'settings_page.dart';
import 'swipe_feed_page.dart';
import 'x_nav.dart';
import 'x_web_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  final ScrollController _scroll = ScrollController();
  Timer? _saveDebounce;
  bool _restored = false;

  /// `CustomScrollView` 的「中心」。
  ///
  /// 中心之上放「往前翻出来的、更新的条目」，中心之下放当前的列表。
  /// 往中心上方追加内容时，滚动位置 0 仍然对应中心那一条 —— 这就是
  /// 「加载上一页时当前位置不动」的全部秘密。
  final GlobalKey _centerKey = GlobalKey();

  /// 在 didChangeDependencies 里取一次，避免在滚动回调里依赖 InheritedWidget。
  AppController? _app;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _restorePosition());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _app = AppScope.read(context);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scroll.dispose();
    _saveDebounce?.cancel();
    super.dispose();
  }

  /// 切后台/被系统回收前再存一次位置。
  ///
  /// 平时靠滚动停止 1.2s 的防抖保存，但如果用户滚完立刻切走/杀掉，
  /// 那一次就丢了 —— 这里补一刀，保证「下次打开在原位置」。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) return;
    final app = _app;
    if (app == null || !_scroll.hasClients) return;
    app.browse.saveView(scrollOffset: _scroll.position.pixels);
  }

  /// 恢复上次的位置（冷启动只加载了第一页，所以要先按锚点重新取一页再套像素偏移）。
  ///
  /// 位移按**当前 Tab** 取：三个排序各自记过自己的位置。
  Future<void> _restorePosition() async {
    if (_restored) return;
    _restored = true;
    final app = _app;
    if (app == null || !mounted) return;
    final view = app.settings.view;
    final browse = app.browse;

    final anchor = view.anchorSeq;
    final firstSeq = browse.items.isNotEmpty
        ? browse.items.first.feedRank
        : null;
    if (anchor != null && browse.items.isNotEmpty && anchor != firstSeq) {
      await browse.jumpToSeq(anchor);
      if (!mounted) return;
    }
    final saved = app.settings.scrollOf(browse.mode.name);
    final offset = saved > 0 ? saved : view.scrollOffset;
    if (offset > 0 && _scroll.hasClients) {
      final max = _scroll.position.maxScrollExtent;
      _scroll.jumpTo(offset.clamp(0, max));
    }
  }

  /// 切 Tab：记住当前 Tab 的位置，切过去之后再恢复到目标 Tab 上次的位置。
  Future<void> _switchMode(SortMode mode) async {
    final app = _app;
    if (app == null) return;
    final browse = app.browse;
    if (browse.mode == mode) return;

    if (_scroll.hasClients) {
      await app.settings.setScrollOf(browse.mode.name, _scroll.position.pixels);
    }
    await browse.setMode(mode);
    if (!mounted) return;
    // 列表刚换了一批数据，等它布局完再落位置。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Timer(const Duration(milliseconds: 80), () {
        if (!mounted || !_scroll.hasClients) return;
        final target = app.settings.scrollOf(mode.name);
        final max = _scroll.position.maxScrollExtent;
        _scroll.jumpTo(target.clamp(0, max));
      });
    });
  }

  /// 回到当前 Tab 的顶部（点底栏的「喜欢」触发）。
  void _scrollToTop() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      _scroll.position.minScrollExtent,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  void _onScroll() {
    final app = _app;
    if (app == null || !mounted || !_scroll.hasClients) return;
    final browse = app.browse;
    final pos = _scroll.position;
    // 往后翻（更旧）
    if (pos.pixels >= pos.maxScrollExtent - 800) browse.loadMore();
    // 往前翻（更新）：滚到当前顶边附近就补一页。补进去的内容放在
    // center 上方，所以当前位置不会动，用户继续往上滚就能看到。
    if (browse.hasOlder && pos.pixels <= pos.minScrollExtent + 500) {
      browse.loadPrev();
    }
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 1200), () {
      if (!mounted) return;
      app.browse.saveView(scrollOffset: pos.pixels);
      // 按 Tab 记一份位置：切走再切回来、重启 App 都能回到原处。
      unawaited(app.settings.setScrollOf(browse.mode.name, pos.pixels));
      // 停住就看：把当前已加载的这一段交给巡边器核对（内部有 1.5s/次、4 次/分的预算）
      if (browse.listItems.isNotEmpty) {
        final first = browse.listItems.first.feedRank;
        final last = browse.listItems.last.feedRank;
        if (first != null && last != null) app.markViewportDirty(last, first);
      }
    });
  }

  /// 打开播放页；返回后把列表**滚回刚才看的那一条**。
  ///
  /// 位置从播放页一路上报的 [FeedPage.onCurrentChanged] 拿，而不是靠 pop 结果：
  /// Android 的系统返回键和侧滑返回都不会带 result，靠 result 的话那两条路上
  /// 定位就失效了。pop 结果只是顺手留着（App 内返回按钮会带）。
  Future<void> _openFeed(String tweetId) async {
    final app = _app;
    if (app == null) return;
    var lastSeen = tweetId;
    await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (_) => FeedPage(
          source: app.browse,
          // 按 id 定位而不是按下标：列表滤掉了本次取消喜欢的条目，
          // 下标和源头的 items 对不上。
          initialTweetId: tweetId,
          cache: app.mediaCache,
          onCurrentChanged: (id) => lastSeen = id,
        ),
      ),
    );
    if (!mounted) return;
    final targetId = lastSeen;
    // 只是在原地进来又原样回去（没在播放页里滑走）的话，位置本来就没变，
    // 别为了「滚动」把整段列表重新锚一遍。
    if (targetId == tweetId) return;
    final at = app.browse.items.indexWhere((i) => i.tweetId == targetId);
    if (at < 0) return;
    await app.browse.jumpToItem(app.browse.items[at]);
    if (!mounted || !_scroll.hasClients) return;
    _scroll.jumpTo(0);
  }

  void _openAuthor(LikeItem item) {
    final author = item.author;
    if (author == null || author.screenName.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AuthorPage(author: author, cache: _app?.mediaCache),
      ),
    );
  }

  void _openSearch() {
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const SearchPage()));
  }

  @override
  Widget build(BuildContext context) {
    // 用 of 而不是 read：设置一变（自动翻译、低数据模式、显示项…）列表要立刻跟着重建，
    // 不然「在设置里开了自动翻译，回到列表却什么都没变」，看起来就像功能没做。
    final app = AppScope.of(context);

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: Text(t('list.title')),
        actions: [
          // 总数放在跳转按钮左边：它是「我有多少东西」的上下文，
          // 和跳转（在总量里定位）本来就是一组。
          ListenableBuilder(
            listenable: app.browse,
            builder: (context, _) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Center(
                child: Text(
                  '${app.browse.totalCount}',
                  style: Theme.of(context).textTheme.labelLarge
                      ?.copyWith(color: Theme.of(context).colorScheme.outline),
                ),
              ),
            ),
          ),
          // 跳转只留一个图标：位置跳（喜欢顺序）或日期跳（按发布日期），
          // 随机模式没有顺序可言，直接不显示。
          ListenableBuilder(
            listenable: app.browse,
            builder: (context, _) {
              if (app.browse.mode == SortMode.random) {
                return const SizedBox.shrink();
              }
              return IconButton(
                tooltip: app.browse.mode == SortMode.likeOrder
                    ? t('jump.byPosition')
                    : t('jump.byDate'),
                onPressed: () => _openJumpSheet(context, app),
                icon: const Icon(Icons.my_location),
              );
            },
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(44),
          child: ListenableBuilder(
            listenable: app.browse,
            builder: (context, _) =>
                _ModeBar(browse: app.browse, onModeChanged: _switchMode),
          ),
        ),
      ),
      body: Column(
        children: [
          ListenableBuilder(
            listenable: app.sync,
            builder: (context, _) => _SyncBanner(sync: app.sync),
          ),
          Expanded(
            child: ListenableBuilder(
              listenable: app.browse,
              builder: (context, _) => _modeSwipe(_list(app)),
            ),
          ),
        ],
      ),
      bottomNavigationBar: ListenableBuilder(
        listenable: app,
        builder: (context, _) {
          // 导航项和顺序都来自设置（每一项都能拖动排序，除「设置」外都能隐藏）。
          final tabs = app.settings.navTabs;
          // 「喜欢」是当前页，高亮它 —— 不能写死 0：用户把别的项拖到第一位之后，
          // 写死 0 会高亮错的那一格。
          // 用户把「喜欢」藏起来时它不在列表里（-1），NavigationBar 的 selectedIndex
          // 必须落在 0..n-1，退化成 0（这时底栏本来也没有代表当前页的那一格）。
          final browseIndex = tabs.indexOf('browse');
          return NavigationBar(
            selectedIndex: browseIndex < 0 ? 0 : browseIndex,
            onDestinationSelected: (i) {
              if (i < 0 || i >= tabs.length) return;
              switch (tabs[i]) {
                case 'search':
                  _openSearch();
                case 'swipe':
                  _openSwipe();
                case 'grok':
                  _openGrok();
                case 'settings':
                  _openSettings(context);
                default:
                  // 「喜欢」是当前页：再点一次 = 回到当前 Tab 的顶部
                  // （和常见 App「再点当前 tab」的习惯一致）。
                  _scrollToTop();
              }
            },
            destinations: [for (final key in tabs) _navDestination(key)],
          );
        },
      ),
    );
  }

  NavigationDestination _navDestination(String key) => switch (key) {
    'search' => NavigationDestination(
      icon: const Icon(Icons.search),
      label: t('nav.search'),
    ),
    'swipe' => NavigationDestination(
      icon: const Icon(Icons.play_circle_outline),
      label: t('nav.swipe'),
    ),
    'grok' => NavigationDestination(
      icon: const Icon(Icons.auto_awesome_outlined),
      label: t('nav.grok'),
    ),
    'settings' => NavigationDestination(
      icon: const Icon(Icons.settings),
      label: t('nav.settings'),
    ),
    _ => NavigationDestination(
      icon: const Icon(Icons.dynamic_feed),
      label: t('nav.browse'),
    ),
  };

  /// Grok 页：grok.com 官方页面，内嵌网页。
  ///
  /// 登录态：grok.com 的登录本来就跳 X 授权，而 WebView 里 x.com 的 cookie
  /// 已经注入了 —— 所以点一次「Sign in with X」就会自动通过，不用另配账号。
  void _openGrok() {
    unawaited(
      openXPage(
        context,
        const XWebPage(url: 'https://grok.com', title: 'Grok'),
      ),
    );
  }

  void _openSwipe() {
    unawaited(openXPage(context, const SwipeFeedPage()));
  }

  void _openSettings(BuildContext context) {
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const SettingsPage()));
  }

  Future<bool> _confirmBackfill(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t('sync.backfill')),
        content: Text(t('sync.backfillConfirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t('action.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t('action.confirm')),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  /// 左右滑动切换顶部那三个排序 Tab。
  ///
  /// 只接管**水平**方向的拖动：垂直滚动仍归列表自己（Flutter 的手势竞技场按
  /// 初始位移的方向判胜负），所以「上下滑」和「左右滑」不会互相抢。
  /// 到第一个/最后一个就停住，不循环 —— 循环会让「我到底在哪一档」失去坐标。
  Widget _modeSwipe(Widget child) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragEnd: (details) {
        final app = _app;
        if (app == null) return;
        final v = details.primaryVelocity ?? 0;
        // 轻扫不切：手指轻微斜着划一下不该换 Tab。
        if (v.abs() < 240) return;
        final modes = SortMode.values;
        final i = modes.indexOf(app.browse.mode);
        if (i < 0) return;
        // 往左滑 = 看下一个（右边的 Tab），和翻页方向一致。
        final next = i + (v < 0 ? 1 : -1);
        if (next < 0 || next >= modes.length) return;
        unawaited(_switchMode(modes[next]));
      },
      child: child,
    );
  }

  Widget _list(AppController app) {
    final browse = app.browse;
    if (browse.listItems.isEmpty) {
      if (browse.loadingPage) {
        return const Center(child: CircularProgressIndicator());
      }
      return _EmptyState(
        onBackfill: () async {
          final ok = await _confirmBackfill(context);
          if (ok) await app.sync.startBackfill();
        },
      );
    }

    // 列表用**已滤掉本次取消喜欢**的视图；播放页仍用 browse.items，
    // 这样取消之后还能在当前页点回喜欢。
    final all = browse.listItems;
    final olderCount = browse.listOlderCount;
    final belowCount = all.length - olderCount;

    return RefreshIndicator(
      // 下拉的含义跟着「你在哪」走：
      // - 跳转过（上面还有更新的）→ 加载上一页，纯读本地，不发请求；
      // - 已经在第一页 → 随机模式洗牌换一批，其它模式去 X 拉新增。
      // 这样「回填/同步」只在第一页发生，翻到中间不会被同步打乱位置。
      onRefresh: () async {
        if (browse.hasOlder) {
          // 注意：这里**不**再 jumpTo(0)。补进来的内容放在 center 上方，
          // 当前位置本来就不会动 —— 强行跳回 0 反而会把用户甩回去。
          await browse.loadPrev();
          return;
        }
        if (browse.mode == SortMode.random) {
          await browse.reshuffle();
        } else {
          await app.sync.syncNew();
        }
      },
      child: Center(
        child: ConstrainedBox(
          // 宽屏（Windows 上调试时）也别把一行拉成一米长，读起来太累。
          constraints: const BoxConstraints(maxWidth: 720),
          child: CustomScrollView(
            // center：滚动位置 0 = 中心的那一条。center 之前（负偏移）是
            // 「往前翻出来的更新条目」，之后是继续往下的列表。
            center: _centerKey,
            controller: _scroll,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              // ---- center 之上：更新的条目（倒序排，索引 0 最靠近 center）
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, i) => _cardAt(app, all, olderCount - 1 - i),
                  childCount: olderCount,
                ),
              ),
              // ---- center 及以下
              SliverList(
                key: _centerKey,
                delegate: SliverChildBuilderDelegate((context, i) {
                  if (i >= belowCount) {
                    return const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  return _cardAt(app, all, olderCount + i);
                }, childCount: belowCount + (browse.hasMore ? 1 : 0)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 列表里的一张卡片。定位一律用 `tweetId`（列表视图可能滤掉了取消喜欢的
  /// 条目，下标和播放页的源头列表对不上）。
  Widget _cardAt(AppController app, List<LikeItem> all, int index) {
    final item = all[index];
    return Column(
      // key 放在最外层：往 center 上方插入内容时，元素靠它对应上原来的条目，
      // 否则索引整体错位会让卡片被重建（图片重新解码、滑动位置乱跳）。
      key: ValueKey(item.tweetId),
      mainAxisSize: MainAxisSize.min,
      children: [
        PostCard(
          item: item,
          cache: app.mediaCache,
          autoPlayVideo: app.settings.playback.autoPlayInList,
          onTap: () => _openFeed(item.tweetId),
          onAvatarTap: () => _openAuthor(item),
        ),
        const Divider(height: 1, thickness: 0.4),
      ],
    );
  }

  /// 跳转面板。**只提供当前 tab 有意义的那个维度**：
  /// - 喜欢顺序 → 跳到第几个；
  /// - 发布日期 → 跳到某一天；
  /// - 随机 → 没有「位置」这个概念，不提供跳转。
  ///
  /// 跳过去之后列表顶部会出现「加载上一页」——下拉就是往回加载（见 [_list]）。
  Future<void> _openJumpSheet(BuildContext context, AppController app) async {
    final browse = app.browse;
    final total = browse.totalCount;
    if (total == 0 || browse.mode == SortMode.random) return;

    final byPosition = browse.mode == SortMode.likeOrder;
    var position = 1;
    DateTime? date;

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final theme = Theme.of(ctx);
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    byPosition ? t('jump.byPosition') : t('jump.byDate'),
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 16),
                  if (byPosition) ...[
                    Row(
                      children: [
                        Text('1 — $total'),
                        const Spacer(),
                        Text('$position', style: theme.textTheme.titleMedium),
                      ],
                    ),
                    Slider(
                      value: position.toDouble().clamp(1, total.toDouble()),
                      min: 1,
                      max: total.toDouble(),
                      divisions: total > 1 ? total - 1 : null,
                      label: '$position',
                      onChanged: (v) => setLocal(() => position = v.round()),
                    ),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: () {
                          Navigator.pop(ctx);
                          // 跳完把视口拉回顶部：新的一页从第一条开始，
                          // 留在旧的像素偏移上会落在半截。
                          browse.jumpToOffset(position - 1).then((_) {
                            if (_scroll.hasClients) _scroll.jumpTo(0);
                          });
                        },
                        child: Text(t('jump.go')),
                      ),
                    ),
                  ] else ...[
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.event, size: 18),
                        label: Text(
                          date == null
                              ? t('filter.dateRange')
                              : _fmtDate(date!),
                        ),
                        onPressed: () async {
                          final picked = await showDatePicker(
                            context: ctx,
                            firstDate: DateTime(2006),
                            lastDate: DateTime.now(),
                            initialDate: date ?? DateTime.now(),
                          );
                          if (picked != null) setLocal(() => date = picked);
                        },
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: date == null
                            ? null
                            : () {
                                Navigator.pop(ctx);
                                browse.jumpToDate(date!).then((_) {
                                  if (_scroll.hasClients) _scroll.jumpTo(0);
                                });
                              },
                        child: Text(t('jump.go')),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  static String _fmtDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

/// 响应式断点（搜索页/作者空间复用）。
const double kBreakpointWide = 1000;
const double kBreakpointMedium = 600;

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onBackfill});
  final VoidCallback onBackfill;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.favorite_border, size: 56),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(t('sync.empty'), textAlign: TextAlign.center),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: onBackfill,
            icon: const Icon(Icons.cloud_download),
            label: Text(t('sync.backfill')),
          ),
        ],
      ),
    );
  }
}

class _ModeBar extends StatelessWidget {
  const _ModeBar({required this.browse, required this.onModeChanged});

  final BrowseState browse;

  /// 切 Tab 要经过外层：切之前记住当前位置、切之后恢复目标 Tab 的位置。
  final ValueChanged<SortMode> onModeChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        children: [
          SegmentedButton<SortMode>(
            showSelectedIcon: false,
            style: const ButtonStyle(
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              padding: WidgetStatePropertyAll(
                EdgeInsets.symmetric(horizontal: 10),
              ),
              textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 12)),
            ),
            segments: [
              ButtonSegment(
                value: SortMode.likeOrder,
                label: Text(t('mode.likeOrder')),
              ),
              ButtonSegment(
                value: SortMode.publishDate,
                label: Text(t('mode.publishDate')),
              ),
              ButtonSegment(
                value: SortMode.random,
                label: Text(t('mode.random')),
              ),
            ],
            selected: {browse.mode},
            onSelectionChanged: (s) => onModeChanged(s.first),
          ),
          const SizedBox(width: 12),
        ],
      ),
    );
  }
}

class _SyncBanner extends StatelessWidget {
  const _SyncBanner({required this.sync});
  final SyncController sync;

  @override
  Widget build(BuildContext context) {
    final p = sync.progress;
    final error = sync.error;
    final last = sync.lastResult;
    if (p == null && error == null && last == null) {
      return const SizedBox.shrink();
    }
    final scheme = Theme.of(context).colorScheme;

    if (p == null) {
      final isError = error != null;
      final text = isError
          ? '${t("sync.error")}: $error'
          : last!.inserted > 0
          ? '${t("sync.done")} · ${last.pages} ${t("sync.pages")} '
                '· +${last.inserted} ${t("sync.items")}'
          : '${t("sync.done")} · ${t("sync.noNew")}';
      return Material(
        color: isError ? scheme.errorContainer : scheme.secondaryContainer,
        child: ListTile(
          dense: true,
          leading: Icon(
            isError ? Icons.error_outline : Icons.check_circle_outline,
          ),
          title: Text(text),
          trailing: IconButton(
            icon: const Icon(Icons.close),
            onPressed: sync.clear,
          ),
        ),
      );
    }

    final total = p.fetched;
    return Material(
      color: scheme.secondaryContainer,
      child: Column(
        children: [
          LinearProgressIndicator(value: p.done ? 1 : null),
          ListTile(
            dense: true,
            leading: const Icon(Icons.sync),
            title: Text(
              p.message ??
                  '${t("sync.backfillRunning")} · ${p.pages} ${t("sync.pages")} '
                      '· $total ${t("sync.items")} · +${p.inserted}',
            ),
            trailing: IconButton(
              icon: const Icon(Icons.stop_circle_outlined),
              onPressed: sync.cancel,
            ),
          ),
        ],
      ),
    );
  }
}

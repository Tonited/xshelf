/// 主界面：X 风格的一列图文列表。
///
/// 两个**来源**（喜欢 / 书签）各是一页，共用同一个列表组件 [_SourceList]，
/// 底栏切换、也可以横滑切换：
/// - 横滑先切**排序**（喜欢顺序 / 发布日期 / 随机）；
/// - 排序到两端时再往同方向滑，切**来源**（两端停住，不循环）。
///
/// 两个来源各有独立的 [BrowseState]，所以排序档、滚动位置、翻页游标互不干扰。
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

/// 响应式断点（搜索页/作者空间复用）。
const double kBreakpointWide = 1000;
const double kBreakpointMedium = 600;

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final PageController _page = PageController();

  /// 0 = 喜欢，1 = 书签。
  int _source = 0;

  /// 用来把「切排序」的请求转给对应那一页（它持有滚动控制器）。
  final Map<int, GlobalKey<_SourceListState>> _listKeys = {
    0: GlobalKey<_SourceListState>(),
    1: GlobalKey<_SourceListState>(),
  };

  @override
  void dispose() {
    _page.dispose();
    super.dispose();
  }

  BrowseState _browseFor(AppController app) =>
      _source == 1 ? app.bookmarks : app.browse;

  void _switchSource(int delta) {
    final next = (_source + delta).clamp(0, 1);
    if (next == _source) return;
    setState(() => _source = next);
    _page.animateToPage(
      next,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
    );
  }

  void _switchModeAt(int source, SortMode mode) {
    _listKeys[source]?.currentState?.switchMode(mode);
  }

  @override
  Widget build(BuildContext context) {
    // 用 of 而不是 read：设置一变（自动翻译、低数据模式…）列表要立刻跟着重建。
    final app = AppScope.of(context);
    final browse = _browseFor(app);
    final isBookmarks = _source == 1;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: Text(
          isBookmarks ? t('list.title.bookmarks') : t('list.title.likes'),
        ),
        actions: [
          // 总数跟随当前来源：看喜欢时是喜欢数，看书签时是书签数。
          ListenableBuilder(
            listenable: browse,
            builder: (context, _) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Center(
                child: Text(
                  '${browse.totalCount}',
                  style: Theme.of(context).textTheme.labelLarge
                      ?.copyWith(color: Theme.of(context).colorScheme.outline),
                ),
              ),
            ),
          ),
          ListenableBuilder(
            listenable: browse,
            builder: (context, _) {
              if (browse.mode == SortMode.random) {
                return const SizedBox.shrink();
              }
              return IconButton(
                tooltip: browse.mode == SortMode.likeOrder
                    ? t('jump.byPosition')
                    : t('jump.byDate'),
                onPressed: () => _openJumpSheet(context, app, browse),
                icon: const Icon(Icons.my_location),
              );
            },
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(44),
          child: ListenableBuilder(
            listenable: browse,
            builder: (context, _) => _ModeBar(
              browse: browse,
              onModeChanged: (m) => _switchModeAt(_source, m),
            ),
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
            child: PageView(
              controller: _page,
              // 横滑交给每页自己的手势：先切排序，到边界才切来源。
              physics: const NeverScrollableScrollPhysics(),
              onPageChanged: (i) {
                if (i != _source) setState(() => _source = i);
              },
              children: [
                _SourceList(
                  key: _listKeys[0],
                  app: app,
                  browse: app.browse,
                  onEdgeSwipe: _switchSource,
                ),
                _SourceList(
                  key: _listKeys[1],
                  app: app,
                  browse: app.bookmarks,
                  onEdgeSwipe: _switchSource,
                ),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: ListenableBuilder(
        listenable: app,
        builder: (context, _) {
          final tabs = app.settings.navTabs;
          final currentKey = isBookmarks ? 'bookmarks' : 'browse';
          final selected = tabs.indexOf(currentKey);
          return NavigationBar(
            selectedIndex: selected < 0 ? 0 : selected,
            onDestinationSelected: (i) {
              if (i < 0 || i >= tabs.length) return;
              switch (tabs[i]) {
                case 'bookmarks':
                  if (_source != 1) _switchSource(1);
                case 'browse':
                  if (_source != 0) {
                    _switchSource(-1);
                  } else {
                    // 已经在喜欢的当前页：再点一次回到顶部。
                    _listKeys[0]?.currentState?.scrollToTop();
                  }
                case 'search':
                  _openSearch();
                case 'swipe':
                  unawaited(openXPage(context, const SwipeFeedPage()));
                case 'grok':
                  unawaited(
                    openXPage(
                      context,
                      const XWebPage(url: 'https://grok.com', title: 'Grok'),
                    ),
                  );
                case 'settings':
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const SettingsPage(),
                    ),
                  );
              }
            },
            destinations: [for (final key in tabs) _navDestination(key)],
          );
        },
      ),
    );
  }

  NavigationDestination _navDestination(String key) => switch (key) {
    'bookmarks' => NavigationDestination(
      icon: const Icon(Icons.bookmark_border),
      label: t('nav.bookmarks'),
    ),
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

  void _openSearch() {
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const SearchPage()));
  }

  /// 跳转面板。**只提供当前 tab 有意义的那个维度**：
  /// - 喜欢/书签顺序 → 跳到第几个；
  /// - 发布日期 → 跳到某一天；
  /// - 随机 → 没有「位置」，不提供跳转。
  Future<void> _openJumpSheet(
    BuildContext context,
    AppController app,
    BrowseState browse,
  ) async {
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
                          browse.jumpToOffset(position - 1).then((_) {
                            _listKeys[_source]?.currentState
                                ?.jumpToTopAfterJump();
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
                                  _listKeys[_source]?.currentState
                                      ?.jumpToTopAfterJump();
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

/// 一个来源的列表（喜欢或书签），布局与行为完全一致。
class _SourceList extends StatefulWidget {
  const _SourceList({
    super.key,
    required this.app,
    required this.browse,
    required this.onEdgeSwipe,
  });

  final AppController app;
  final BrowseState browse;

  /// 排序已经到头时，请求外层切换来源（+1 / -1）。
  final void Function(int delta) onEdgeSwipe;

  @override
  State<_SourceList> createState() => _SourceListState();
}

class _SourceListState extends State<_SourceList>
    with AutomaticKeepAliveClientMixin {
  final ScrollController _scroll = ScrollController();

  /// `CustomScrollView` 的「中心」。
  ///
  /// 中心之上放「往前翻出来的、更新的条目」，中心之下放当前的列表。
  /// 往中心上方追加内容时，滚动位置 0 仍然对应中心那一条。
  final GlobalKey _centerKey = GlobalKey();

  Timer? _saveDebounce;
  bool _restored = false;

  BrowseState get browse => widget.browse;
  AppController get app => widget.app;

  /// 来源名（`like` / `bookmark`），用于按来源记忆位置。
  String get _kind => browse.kinds.first;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _restorePosition());
  }

  @override
  void dispose() {
    _scroll.dispose();
    _saveDebounce?.cancel();
    super.dispose();
  }

  Future<void> _restorePosition() async {
    if (_restored) return;
    _restored = true;
    if (!mounted) return;
    final view = app.settings.view;
    final items = browse.items;

    final anchor = view.anchorSeq;
    final firstSeq = items.isNotEmpty ? items.first.feedRank : null;
    if (anchor != null && items.isNotEmpty && anchor != firstSeq) {
      await browse.jumpToSeq(anchor);
      if (!mounted) return;
    }
    final saved = app.settings.scrollOf(browse.storageKey);
    final offset = saved > 0 ? saved : view.scrollOffset;
    if (offset > 0 && _scroll.hasClients) {
      final max = _scroll.position.maxScrollExtent;
      _scroll.jumpTo(offset.clamp(0, max));
    }
  }

  /// 切排序：记住当前来源+档位的位置，切过去再恢复目标档的位置。
  Future<void> switchMode(SortMode mode) async {
    if (browse.mode == mode) return;
    if (_scroll.hasClients) {
      await app.settings.setScrollOf(
        browse.storageKey,
        _scroll.position.pixels,
      );
    }
    await browse.setMode(mode);
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Timer(const Duration(milliseconds: 80), () {
        if (!mounted || !_scroll.hasClients) return;
        final target = app.settings.scrollOf(browse.storageKey);
        final max = _scroll.position.maxScrollExtent;
        _scroll.jumpTo(target.clamp(0, max));
      });
    });
  }

  /// 跳转面板落位之后把视口拉回顶部。
  void jumpToTopAfterJump() {
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void scrollToTop() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      _scroll.position.minScrollExtent,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  void _onScroll() {
    if (!mounted || !_scroll.hasClients) return;
    final pos = _scroll.position;
    if (pos.pixels >= pos.maxScrollExtent - 800) browse.loadMore();
    if (browse.hasOlder && pos.pixels <= pos.minScrollExtent + 500) {
      browse.loadPrev();
    }
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 1200), () {
      if (!mounted) return;
      browse.saveView(scrollOffset: pos.pixels);
      unawaited(app.settings.setScrollOf(browse.storageKey, pos.pixels));
      if (browse.listItems.isNotEmpty) {
        final first = browse.listItems.first.feedRank;
        final last = browse.listItems.last.feedRank;
        if (first != null && last != null) {
          app.markViewportDirty(last, first, kind: _kind);
        }
      }
    });
  }

  Future<void> _openFeed(String tweetId) async {
    var lastSeen = tweetId;
    await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (_) => FeedPage(
          source: browse,
          initialTweetId: tweetId,
          cache: app.mediaCache,
          onCurrentChanged: (id) => lastSeen = id,
        ),
      ),
    );
    if (!mounted) return;
    if (lastSeen == tweetId) return;
    final at = browse.items.indexWhere((i) => i.tweetId == lastSeen);
    if (at < 0) return;
    await browse.jumpToItem(browse.items[at]);
    if (!mounted || !_scroll.hasClients) return;
    _scroll.jumpTo(0);
  }

  /// 横滑：先切排序；排序到头（第一档往右 / 末档往左）时切来源。
  void _onHorizontalDragEnd(DragEndDetails details) {
    final v = details.primaryVelocity ?? 0;
    if (v.abs() < 240) return;
    final modes = SortMode.values;
    final i = modes.indexOf(browse.mode);
    if (i < 0) return;
    final next = i + (v < 0 ? 1 : -1);
    if (next >= 0 && next < modes.length) {
      unawaited(switchMode(modes[next]));
      return;
    }
    widget.onEdgeSwipe(v < 0 ? 1 : -1);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragEnd: _onHorizontalDragEnd,
      // 必须在这里订阅：本组件活在 PageView 里，外层没有 ListenableBuilder。
      // 少了它，切排序 / 同步回填之后 `browse.listItems` 变了也不会重建 ——
      // 表现就是「点了 tab，数据没变，得退出去再进来才更新」。
      child: ListenableBuilder(
        listenable: browse,
        builder: (context, _) => _list(),
      ),
    );
  }

  Widget _list() {
    if (browse.listItems.isEmpty) {
      if (browse.loadingPage) {
        return const Center(child: CircularProgressIndicator());
      }
      return _EmptyState(
        isBookmarks: _kind == 'bookmark',
        onBackfill: () async {
          final ok = await _confirmBackfill(context, _kind);
          if (ok) await app.sync.startBackfill(kind: _kind);
        },
      );
    }

    final all = browse.listItems;
    final olderCount = browse.listOlderCount;
    final belowCount = all.length - olderCount;

    return RefreshIndicator(
      onRefresh: () async {
        if (browse.hasOlder) {
          await browse.loadPrev();
          return;
        }
        if (browse.mode == SortMode.random) {
          await browse.reshuffle();
        } else {
          await app.sync.syncNew(kind: _kind);
        }
      },
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: CustomScrollView(
            center: _centerKey,
            controller: _scroll,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, i) => _cardAt(all, olderCount - 1 - i),
                  childCount: olderCount,
                ),
              ),
              SliverList(
                key: _centerKey,
                delegate: SliverChildBuilderDelegate((context, i) {
                  if (i >= belowCount) {
                    return const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  return _cardAt(all, olderCount + i);
                }, childCount: belowCount + (browse.hasMore ? 1 : 0)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 列表里的一张卡片。定位一律用 `tweetId`。
  Widget _cardAt(List<LikeItem> all, int index) {
    final item = all[index];
    return Column(
      key: ValueKey('$_kind:${item.tweetId}'),
      mainAxisSize: MainAxisSize.min,
      children: [
        PostCard(
          item: item,
          cache: app.mediaCache,
          autoPlayVideo: app.settings.playback.autoPlayInList,
          bookmarked: app.db.hasTweet(item.tweetId, kind: 'bookmark'),
          onTap: () => _openFeed(item.tweetId),
          onAvatarTap: () => _openAuthor(item),
        ),
        const Divider(height: 1, thickness: 0.4),
      ],
    );
  }

  void _openAuthor(LikeItem item) {
    final author = item.author;
    if (author == null || author.screenName.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AuthorPage(author: author, cache: app.mediaCache),
      ),
    );
  }

  Future<bool> _confirmBackfill(BuildContext context, String kind) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          kind == 'bookmark' ? t('sync.backfillBookmarks') : t('sync.backfill'),
        ),
        content: Text(
          kind == 'bookmark'
              ? t('sync.backfillConfirmBookmarks')
              : t('sync.backfillConfirm'),
        ),
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
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onBackfill, this.isBookmarks = false});

  final VoidCallback onBackfill;
  final bool isBookmarks;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isBookmarks ? Icons.bookmark_border : Icons.favorite_border,
            size: 56,
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              isBookmarks ? t('empty.bookmarks') : t('sync.empty'),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: onBackfill,
            icon: const Icon(Icons.cloud_download),
            label: Text(
              isBookmarks ? t('sync.backfillBookmarks') : t('sync.backfill'),
            ),
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
    final isBookmarks = browse.kinds.contains('bookmark');
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
                label: Text(
                  isBookmarks ? t('mode.bookmarkOrder') : t('mode.likeOrder'),
                ),
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

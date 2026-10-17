/// 主界面：自适应（桌面双栏 / 平板覆盖 / 手机单列）。
///
/// 重建范围刻意收到最小：
/// - 网格 + 时间轴只订阅 [BrowseState]；
/// - 顶栏按钮 + 同步横幅只订阅 [SyncController]。
/// 这样同步每抓一页刷一次进度时，屏幕上的几十上百张卡片完全不动。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

import '../app_controller.dart';
import '../core/l10n.dart';
import '../db/app_database.dart';
import '../model/like_item.dart';
import '../state/browse_state.dart';
import '../state/sync_state.dart';
import 'detail_pane.dart';
import 'like_tile.dart';
import 'settings_page.dart';
import 'timeline_bar.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final ScrollController _scroll = ScrollController();
  final TextEditingController _search = TextEditingController();
  Timer? _saveDebounce;
  bool _restored = false;

  /// 在 didChangeDependencies 里取一次，避免在滚动回调里依赖 InheritedWidget。
  AppController? _app;

  @override
  void initState() {
    super.initState();
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
    _scroll.dispose();
    _search.dispose();
    _saveDebounce?.cancel();
    super.dispose();
  }

  /// 恢复上次的位置。
  ///
  /// 冷启动时只加载了第一页，直接按像素偏移 `jumpTo` 会被 `maxScrollExtent`
  /// 截断（等于永远回到顶部）。所以先用存下来的锚点 seq 重新取一页，
  /// 再套像素偏移 —— 5 万条的列表里这才是「上次看到哪」的真正含义。
  Future<void> _restorePosition() async {
    if (_restored) return;
    _restored = true;
    final app = _app;
    if (app == null || !mounted) return;
    final view = app.settings.view;
    final browse = app.browse;

    final q = browse.filter.search;
    if (q != null && q.isNotEmpty) _search.text = q;

    final anchor = view.anchorSeq;
    final firstSeq = browse.items.isNotEmpty ? browse.items.first.feedRank : null;
    if (anchor != null && browse.items.isNotEmpty && anchor != firstSeq) {
      await browse.jumpToSeq(anchor);
      if (!mounted) return;
    }
    if (view.scrollOffset > 0 && _scroll.hasClients) {
      final max = _scroll.position.maxScrollExtent;
      _scroll.jumpTo(view.scrollOffset.clamp(0, max));
    }
  }

  void _onScroll() {
    final app = _app;
    if (app == null || !mounted || !_scroll.hasClients) return;
    final browse = app.browse;
    final pos = _scroll.position;
    if (pos.pixels >= pos.maxScrollExtent - 800) browse.loadMore();
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 1200), () {
      if (!mounted) return;
      app.browse.saveView(scrollOffset: pos.pixels);
      // 停住就看：把当前已加载的这一段交给巡边器核对（内部有 1.5s/次、4 次/分的预算）
      if (browse.items.isNotEmpty) {
        final first = browse.items.first.feedRank;
        final last = browse.items.last.feedRank;
        if (first != null && last != null) app.markViewportDirty(last, first);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.read(context);
    final width = MediaQuery.sizeOf(context).width;
    final wide = width >= kBreakpointWide;
    final medium = width >= kBreakpointMedium;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 12,
        title: _SearchField(
          controller: _search,
          onSubmitted: (v) {
            final browse = app.browse;
            browse.setFilter(browse.filter.copyWith(
              search: v.trim().isEmpty ? null : v.trim(),
              clearSearch: v.trim().isEmpty,
            ));
          },
        ),
        actions: [
          ListenableBuilder(
            listenable: app.sync,
            builder: (context, _) {
              final busy = app.sync.busy;
              return IconButton(
                tooltip: t('action.refresh'),
                onPressed: busy ? app.sync.cancel : () => app.sync.syncNew(),
                icon: Icon(busy ? Icons.stop : Icons.refresh),
              );
            },
          ),
          PopupMenuButton<String>(
            onSelected: (v) async {
              switch (v) {
                case 'backfill':
                  final ok = await _confirmBackfill(context);
                  if (ok) await app.sync.startBackfill();
                case 'reshuffle':
                  await app.browse.reshuffle();
                case 'settings':
                  _openSettings(context);
                case 'logout':
                  await app.signOut();
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'backfill',
                child: Text(
                    app.sync.backfillDone ? t('sync.backfill') : t('sync.resume')),
              ),
              PopupMenuItem(value: 'reshuffle', child: Text(t('mode.reshuffle'))),
              PopupMenuItem(value: 'settings', child: Text(t('action.settings'))),
              PopupMenuItem(value: 'logout', child: Text(t('action.logout'))),
            ],
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(52),
          child: ListenableBuilder(
            listenable: app.browse,
            builder: (context, _) => _ModeBar(
              browse: app.browse,
              onOpenFilter: () => _openFilterSheet(context, app),
            ),
          ),
        ),
      ),
      body: Column(
        children: [
          ListenableBuilder(
            listenable: app.sync,
            builder: (context, _) =>
                _SyncBanner(sync: app.sync),
          ),
          Expanded(
            child: ListenableBuilder(
              listenable: app.browse,
              builder: (context, _) {
                final browse = app.browse;
                final selected = browse.selectedItem;
                return Row(
                  children: [
                    Expanded(
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: _grid(app, onTap: (item) {
                              browse.select(item.tweetId);
                              if (!wide) {
                                Navigator.of(context)
                                    .push(MaterialPageRoute<void>(
                                  builder: (_) => Scaffold(
                                    appBar: AppBar(),
                                    body: DetailPane(
                                      item: item,
                                      onClose: () =>
                                          Navigator.of(context).pop(),
                                    ),
                                  ),
                                ));
                              }
                            }),
                          ),
                          // 时间轴：右侧竖向刻度（随机模式下自动隐藏）
                          Positioned(
                            right: 8,
                            top: 12,
                            bottom: 12,
                            child: SizedBox(
                              width: 44,
                              child: TimelineBar(browse: browse),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (wide && selected != null) ...[
                      const VerticalDivider(width: 1),
                      SizedBox(
                        width: 440,
                        child: DetailPane(
                          item: selected,
                          onClose: () => browse.select(null),
                        ),
                      ),
                    ],
                  ],
                );
              },
            ),
          ),
        ],
      ),
      bottomNavigationBar: medium
          ? null
          : NavigationBar(
              selectedIndex: 0,
              onDestinationSelected: (i) {
                if (i == 2) _openSettings(context);
              },
              destinations: [
                NavigationDestination(
                    icon: const Icon(Icons.grid_view), label: t('nav.browse')),
                NavigationDestination(
                    icon: const Icon(Icons.search), label: t('nav.search')),
                NavigationDestination(
                    icon: const Icon(Icons.settings), label: t('nav.settings')),
              ],
            ),
    );
  }

  void _openSettings(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
    );
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
              child: Text(t('action.cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t('action.confirm'))),
        ],
      ),
    );
    return ok ?? false;
  }

  Widget _grid(AppController app, {required void Function(LikeItem) onTap}) {
    final browse = app.browse;
    if (browse.items.isEmpty) {
      if (browse.loadingPage) {
        return const Center(child: CircularProgressIndicator());
      }
      return _EmptyState(onBackfill: () async {
        final ok = await _confirmBackfill(context);
        if (ok) await app.sync.startBackfill();
      });
    }

    return GridView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(12, 12, 56, 12),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columnsForWidth(MediaQuery.sizeOf(context).width),
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 1,
      ),
      // 卡片有状态（悬停浮层），滚动离开后不必保活；预取半屏，快速滑动不空白。
      addAutomaticKeepAlives: false,
      scrollCacheExtent: const ScrollCacheExtent.viewport(0.5),
      itemCount: browse.items.length + (browse.hasMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= browse.items.length) {
          return const Center(child: CircularProgressIndicator());
        }
        final item = browse.items[index];
        return LikeTile(
          key: ValueKey(item.tweetId),
          item: item,
          cache: app.mediaCache,
          selected: item.tweetId == browse.selectedTweetId,
          onTap: () => onTap(item),
        );
      },
    );
  }

  Future<void> _openFilterSheet(BuildContext context, AppController app) async {
    final authors = app.browse.topAuthors();
    var filter = app.browse.filter;
    final from = await showModalBottomSheet<LikesFilter>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          return Padding(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 16,
              bottom: MediaQuery.viewInsetsOf(ctx).bottom + 16,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t('filter.title'),
                    style: Theme.of(ctx).textTheme.titleMedium),
                const SizedBox(height: 12),
                Text(t('filter.media')),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final m in MediaFilter.values)
                      FilterChip(
                        label: Text(_mediaLabel(m)),
                        selected: filter.media.contains(m),
                        onSelected: (on) {
                          final next = Set<MediaFilter>.from(filter.media);
                          on ? next.add(m) : next.remove(m);
                          filter = filter.copyWith(media: next);
                          setLocal(() {});
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: filter.authorScreenName,
                  decoration: InputDecoration(labelText: t('filter.author')),
                  items: [
                    DropdownMenuItem(
                        value: null, child: Text(t('filter.all'))),
                    for (final a in authors)
                      DropdownMenuItem(
                        value: a.screenName,
                        child: Text('@${a.screenName} (${a.count})',
                            overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (v) {
                    filter = v == null
                        ? filter.copyWith(clearAuthor: true)
                        : filter.copyWith(authorScreenName: v);
                    setLocal(() {});
                  },
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () async {
                          final range = await showDateRangePicker(
                            context: ctx,
                            firstDate: DateTime(2006),
                            lastDate: DateTime.now(),
                            initialDateRange: filter.from != null && filter.to != null
                                ? DateTimeRange(
                                    start: filter.from!, end: filter.to!)
                                : null,
                          );
                          if (range != null) {
                            filter = filter.copyWith(
                                from: range.start, to: range.end);
                            setLocal(() {});
                          }
                        },
                        child: Text(filter.from == null
                            ? t('filter.dateRange')
                            : '${filter.from!.year}-${filter.from!.month} → ${filter.to!.year}-${filter.to!.month}'),
                      ),
                    ),
                    if (filter.from != null)
                      IconButton(
                        onPressed: () {
                          filter = filter.copyWith(clearRange: true);
                          setLocal(() {});
                        },
                        icon: const Icon(Icons.clear),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    TextButton(
                      onPressed: () =>
                          Navigator.pop(ctx, const LikesFilter()),
                      child: Text(t('filter.clear')),
                    ),
                    const Spacer(),
                    FilledButton(
                      onPressed: () => Navigator.pop(ctx, filter),
                      child: Text(t('action.confirm')),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
    if (from != null) await app.browse.setFilter(from);
  }

  String _mediaLabel(MediaFilter m) => switch (m) {
        MediaFilter.video => t('filter.video'),
        MediaFilter.image => t('filter.image'),
        MediaFilter.gif => t('filter.gif'),
        MediaFilter.text => t('filter.text'),
      };
}

/// 响应式断点：宽度 ≥ 1000dp 是桌面双栏，≥ 600dp 是平板，再窄是手机单列。
const double kBreakpointWide = 1000;
const double kBreakpointMedium = 600;

/// 网格列数（纯函数，方便单测）。
int columnsForWidth(double width) {
  if (width >= 1600) return 6;
  if (width >= 1200) return 5;
  if (width >= 900) return 4;
  if (width >= kBreakpointMedium) return 3;
  return 2;
}

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
  const _ModeBar({required this.browse, required this.onOpenFilter});
  final BrowseState browse;
  final VoidCallback onOpenFilter;

  @override
  Widget build(BuildContext context) {
    final filter = browse.filter;
    return SizedBox(
      height: 52,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          SegmentedButton<SortMode>(
            segments: [
              ButtonSegment(
                  value: SortMode.likeOrder, label: Text(t('mode.likeOrder'))),
              ButtonSegment(
                  value: SortMode.publishDate,
                  label: Text(t('mode.publishDate'))),
              ButtonSegment(value: SortMode.random, label: Text(t('mode.random'))),
            ],
            selected: {browse.mode},
            onSelectionChanged: (s) => browse.setMode(s.first),
          ),
          const SizedBox(width: 12),
          FilterChip(
            label: Text(filter.isEmpty
                ? t('filter.title')
                : '${t("filter.title")} (${filter.media.length})'),
            selected: !filter.isEmpty,
            onSelected: (_) => onOpenFilter(),
          ),
          if (filter.search != null && filter.search!.isNotEmpty) ...[
            const SizedBox(width: 8),
            Chip(
              label: Text(filter.search!),
              onDeleted: () => browse.setFilter(filter.copyWith(clearSearch: true)),
            ),
          ],
          const SizedBox(width: 8),
          // 精确的年月跳转（顶部下拉），与右侧拖动刻度互补
          if (browse.mode != SortMode.random)
            _MonthJump(browse: browse),
          const SizedBox(width: 12),
          Center(
            child: Text(
              '${browse.totalCount}',
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ),
        ],
      ),
    );
  }
}

/// 顶部「跳到某年某月」下拉，与右侧刻度条互补：这里精确、那里快。
class _MonthJump extends StatelessWidget {
  const _MonthJump({required this.browse});
  final BrowseState browse;

  @override
  Widget build(BuildContext context) {
    final months = browse.months();
    if (months.isEmpty) return const SizedBox.shrink();
    return Center(
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          hint: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.event, size: 16),
                const SizedBox(width: 4),
                Text(t('filter.dateRange'),
                    style: Theme.of(context).textTheme.labelMedium),
              ],
            ),
          ),
          isDense: true,
          menuMaxHeight: 420,
          items: [
            for (final m in months)
              DropdownMenuItem(
                value: m.month,
                child: Text('${m.month}  (${m.count})'),
              ),
          ],
          onChanged: (m) {
            if (m != null) browse.jumpToMonth(m);
          },
        ),
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.onSubmitted});
  final TextEditingController controller;
  final void Function(String) onSubmitted;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      textInputAction: TextInputAction.search,
      onSubmitted: onSubmitted,
      decoration: InputDecoration(
        hintText: t('search.hint'),
        prefixIcon: const Icon(Icons.search),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(24),
          borderSide: BorderSide.none,
        ),
        filled: true,
        contentPadding: const EdgeInsets.symmetric(vertical: 8),
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
          leading:
              Icon(isError ? Icons.error_outline : Icons.check_circle_outline),
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

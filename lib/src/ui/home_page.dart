/// 主界面：自适应（桌面双栏 / 平板覆盖 / 手机单列）。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../core/l10n.dart';
import '../db/app_database.dart';
import '../model/like_item.dart';
import 'detail_pane.dart';
import 'like_tile.dart';
import 'settings_page.dart';

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

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _restoreScroll());
  }

  @override
  void dispose() {
    _scroll.dispose();
    _search.dispose();
    _saveDebounce?.cancel();
    super.dispose();
  }

  void _restoreScroll() {
    if (_restored) return;
    _restored = true;
    final app = AppScope.of(context);
    final offset = app.settings.view.scrollOffset;
    if (offset > 0 && _scroll.hasClients) {
      final max = _scroll.position.maxScrollExtent;
      _scroll.jumpTo(offset.clamp(0, max));
    }
    final q = app.filter.search;
    if (q != null && q.isNotEmpty) _search.text = q;
  }

  void _onScroll() {
    final app = AppScope.of(context);
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 800) {
      app.loadMore();
    }
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 1500), () {
      app.saveViewState(scrollOffset: _scroll.position.pixels);
      // 停住就看：把当前已加载的这一段交给巡边器核对（内部有 1.5s/次、4 次/分 的预算）
      if (app.items.isNotEmpty) {
        final first = app.items.first.feedRank;
        final last = app.items.last.feedRank;
        if (first != null && last != null) {
          app.markViewportDirty(last, first);
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final width = MediaQuery.sizeOf(context).width;
    final wide = width >= 1000;
    final medium = width >= 600;
    LikeItem? selected;
    for (final i in app.items) {
      if (i.tweetId == app.selectedTweetId) {
        selected = i;
        break;
      }
    }

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 12,
        title: _SearchField(controller: _search, onSubmitted: (v) {
          app.setFilter(app.filter.copyWith(
            search: v.trim().isEmpty ? null : v.trim(),
            clearSearch: v.trim().isEmpty,
          ));
        }),
        actions: [
          IconButton(
            tooltip: t('action.refresh'),
            onPressed: app.syncProgress != null
                ? app.cancelSync
                : () => app.syncNew(),
            icon: Icon(app.syncProgress != null ? Icons.stop : Icons.refresh),
          ),
          PopupMenuButton<String>(
            onSelected: (v) async {
              switch (v) {
                case 'backfill':
                  final ok = await _confirmBackfill(context);
                  if (ok) await app.startBackfill();
                case 'reshuffle':
                  await app.reshuffle();
                case 'settings':
                  _openSettings(context);
                case 'logout':
                  await app.signOut();
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'backfill', child: Text(t('sync.backfill'))),
              PopupMenuItem(
                  value: 'reshuffle', child: Text(t('mode.reshuffle'))),
              PopupMenuItem(value: 'settings', child: Text(t('action.settings'))),
              PopupMenuItem(value: 'logout', child: Text(t('action.logout'))),
            ],
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(52),
          child: _ModeBar(app: app),
        ),
      ),
      body: Column(
        children: [
          if (app.syncProgress != null || app.syncError != null)
            _SyncBanner(app: app),
          Expanded(
            child: Row(
              children: [
                Expanded(child: _grid(context, app, onTap: (item) {
                  app.select(item.tweetId);
                  if (!wide) {
                    Navigator.of(context).push(MaterialPageRoute<void>(
                      builder: (_) => Scaffold(
                        appBar: AppBar(),
                        body: DetailPane(
                          item: item,
                          onClose: () => Navigator.of(context).pop(),
                        ),
                      ),
                    ));
                  }
                })),
                if (wide && selected != null) ...[
                  const VerticalDivider(width: 1),
                  SizedBox(
                    width: 440,
                    child: DetailPane(
                      item: selected,
                      onClose: () => app.select(null),
                    ),
                  ),
                ],
              ],
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
      floatingActionButton: app.items.isEmpty && app.syncProgress == null
          ? null
          : null,
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

  Widget _grid(BuildContext context, AppController app,
      {required void Function(LikeItem) onTap}) {
    if (app.items.isEmpty) {
      if (app.loadingPage) {
        return const Center(child: CircularProgressIndicator());
      }
      return _EmptyState(app: app);
    }

    final columns = _columnsFor(context);
    return GridView.builder(
      controller: _scroll,
      padding: const EdgeInsets.all(12),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 1,
      ),
      itemCount: app.items.length + (app.hasMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= app.items.length) {
          return const Center(child: CircularProgressIndicator());
        }
        final item = app.items[index];
        return LikeTile(
          key: ValueKey(item.tweetId),
          item: item,
          selected: item.tweetId == app.selectedTweetId,
          onTap: () => onTap(item),
        );
      },
    );
  }

  int _columnsFor(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    if (width >= 1600) return 6;
    if (width >= 1200) return 5;
    if (width >= 900) return 4;
    if (width >= 600) return 3;
    return 2;
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.app});
  final AppController app;

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
            onPressed: () async {
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
              if (ok == true) await app.startBackfill();
            },
            icon: const Icon(Icons.cloud_download),
            label: Text(t('sync.backfill')),
          ),
        ],
      ),
    );
  }
}

class _ModeBar extends StatelessWidget {
  const _ModeBar({required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) {
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
            selected: {app.mode},
            onSelectionChanged: (s) => app.setMode(s.first),
          ),
          const SizedBox(width: 12),
          FilterChip(
            label: Text(app.filter.isEmpty
                ? t('filter.title')
                : '${t("filter.title")} (${app.filter.media.length})'),
            selected: !app.filter.isEmpty,
            onSelected: (_) => _openFilterSheet(context, app),
          ),
          if (app.filter.search != null && app.filter.search!.isNotEmpty) ...[
            const SizedBox(width: 8),
            Chip(
              label: Text(app.filter.search!),
              onDeleted: () => app.setFilter(app.filter.copyWith(clearSearch: true)),
            ),
          ],
          const SizedBox(width: 12),
          Center(
            child: Text(
              '${app.totalCount}',
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openFilterSheet(BuildContext context, AppController app) async {
    final authors = app.db.topAuthors(limit: 100);
    var filter = app.filter;
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
                      onPressed: () => Navigator.pop(
                          ctx, const LikesFilter()),
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
    if (from != null) await app.setFilter(from);
  }

  String _mediaLabel(MediaFilter m) => switch (m) {
        MediaFilter.video => t('filter.video'),
        MediaFilter.image => t('filter.image'),
        MediaFilter.gif => t('filter.gif'),
        MediaFilter.text => t('filter.text'),
      };
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
  const _SyncBanner({required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) {
    final p = app.syncProgress;
    final error = app.syncError;
    if (error != null) {
      return Material(
        color: Theme.of(context).colorScheme.errorContainer,
        child: ListTile(
          leading: const Icon(Icons.error_outline),
          title: Text('${t("sync.error")}: $error'),
          trailing: IconButton(
            icon: const Icon(Icons.close),
            onPressed: app.clearSyncError,
          ),
        ),
      );
    }
    final total = p?.fetched ?? 0;
    return Material(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: Column(
        children: [
          LinearProgressIndicator(
            value: p?.done == true ? 1 : null,
          ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.sync),
            title: Text(
              p?.message ??
                  '${t("sync.backfillRunning")} · ${p?.pages ?? 0} ${t("sync.pages")} '
                      '· ${total} ${t("sync.items")} · +${p?.inserted ?? 0}',
            ),
            trailing: IconButton(
              icon: const Icon(Icons.stop_circle_outlined),
              onPressed: app.cancelSync,
            ),
          ),
        ],
      ),
    );
  }
}

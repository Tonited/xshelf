/// 搜索页：本地喜欢 + X 全网，条件**直接平铺在页面上**，不再藏进弹窗。
///
/// 布局（整页可滚，条件在上、结果在下）：
/// 1. 模式分段（我的喜欢 / X 全网）；
/// 2. 关键词输入；
/// 3. 条件区：作者（下拉，显示「展示名 · @handle」）、媒体、时间、语言、排除；
///    切到 X 全网时额外出现互动量与结果排序；
/// 4. 本地 → 结果列表；全网 → 查询预览 + 「在 X 中搜索」。
///
/// 为什么把「加条件」弹窗去掉：条件一旦藏起来，用户就不知道自己漏设了什么，
/// 每次都要点开看一眼。平铺之后一眼看全，改哪项就直接改。
///
/// X 全网搜索仍交给 [XSearchPage]（内嵌 WebView 驱动 X 自己的页面）：
/// X 给每个 GraphQL 请求签名，纯 HTTP 走 `SearchTimeline` 必失败，见 docs/GRAPHQL.md §1.1。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_controller.dart';
import '../core/l10n.dart';
import '../db/app_database.dart';
import '../model/like_item.dart';
import '../net/translate.dart';
import '../state/feed_source.dart';
import '../state/query_feed_source.dart';
import '../sync/search_parser.dart';
import '../sync/search_query.dart';
import 'author_page.dart';
import 'feed_page.dart';
import 'post_card.dart';
import 'x_nav.dart';
import 'x_search_page.dart';

enum _Mode { local, onX }

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  Timer? _debounce;

  QueryFeedSource? _localSource;
  AppController? _app;
  _Mode _mode = _Mode.local;
  List<AuthorCount> _authors = const [];

  /// 本地条件（不含关键词；关键词在输入框里）。
  LikesFilter _localFilter = const LikesFilter();

  /// 本地搜索覆盖哪个来源：`like` / `bookmark` / `all`。
  String _kind = 'like';

  /// 本地结果的排序。
  SortMode _localSort = SortMode.publishDate;

  Set<String> get _kindsOf => switch (_kind) {
    'bookmark' => const {'bookmark'},
    'all' => const {'like', 'bookmark'},
    _ => const {'like'},
  };

  /// X 全网的结构化条件。
  XSearchQuery _xQuery = const XSearchQuery();
  SearchProduct _product = SearchProduct.latest;

  // X 互动量的输入框（本地没有这些字段，所以只在 X 模式下用）。
  final TextEditingController _faves = TextEditingController();
  final TextEditingController _retweets = TextEditingController();
  final TextEditingController _replies = TextEditingController();

  /// 关键词列表。可以加多个，用「且 / 或」连起来。
  ///
  /// 单个关键词时行为和老版本一样；多个词拼成 FTS 表达式（`"a" AND "b"`），
  /// 底层 `_searchClause` 认得这种写法。
  final List<String> _terms = [];
  bool _matchAll = true;

  /// 正在翻译输入框里的文字。
  bool _translating = false;

  /// 拼好的搜索表达式（本地用 FTS 语法，X 侧再翻译一次）。
  String get _searchExpr {
    if (_terms.isEmpty) return _query;
    final parts = _terms
        .map((t) => '"${t.replaceAll('"', '')}"')
        .toList(growable: false);
    if (parts.length == 1) return parts.first;
    return parts.join(_matchAll ? ' AND ' : ' OR ');
  }

  void _addTerm() {
    final v = _input.text.trim();
    if (v.isEmpty) return;
    if (_terms.contains(v)) {
      _input.clear();
      setState(() {});
      return;
    }
    setState(() {
      _terms.add(v);
      _input.clear();
    });
    if (_mode == _Mode.local) _runLocal();
  }

  void _removeTerm(String t) {
    setState(() => _terms.remove(t));
    if (_mode == _Mode.local) _runLocal();
  }

  String get _query => _input.text.trim();

  /// 把输入框里的文字翻成指定语言，替换回输入框。
  ///
  /// 先选目标语言（默认用设置里那个），翻完直接替换输入 —— 用户下一步
  /// 就是「搜索/加入关键词」，不用再手动复制。
  Future<void> _translateInput() async {
    final app = AppScope.read(context);
    final text = _input.text.trim();
    if (text.isEmpty) return;
    final lang = await _pickTranslateLanguage(app);
    if (lang == null || !mounted) return;

    setState(() => _translating = true);
    try {
      final out = await app.translate.translate(text, to: lang.code);
      if (!mounted) return;
      setState(() {
        _translating = false;
        _input.text = out;
        _input.selection = TextSelection.collapsed(offset: _input.text.length);
      });
      if (_mode == _Mode.local) _runLocal();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tf('translate.done', {'lang': lang.label}))),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _translating = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t('translate.failed'))));
    }
  }

  /// 选目标语言。选完会写进设置，正文翻译也跟着用这个语言。
  Future<TranslateLanguage?> _pickTranslateLanguage(AppController app) async {
    final current = app.settings.translateTo;
    return showModalBottomSheet<TranslateLanguage>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Row(
                children: [
                  Text(
                    t('translate.title'),
                    style: Theme.of(ctx).textTheme.titleMedium,
                  ),
                  const Spacer(),
                  Text(
                    t('translate.hint'),
                    style: Theme.of(ctx).textTheme.bodySmall
                        ?.copyWith(color: Theme.of(ctx).colorScheme.outline),
                  ),
                ],
              ),
            ),
            for (final lang in TranslateLanguage.all)
              ListTile(
                dense: true,
                title: Text(lang.label),
                trailing: lang.code == current
                    ? const Icon(Icons.check, size: 18)
                    : null,
                onTap: () async {
                  await app.settings.setTranslateTo(lang.code);
                  app.refreshSettings();
                  if (ctx.mounted) Navigator.pop(ctx, lang);
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// 关键词框里出现这些操作符，就认为用户在手写 X 语法，整串原样发。
  static final RegExp _rawSyntax = RegExp(
    r'\b(from|to|since|until|filter|min_faves|min_retweets|min_replies|lang|list|within_time|exclude|url|conversation_id|quoted_tweet_id|since_time|until_time):',
    caseSensitive: false,
  );

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = AppScope.read(context);
    if (_app == app) return;
    _app = app;
    _authors = app.browse.topAuthors(limit: 200);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _input.dispose();
    _faves.dispose();
    _retweets.dispose();
    _replies.dispose();
    _scroll.dispose();
    _localSource?.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    if (pos.pixels < pos.maxScrollExtent - 600) return;
    _localSource?.loadMore();
  }

  // ------------------------------------------------------------------ 本地

  void _onKeywordChanged(String value) {
    if (_mode == _Mode.local) {
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 300), _runLocal);
      return;
    }
    setState(() {}); // X 模式只刷新查询预览
  }

  Future<void> _runLocal() async {
    final app = _app;
    if (app == null) return;
    final expr = _searchExpr;
    // 来源维度由页面上的选择决定，不跟随条件面板（条件面板只管内容条件）。
    final base = _localFilter.copyWith(kinds: _kindsOf);
    final filter = expr.isEmpty ? base : base.copyWith(search: expr);

    if (filter.isEmpty) {
      setState(() => _localSource = null);
      return;
    }

    final existing = _localSource;
    // 排序是 QueryFeedSource 的 final 字段：换了排序就换一个源。
    if (existing != null && existing.mode == _localSort) {
      await existing.reset(filter);
      if (mounted) setState(() {});
      return;
    }
    final src = QueryFeedSource(db: app.db, filter: filter, mode: _localSort);
    setState(() => _localSource = src);
    await src.loadMore();
    if (mounted) setState(() {});
  }

  void _setLocal(LikesFilter next) {
    setState(() => _localFilter = next);
    unawaited(_runLocal());
  }

  // ------------------------------------------------------------------ X 全网

  String _buildXQuery() {
    final raw = _query;
    // 手写语法优先：整串原样用，不拼引号。
    if (raw.isNotEmpty && _rawSyntax.hasMatch(raw)) return raw;

    // 多关键词：X 的 AND 是「空格相连」，OR 要显式写 `OR`。
    final terms = _terms.isNotEmpty
        ? _terms
        : (raw.isEmpty ? const <String>[] : [raw]);
    final keyword = terms.isEmpty
        ? ''
        : terms.length == 1
        ? terms.first
        : terms
              .map((t) => '"${t.replaceAll('"', '')}"')
              .join(_matchAll ? ' ' : ' OR ');

    final structured = _xQuery.build();
    if (keyword.isEmpty) return structured;
    if (structured.isEmpty) return keyword;
    return '$keyword $structured';
  }

  int? _intOf(TextEditingController c) {
    final v = int.tryParse(c.text.trim());
    return (v == null || v <= 0) ? null : v;
  }

  void _syncXInts() {
    _xQuery = _xQuery.copyWith(
      minFaves: _intOf(_faves),
      minRetweets: _intOf(_retweets),
      minReplies: _intOf(_replies),
      clearMinFaves: _intOf(_faves) == null,
      clearMinRetweets: _intOf(_retweets) == null,
      clearMinReplies: _intOf(_replies) == null,
    );
  }

  Future<void> _openXSearch() async {
    final raw = _buildXQuery();
    if (raw.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t('search.xIdle'))));
      return;
    }
    await openXPage(context, XSearchPage(rawQuery: raw, product: _product));
  }

  // ---------------------------------------------------------------- 页面

  void _openAuthorBy(String screenName, String name) {
    if (screenName.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AuthorPage(
          author: Author(id: '', screenName: screenName, name: name),
          cache: _app?.mediaCache,
        ),
      ),
    );
  }

  /// 打开播放页。**按 tweetId 定位**：结果列表是按 tweetId 去重后的视图，
  /// 它的下标和 `source.items`（未去重）对不上，直接传下标会打开错的帖子。
  void _openFeed(FeedSource source, LikeItem item) {
    Navigator.of(context).push(
      MaterialPageRoute<String>(
        builder: (_) => FeedPage(
          source: source,
          initialTweetId: item.tweetId,
          cache: _app?.mediaCache,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isLocal = _mode == _Mode.local;
    final items = isLocal ? (_localSource?.items ?? const <LikeItem>[]) : null;

    return Scaffold(
      appBar: AppBar(title: Text(t('search.title'))),
      body: CustomScrollView(
        controller: _scroll,
        slivers: [
          SliverToBoxAdapter(child: _conditionsPanel(theme)),
          if (isLocal) ..._localResultSlivers(theme, items ?? const []),
        ],
      ),
    );
  }

  // -------------------------------------------------------------- 条件区

  Widget _conditionsPanel(ThemeData theme) {
    final isLocal = _mode == _Mode.local;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: SegmentedButton<_Mode>(
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              segments: [
                ButtonSegment(
                  value: _Mode.local,
                  icon: const Icon(Icons.favorite_border, size: 17),
                  label: Text(t('search.local')),
                ),
                ButtonSegment(
                  value: _Mode.onX,
                  icon: const Icon(Icons.public, size: 17),
                  label: Text(t('search.onX')),
                ),
              ],
              selected: {_mode},
              onSelectionChanged: (s) {
                setState(() => _mode = s.first);
                if (_mode == _Mode.local) _runLocal();
              },
            ),
          ),

          // 本地搜索覆盖哪些来源：喜欢 / 书签 / 全部。
          if (isLocal) ...[
            const SizedBox(height: 8),
            Center(
              child: SegmentedButton<String>(
                showSelectedIcon: false,
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
                segments: [
                  ButtonSegment(value: 'like', label: Text(t('nav.browse'))),
                  ButtonSegment(
                    value: 'bookmark',
                    label: Text(t('nav.bookmarks')),
                  ),
                  ButtonSegment(value: 'all', label: Text(t('common.all'))),
                ],
                selected: {_kind},
                onSelectionChanged: (s) {
                  setState(() => _kind = s.first);
                  unawaited(_runLocal());
                },
              ),
            ),
          ],
          const SizedBox(height: 14),

          // 关键词：加进列表才算数，可以叠多个词
          TextField(
            controller: _input,
            onChanged: _onKeywordChanged,
            textInputAction: TextInputAction.done,
            // 回车 = 把当前输入加进关键词列表（而不是直接搜），
            // 这样「加了词再搜」和多关键词都顺。
            onSubmitted: (_) {
              if (_input.text.trim().isEmpty) {
                _mode == _Mode.local ? _runLocal() : _openXSearch();
              } else {
                _addTerm();
              }
            },
            decoration: InputDecoration(
              hintText: isLocal
                  ? t('search.hintLocal')
                  : t('search.keywordHint'),
              prefixIcon: const Icon(Icons.search),
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 翻译：把输入框里的文字翻成指定语言再搜。
                  // 搜外语内容时很实用（比如想找日文的某样东西，用中文描述再翻过去）。
                  if (_input.text.isNotEmpty)
                    IconButton(
                      icon: _translating
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 1.8,
                              ),
                            )
                          : const Icon(Icons.translate, size: 20),
                      tooltip: t('translate.action'),
                      onPressed: _translating ? null : _translateInput,
                    ),
                  if (_input.text.isNotEmpty)
                    IconButton(
                      icon: const Icon(Icons.add, size: 20),
                      tooltip: t('search.addTerm'),
                      onPressed: _addTerm,
                    ),
                  if (_input.text.isNotEmpty)
                    IconButton(
                      icon: const Icon(Icons.clear, size: 20),
                      onPressed: () {
                        _input.clear();
                        _debounce?.cancel();
                        setState(() {});
                        if (_mode == _Mode.local) _runLocal();
                      },
                    ),
                ],
              ),
            ),
          ),

          // 已加入的关键词 + 且/或
          if (_terms.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final term in _terms)
                  InputChip(
                    label: Text(term),
                    visualDensity: VisualDensity.compact,
                    onDeleted: () => _removeTerm(term),
                  ),
                if (_terms.length > 1)
                  SegmentedButton<bool>(
                    showSelectedIcon: false,
                    style: const ButtonStyle(
                      visualDensity: VisualDensity.compact,
                    ),
                    segments: [
                      ButtonSegment(
                        value: true,
                        label: Text(t('search.matchAll')),
                      ),
                      ButtonSegment(
                        value: false,
                        label: Text(t('search.matchAny')),
                      ),
                    ],
                    selected: {_matchAll},
                    onSelectionChanged: (s) {
                      setState(() => _matchAll = s.first);
                      if (_mode == _Mode.local) _runLocal();
                    },
                  ),
              ],
            ),
          ],
          const SizedBox(height: 14),

          // 作者：下拉（本地作者榜 + 当前值兜底）
          _label(theme, t('filter.author')),
          _authorField(theme, isLocal),
          const SizedBox(height: 14),

          // 媒体类型
          _label(theme, t('filter.media')),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: isLocal
                ? [
                    for (final m in MediaFilter.values)
                      FilterChip(
                        label: Text(_mediaFilterLabelLocal(m)),
                        selected: _localFilter.media.contains(m),
                        onSelected: (on) {
                          final next = Set<MediaFilter>.from(
                            _localFilter.media,
                          );
                          on ? next.add(m) : next.remove(m);
                          _setLocal(_localFilter.copyWith(media: next));
                        },
                      ),
                  ]
                : [
                    for (final f in SearchMediaFilter.values)
                      ChoiceChip(
                        label: Text(_mediaFilterLabel(f)),
                        selected: _xQuery.media == f,
                        onSelected: (_) => setState(
                          () => _xQuery = _xQuery.copyWith(media: f),
                        ),
                      ),
                  ],
          ),
          const SizedBox(height: 14),

          // 时间
          _label(theme, isLocal ? t('filter.dateRange') : t('search.since')),
          if (isLocal)
            _dateRangeButton(theme)
          else
            Row(
              children: [
                Expanded(
                  child: _dateButton(
                    theme,
                    value: _xQuery.since,
                    onPick: (v) =>
                        setState(() => _xQuery = _xQuery.copyWith(since: v)),
                    onClear: () => setState(
                      () => _xQuery = _xQuery.copyWith(clearSince: true),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _dateButton(
                    theme,
                    value: _xQuery.until,
                    onPick: (v) =>
                        setState(() => _xQuery = _xQuery.copyWith(until: v)),
                    onClear: () => setState(
                      () => _xQuery = _xQuery.copyWith(clearUntil: true),
                    ),
                  ),
                ),
              ],
            ),
          const SizedBox(height: 14),

          // 语言
          _label(theme, t('search.lang')),
          DropdownButtonFormField<String>(
            initialValue: (isLocal ? _localFilter.lang : _xQuery.lang) ?? '',
            items: [
              for (final e in _langs.entries)
                DropdownMenuItem(
                  value: e.key,
                  child: Text(
                    e.key.isEmpty ? t(e.value) : '${e.value} (${e.key})',
                  ),
                ),
            ],
            onChanged: (v) {
              final empty = v == null || v.isEmpty;
              if (isLocal) {
                _setLocal(
                  empty
                      ? _localFilter.copyWith(clearLang: true)
                      : _localFilter.copyWith(lang: v),
                );
              } else {
                setState(
                  () => _xQuery = empty
                      ? _xQuery.copyWith(clearLang: true)
                      : _xQuery.copyWith(lang: v),
                );
              }
            },
          ),
          const SizedBox(height: 14),

          // 排除项
          _label(theme, t('search.excludes')),
          if (isLocal) ...[
            _switchRow(
              title: t('search.excludeReplies'),
              value: _localFilter.excludeReplies,
              onChanged: (v) =>
                  _setLocal(_localFilter.copyWith(excludeReplies: v)),
            ),
            _switchRow(
              title: t('search.excludeRetweets'),
              value: _localFilter.excludeRetweets,
              onChanged: (v) =>
                  _setLocal(_localFilter.copyWith(excludeRetweets: v)),
            ),
          ] else ...[
            _switchRow(
              title: t('search.excludeReplies'),
              value: _xQuery.excludeReplies,
              onChanged: (v) =>
                  setState(() => _xQuery = _xQuery.copyWith(excludeReplies: v)),
            ),
            _switchRow(
              title: t('search.excludeRetweets'),
              value: _xQuery.excludeRetweets,
              onChanged: (v) => setState(
                () => _xQuery = _xQuery.copyWith(excludeRetweets: v),
              ),
            ),
            _switchRow(
              title: t('search.excludeLinks'),
              value: _xQuery.excludeLinks,
              onChanged: (v) =>
                  setState(() => _xQuery = _xQuery.copyWith(excludeLinks: v)),
            ),
            _switchRow(
              title: t('search.verified'),
              value: _xQuery.verifiedOnly,
              onChanged: (v) =>
                  setState(() => _xQuery = _xQuery.copyWith(verifiedOnly: v)),
            ),
          ],

          // X 模式额外：互动量 + 结果排序 + 预览 + 按钮
          if (!isLocal) ...[
            const SizedBox(height: 14),
            _label(theme, t('search.minFaves')),
            Row(
              children: [
                Expanded(child: _intBox(_faves, 'min_faves')),
                const SizedBox(width: 10),
                Expanded(child: _intBox(_retweets, 'min_retweets')),
                const SizedBox(width: 10),
                Expanded(child: _intBox(_replies, 'min_replies')),
              ],
            ),
            const SizedBox(height: 14),
            Center(
              child: SegmentedButton<SearchProduct>(
                showSelectedIcon: false,
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
                segments: [
                  ButtonSegment(
                    value: SearchProduct.top,
                    label: Text(t('search.productTop')),
                  ),
                  ButtonSegment(
                    value: SearchProduct.latest,
                    label: Text(t('search.productLatest')),
                  ),
                  ButtonSegment(
                    value: SearchProduct.media,
                    label: Text(t('search.productMedia')),
                  ),
                ],
                selected: {_product},
                onSelectionChanged: (s) => setState(() => _product = s.first),
              ),
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                _buildXQuery().isEmpty ? '—' : _buildXQuery(),
                maxLines: 4,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _buildXQuery().isEmpty ? null : _openXSearch,
                icon: const Icon(Icons.search, size: 18),
                label: Text(t('search.run')),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              t('search.rawHint'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ],
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  // ------------------------------------------------------------- 本地结果

  /// 本地结果的排序菜单（喜欢顺序 / 按发布日期 / 随机）。
  Widget _sortMenu(ThemeData theme) {
    String label(SortMode m) => switch (m) {
      SortMode.likeOrder => t('mode.likeOrder'),
      SortMode.publishDate => t('mode.publishDate'),
      SortMode.random => t('mode.random'),
    };
    return PopupMenuButton<SortMode>(
      tooltip: t('search.sort'),
      initialValue: _localSort,
      onSelected: (m) {
        if (m == _localSort) return;
        setState(() => _localSort = m);
        unawaited(_runLocal());
      },
      itemBuilder: (_) => [
        for (final m in SortMode.values)
          PopupMenuItem(value: m, child: Text(label(m))),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label(_localSort), style: theme.textTheme.labelMedium),
            const Icon(Icons.arrow_drop_down, size: 18),
          ],
        ),
      ),
    );
  }

  List<Widget> _localResultSlivers(ThemeData theme, List<LikeItem> items) {
    final source = _localSource;
    if (source == null) {
      return [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
            child: Text(
              t('search.idle'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ),
        ),
      ];
    }

    // 「全部」时同一条推文在喜欢和书签里各占一行：按 tweetId 去重，
    // 否则结果里会出现两条一模一样的帖子。
    final seen = <String>{};
    final unique = [
      for (final it in items)
        if (seen.add(it.tweetId)) it,
    ];

    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
          child: Row(
            children: [
              Text(
                tf('search.results', {'n': unique.length}),
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
              const Spacer(),
              _sortMenu(theme),
            ],
          ),
        ),
      ),
      if (unique.isEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(40),
            child: Center(
              child: source.loading
                  ? const CircularProgressIndicator()
                  : Text(t('search.empty')),
            ),
          ),
        )
      else
        SliverList.separated(
          itemCount: unique.length + (source.hasMore ? 1 : 0),
          separatorBuilder: (_, _) => const Divider(height: 1, thickness: 0.4),
          itemBuilder: (context, i) {
            if (i >= unique.length) {
              return const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            final item = unique[i];
            return PostCard(
              item: item,
              cache: _app?.mediaCache,
              onTap: () => _openFeed(source, item),
              onAvatarTap: () => item.author == null
                  ? null
                  : () => _openAuthorBy(
                      item.author!.screenName,
                      item.author!.name,
                    ),
            );
          },
        ),
    ];
  }

  // ------------------------------------------------------------- 小部件

  Widget _label(ThemeData theme, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(text, style: theme.textTheme.labelLarge),
  );

  /// 作者用下拉而不是输入框：本地库已经知道有哪些作者，
  /// 手打 `@screen_name` 既容易打错，也看不到「这个人我有多少条」。
  Widget _authorField(ThemeData theme, bool isLocal) {
    final current = isLocal ? _localFilter.authorScreenName : _xQuery.from;
    final names = <String>{..._authors.map((a) => a.screenName)};
    if (current != null && current.isNotEmpty) names.add(current);

    String labelOf(String screenName) {
      for (final a in _authors) {
        if (a.screenName == screenName) {
          final display = a.name.isEmpty ? a.screenName : a.name;
          return '$display · @${a.screenName} (${a.count})';
        }
      }
      return '@$screenName';
    }

    return DropdownButtonFormField<String>(
      initialValue: (current != null && names.contains(current))
          ? current
          : null,
      isExpanded: true,
      items: [
        DropdownMenuItem(value: null, child: Text(t('filter.all'))),
        for (final n in names)
          DropdownMenuItem(
            value: n,
            child: Text(labelOf(n), overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: (v) {
        if (isLocal) {
          _setLocal(
            v == null
                ? _localFilter.copyWith(clearAuthor: true)
                : _localFilter.copyWith(authorScreenName: v),
          );
        } else {
          setState(
            () => _xQuery = v == null
                ? _xQuery.copyWith(clearFrom: true)
                : _xQuery.copyWith(from: v),
          );
        }
      },
    );
  }

  Widget _switchRow({
    required String title,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) => SwitchListTile(
    contentPadding: EdgeInsets.zero,
    dense: true,
    title: Text(title),
    value: value,
    onChanged: onChanged,
  );

  Widget _intBox(TextEditingController c, String hint) => TextField(
    controller: c,
    keyboardType: TextInputType.number,
    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
    onChanged: (_) => setState(_syncXInts),
    decoration: InputDecoration(hintText: hint, isDense: true),
  );

  Widget _dateButton(
    ThemeData theme, {
    required String? value,
    required ValueChanged<String> onPick,
    required VoidCallback onClear,
  }) {
    return OutlinedButton(
      onPressed: () async {
        final picked = await showDatePicker(
          context: context,
          firstDate: DateTime(2006),
          lastDate: DateTime.now(),
          initialDate: value == null
              ? DateTime.now()
              : (DateTime.tryParse(value) ?? DateTime.now()),
        );
        if (picked != null) onPick(_fmtDate(picked));
      },
      child: Row(
        children: [
          const Icon(Icons.event, size: 16),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              value ?? '—',
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ),
          if (value != null)
            GestureDetector(
              onTap: onClear,
              child: const Icon(Icons.clear, size: 15),
            ),
        ],
      ),
    );
  }

  Widget _dateRangeButton(ThemeData theme) {
    final f = _localFilter;
    final hasRange = f.from != null && f.to != null;
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            icon: const Icon(Icons.event, size: 17),
            label: Text(
              hasRange
                  ? '${_fmtDate(f.from!)} → ${_fmtDate(f.to!)}'
                  : t('filter.dateRange'),
              overflow: TextOverflow.ellipsis,
            ),
            onPressed: () async {
              final now = DateTime.now();
              final range = await showDateRangePicker(
                context: context,
                firstDate: DateTime(2006),
                lastDate: now,
                initialDateRange: hasRange
                    ? DateTimeRange(start: f.from!, end: f.to!)
                    : null,
              );
              if (range == null) return;
              _setLocal(f.copyWith(from: range.start, to: range.end));
            },
          ),
        ),
        if (hasRange)
          IconButton(
            onPressed: () => _setLocal(f.copyWith(clearRange: true)),
            icon: const Icon(Icons.clear, size: 18),
          ),
      ],
    );
  }
}

// --------------------------------------------------------------------- 工具

String _fmtDate(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

String _mediaFilterLabel(SearchMediaFilter f) => switch (f) {
  SearchMediaFilter.any => t('search.mediaAll'),
  SearchMediaFilter.media => t('search.mediaAny'),
  SearchMediaFilter.images => t('filter.image'),
  SearchMediaFilter.videos => t('filter.video'),
  SearchMediaFilter.nativeVideo => t('search.mediaNativeVideo'),
};

String _mediaFilterLabelLocal(MediaFilter f) => switch (f) {
  MediaFilter.video => t('filter.video'),
  MediaFilter.image => t('filter.image'),
  MediaFilter.gif => t('filter.gif'),
  MediaFilter.text => t('filter.text'),
};

const Map<String, String> _langs = <String, String>{
  '': 'search.anyLanguage',
  'zh': '中文',
  'en': 'English',
  'ja': '日本語',
  'ko': '한국어',
  'es': 'Español',
  'fr': 'Français',
  'de': 'Deutsch',
  'ru': 'Русский',
  'pt': 'Português',
  'ar': 'العربية',
};

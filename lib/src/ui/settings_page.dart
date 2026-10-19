/// 设置页：账号、代理、自动同步、缓存、关于。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_controller.dart';
import '../core/l10n.dart';
import '../core/settings.dart';
import '../net/proxy.dart';
import '../version.dart';
import 'media_image.dart';
import 'queryid_probe_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late ProxyConfig _proxy;
  late AutoSyncSettings _auto;
  late PlaybackSettings _play;
  late int _cacheLimitMb;
  String? _lang;
  final _host = TextEditingController();
  final _port = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _maxItems = TextEditingController();
  bool _init = false;
  List<({String host, bool ok, int ms, String? note})>? _diag;
  bool _diagRunning = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_init) return;
    _init = true;
    final app = AppScope.of(context);
    _proxy = app.settings.proxy;
    _auto = app.settings.autoSync;
    _play = app.settings.playback;
    _cacheLimitMb = app.settings.cacheLimitMb;
    _lang = app.settings.language;
    _host.text = _proxy.host;
    _port.text = _proxy.port == 0 ? '' : '${_proxy.port}';
    _user.text = _proxy.username ?? '';
    _pass.text = _proxy.password ?? '';
    _maxItems.text = '${_auto.maxItems}';
  }

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _user.dispose();
    _pass.dispose();
    _maxItems.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(t('action.settings'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ---------------- 账号
          _section(context, t('settings.account')),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: app.session?.avatarUrl == null
                      ? const CircleAvatar(child: Icon(Icons.person))
                      : AuthorAvatar(url: app.session!.avatarUrl!, radius: 20),
                  title: Text(app.session?.displayName ?? ''),
                  subtitle: Text('@${app.session?.screenName ?? ''}'),
                  trailing: TextButton(
                    onPressed: () async {
                      await app.signOut();
                      if (context.mounted) Navigator.of(context).pop();
                    },
                    child: Text(t('action.logout')),
                  ),
                ),
                // 手机 Chrome 没有 F12，取 cookie 很难；桌面端登录后导出这一段，
                // 粘到手机登录页即可，省掉在手机上折腾开发者工具。
                ListTile(
                  leading: const Icon(Icons.ios_share),
                  title: Text(t('settings.exportSession')),
                  subtitle: Text(
                    t('settings.exported'),
                    style: theme.textTheme.bodySmall,
                  ),
                  onTap: () async {
                    final text = app.exportSession();
                    if (text == null) return;
                    await Clipboard.setData(ClipboardData(text: text));
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(t('settings.exported'))),
                    );
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // ---------------- 网络
          _section(context, t('settings.network')),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SegmentedButton<ProxyMode>(
                    segments: [
                      ButtonSegment(
                        value: ProxyMode.system,
                        label: Text(t('settings.proxySystem')),
                      ),
                      ButtonSegment(
                        value: ProxyMode.manual,
                        label: Text(t('settings.proxyManual')),
                      ),
                      ButtonSegment(
                        value: ProxyMode.direct,
                        label: Text(t('settings.proxyDirect')),
                      ),
                    ],
                    selected: {_proxy.mode},
                    onSelectionChanged: (s) {
                      setState(() => _proxy = _proxy.copyWith(mode: s.first));
                      _saveProxy(app);
                    },
                  ),
                  if (app.proxyWarning != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      app.proxyWarning!,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ],
                  if (_proxy.mode == ProxyMode.manual) ...[
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        SegmentedButton<ProxyType>(
                          segments: const [
                            ButtonSegment(
                              value: ProxyType.http,
                              label: Text('HTTP'),
                            ),
                            ButtonSegment(
                              value: ProxyType.socks5,
                              label: Text('SOCKS5'),
                            ),
                          ],
                          selected: {_proxy.type},
                          onSelectionChanged: (s) {
                            setState(
                              () => _proxy = _proxy.copyWith(type: s.first),
                            );
                            _saveProxy(app);
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          flex: 3,
                          child: TextField(
                            controller: _host,
                            decoration: InputDecoration(
                              labelText: t('settings.proxyHost'),
                            ),
                            onSubmitted: (_) => _saveProxy(app),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: _port,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              labelText: t('settings.proxyPort'),
                            ),
                            onSubmitted: (_) => _saveProxy(app),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _user,
                            decoration: InputDecoration(
                              labelText: t('settings.proxyUser'),
                            ),
                            onSubmitted: (_) => _saveProxy(app),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: _pass,
                            obscureText: true,
                            decoration: InputDecoration(
                              labelText: t('settings.proxyPass'),
                            ),
                            onSubmitted: (_) => _saveProxy(app),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton(
                        onPressed: () => _saveProxy(app),
                        child: Text(t('action.confirm')),
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      OutlinedButton.icon(
                        onPressed: _diagRunning
                            ? null
                            : () async {
                                setState(() {
                                  _diagRunning = true;
                                  _diag = null;
                                });
                                final r = await app.diagnoseConnectivity();
                                if (!mounted) return;
                                setState(() {
                                  _diag = r;
                                  _diagRunning = false;
                                });
                              },
                        icon: const Icon(Icons.network_check),
                        label: Text(t('settings.diagnose')),
                      ),
                      if (_diagRunning) ...[
                        const SizedBox(width: 12),
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ],
                    ],
                  ),
                  if (_diag != null) ...[
                    const SizedBox(height: 8),
                    for (final d in _diag!)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(
                          children: [
                            Icon(
                              d.ok ? Icons.check_circle : Icons.error,
                              size: 16,
                              color: d.ok
                                  ? Colors.green
                                  : theme.colorScheme.error,
                            ),
                            const SizedBox(width: 6),
                            Expanded(child: Text(d.host)),
                            Text(
                              '${d.ms}ms · ${d.note ?? ""}',
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // ---------------- 同步
          _section(context, t('settings.sync')),
          Card(
            child: Column(
              children: [
                // 全量回填从首页的溢出菜单搬到这里：它是「一次性大动作」，
                // 不该和列表上的日常操作挤在同一个菜单里。
                ListenableBuilder(
                  listenable: app.sync,
                  builder: (context, _) {
                    final busy = app.sync.busy;
                    final progress = app.sync.progress;
                    return ListTile(
                      leading: const Icon(Icons.cloud_download_outlined),
                      title: Text(
                        app.sync.backfillDone()
                            ? t('sync.backfill')
                            : t('sync.resume'),
                      ),
                      subtitle: Text(
                        busy && progress != null
                            ? '${progress.pages} ${t('sync.pages')} · '
                                  '${progress.fetched} ${t('sync.items')} · '
                                  '+${progress.inserted}'
                            : t('sync.backfillHint'),
                        style: theme.textTheme.bodySmall,
                      ),
                      trailing: busy
                          ? IconButton(
                              icon: const Icon(Icons.stop_circle_outlined),
                              onPressed: app.sync.cancel,
                            )
                          : const Icon(Icons.chevron_right),
                      onTap: busy ? null : () => _startBackfill(app),
                    );
                  },
                ),
                const Divider(height: 1),
                // 书签回填：和喜欢各有各的游标，互不影响。
                ListenableBuilder(
                  listenable: app.sync,
                  builder: (context, _) {
                    final busy = app.sync.busy;
                    return ListTile(
                      leading: const Icon(Icons.bookmark_border),
                      title: Text(
                        app.sync.backfillDone(kind: 'bookmark')
                            ? t('sync.backfillBookmarks')
                            : t('sync.resume'),
                      ),
                      subtitle: Text(
                        t('sync.backfillHintBookmarks'),
                        style: theme.textTheme.bodySmall,
                      ),
                      trailing: busy
                          ? IconButton(
                              icon: const Icon(Icons.stop_circle_outlined),
                              onPressed: app.sync.cancel,
                            )
                          : const Icon(Icons.chevron_right),
                      onTap: busy
                          ? null
                          : () => _startBackfill(app, kind: 'bookmark'),
                    );
                  },
                ),
                const Divider(height: 1),
                // 书签接口参数：失效时点一下，自动去 X 网页学当前值。
                ListTile(
                  leading: const Icon(Icons.key_outlined),
                  title: Text(t('settings.refreshQueryId')),
                  subtitle: Text(
                    t('settings.bookmarkQueryIdHint'),
                    style: theme.textTheme.bodySmall,
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _refreshQueryIds(app),
                ),
                const Divider(height: 1),
                SwitchListTile(
                  title: Text(t('settings.autoSync')),
                  subtitle: Text(t('settings.foregroundOnly')),
                  value: _auto.enabled,
                  onChanged: (v) async {
                    setState(() => _auto = _auto.copyWith(enabled: v));
                    // 走 controller 而不是直接写 settings：否则自动同步的定时器
                    // 不会跟着开关重启（开了也要等下次启动才生效）。
                    await app.setAutoSync(_auto);
                  },
                ),
                ListTile(
                  title: Text(t('settings.interval')),
                  trailing: DropdownButton<int>(
                    value: _auto.intervalMinutes,
                    items: const [15, 30, 60, 360, 1440]
                        .map(
                          (v) => DropdownMenuItem(
                            value: v,
                            child: Text(v >= 60 ? '${v ~/ 60}h' : '${v}m'),
                          ),
                        )
                        .toList(),
                    onChanged: (v) async {
                      if (v == null) return;
                      setState(
                        () => _auto = _auto.copyWith(intervalMinutes: v),
                      );
                      await app.setAutoSync(_auto);
                    },
                  ),
                ),
                ListTile(
                  title: Text(t('settings.range')),
                  trailing: DropdownButton<int?>(
                    value: _auto.rangeDays,
                    items: [
                      DropdownMenuItem(
                        value: null,
                        child: Text(t('filter.all')),
                      ),
                      const DropdownMenuItem(value: 7, child: Text('7d')),
                      const DropdownMenuItem(value: 30, child: Text('30d')),
                    ],
                    onChanged: (v) async {
                      setState(
                        () => _auto = v == null
                            ? _auto.copyWith(clearRange: true)
                            : _auto.copyWith(rangeDays: v),
                      );
                      await app.setAutoSync(_auto);
                    },
                  ),
                ),
                ListTile(
                  title: Text(t('settings.maxItems')),
                  trailing: SizedBox(
                    width: 100,
                    child: TextField(
                      controller: _maxItems,
                      keyboardType: TextInputType.number,
                      textAlign: TextAlign.end,
                      onSubmitted: (v) async {
                        final n = int.tryParse(v) ?? 500;
                        setState(() => _auto = _auto.copyWith(maxItems: n));
                        await app.setAutoSync(_auto);
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // ---------------- 界面语言
          _section(context, t('settings.language')),
          Card(
            child: ListTile(
              leading: const Icon(Icons.translate),
              title: Text(t('settings.language')),
              trailing: DropdownButton<String?>(
                value: _lang,
                items: [
                  DropdownMenuItem(
                    value: null,
                    alignment: AlignmentDirectional.centerEnd,
                    child: Text(t('settings.languageSystem')),
                  ),
                  DropdownMenuItem(
                    value: 'zh',
                    alignment: AlignmentDirectional.centerEnd,
                    child: Text(t('settings.languageChinese')),
                  ),
                  DropdownMenuItem(
                    value: 'en',
                    alignment: AlignmentDirectional.centerEnd,
                    child: Text(t('settings.languageEnglish')),
                  ),
                ],
                onChanged: (v) async {
                  setState(() => _lang = v);
                  await app.setLanguage(v);
                },
              ),
            ),
          ),
          const SizedBox(height: 16),

          // ---------------- 播放
          _section(context, t('settings.playback')),
          Card(
            child: Column(
              children: [
                ListTile(
                  title: Text(t('settings.doubleTapSeconds')),
                  subtitle: Text('${_play.doubleTapSeconds}s'),
                  trailing: SizedBox(
                    width: 120,
                    child: DropdownButton<int>(
                      value:
                          [5, 10, 15, 20, 30].contains(_play.doubleTapSeconds)
                          ? _play.doubleTapSeconds
                          : 10,
                      items: const [5, 10, 15, 20, 30]
                          .map(
                            (v) => DropdownMenuItem(
                              value: v,
                              alignment: AlignmentDirectional.centerEnd,
                              child: Text('${v}s'),
                            ),
                          )
                          .toList(),
                      onChanged: (v) {
                        if (v == null) return;
                        _savePlay(app, _play.copyWith(doubleTapSeconds: v));
                      },
                    ),
                  ),
                ),
                ListTile(
                  title: Text(t('settings.longPressSpeed')),
                  trailing: DropdownButton<double>(
                    value: _play.longPressSpeed,
                    items: const [1.5, 2.0, 2.5, 3.0]
                        .map(
                          (v) => DropdownMenuItem(
                            value: v,
                            alignment: AlignmentDirectional.centerEnd,
                            child: Text('${v}x'),
                          ),
                        )
                        .toList(),
                    onChanged: (v) {
                      if (v == null) return;
                      _savePlay(app, _play.copyWith(longPressSpeed: v));
                    },
                  ),
                ),
                // 「默认清晰度」也删了：清晰度是**当前这条**的即时选择，
                // 在播放页的「⋯」里调，设一个全局默认反而容易和实际不符。
                // 「自动升清晰 / 循环播放 / 保存到相册按钮」都搬到了播放页
                // 右上角的「⋯」里：它们是**当前这条**的即时选择，放在设置页
                // 既远又不像"设置"，改一次还得退出播放页。
                SwitchListTile(
                  title: Text(t('settings.autoPlayInList')),
                  value: _play.autoPlayInList,
                  onChanged: (v) =>
                      _savePlay(app, _play.copyWith(autoPlayInList: v)),
                ),
                // 低数据模式：不切画质、不升档、不后台缓存视频。
                // 本地有缓存就用缓存里最好的那档，没有就最低档。
                SwitchListTile(
                  title: Text(t('settings.lowData')),
                  value: app.settings.lowDataMode,
                  onChanged: (v) async {
                    await app.settings.setLowDataMode(v);
                    app.refreshSettings();
                    if (mounted) setState(() {});
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // ---------------- 界面
          _section(context, t('settings.ui')),
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  title: Text(t('settings.showMetrics')),
                  value: app.settings.showMetrics,
                  onChanged: (v) async {
                    await app.settings.setShowMetrics(v);
                    app.refreshSettings();
                    if (mounted) setState(() {});
                  },
                ),
                SwitchListTile(
                  title: Text(t('settings.keepAwake')),
                  value: app.settings.keepAwake,
                  onChanged: (v) async {
                    await app.settings.setKeepAwake(v);
                    app.refreshSettings();
                    if (mounted) setState(() {});
                  },
                ),
                ListTile(
                  title: Text(t('settings.navTabs')),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _editNavTabs(app),
                ),
                // 自动翻译：把列表里可见的外文正文显示成中文。
                // 优先用 X 自带的译文（零请求），X 没给才走在线翻译兜底。
                SwitchListTile(
                  title: Text(t('settings.autoTranslate')),
                  value: app.settings.autoTranslate,
                  onChanged: (v) async {
                    await app.settings.setAutoTranslate(v);
                    app.refreshSettings();
                    if (mounted) setState(() {});
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // ---------------- 缓存
          _section(context, t('settings.cache')),
          Card(
            child: Column(
              children: [
                ListTile(
                  title: Text(t('settings.cacheLimit')),
                  subtitle: Text('$_cacheLimitMb MB'),
                  trailing: SizedBox(
                    width: 180,
                    child: Slider(
                      value: _cacheLimitMb.toDouble(),
                      min: 512,
                      max: 51200,
                      divisions: 99,
                      label: '${(_cacheLimitMb / 1024).toStringAsFixed(1)} GB',
                      onChanged: (v) =>
                          setState(() => _cacheLimitMb = v.round()),
                      onChangeEnd: (v) async {
                        await app.settings.setCacheLimitMb(v.round());
                        final cache = app.mediaCache;
                        if (cache != null) {
                          // 上限改了要立刻生效，不能等下次启动。
                          cache.maxBytes = v.round() * 1024 * 1024;
                          cache.enforceLimit();
                        } else {
                          app.db.evictMediaCache(v.round() * 1024 * 1024);
                        }
                        if (mounted) setState(() {});
                      },
                    ),
                  ),
                ),
                ListTile(
                  title: Text(t('settings.cacheClear')),
                  subtitle: Text(
                    '${((app.mediaCache?.usedBytes ?? app.db.mediaCacheBytes()) / 1024 / 1024).toStringAsFixed(1)} MB',
                  ),
                  trailing: TextButton(
                    onPressed: () {
                      final cache = app.mediaCache;
                      if (cache != null) {
                        cache.clear();
                      } else {
                        app.db.evictMediaCache(0);
                      }
                      setState(() {});
                    },
                    child: Text(t('settings.cacheClear')),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // ---------------- 关于
          _section(context, t('settings.about')),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'X Like Manage · $kAppVersion',
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    t('settings.riskNote'),
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  Text('MIT License', style: theme.textTheme.bodySmall),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 底部导航：哪些显示、按什么顺序。
  ///
  /// 每一项都能拖动排序；除「设置」外都能隐藏（设置是唯一的自救入口）。
  Future<void> _editNavTabs(AppController app) async {
    final result = await showDialog<({List<String> order, Set<String> hidden})>(
      context: context,
      builder: (_) => _NavTabsDialog(
        initialOrder: app.settings.navOrder,
        initialHidden: app.settings.navHidden,
      ),
    );
    if (result == null) return;
    await app.settings.setNavConfig(order: result.order, hidden: result.hidden);
    app.refreshSettings();
    if (mounted) setState(() {});
  }

  Widget _section(BuildContext context, String title) => Padding(
    padding: const EdgeInsets.only(bottom: 8, top: 8),
    child: Text(title, style: Theme.of(context).textTheme.titleSmall),
  );

  Future<void> _startBackfill(AppController app, {String kind = 'like'}) async {
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
    if (ok == true) await app.sync.startBackfill(kind: kind);
  }

  /// 手动填写书签相关操作的 queryId。
  /// 自动学习书签相关接口当前的 queryId。
  ///
  /// 不用手填：探针页会打开一张真实推文、自己点一次书签再撤销、最后打开书签页，
  /// 从 WebView 拦到的 `/graphql/{queryId}/{operation}` 里把值读出来。
  Future<void> _refreshQueryIds(AppController app) async {
    const ops = ['Bookmarks', 'CreateBookmark', 'DeleteBookmark'];
    // 拿本地第一条喜欢当「试验田」；没有就用书签页（只学得到 Bookmarks）。
    final sample = app.browse.items.isEmpty
        ? null
        : app.browse.items.first.tweetId;
    final found = await Navigator.of(context).push<Map<String, String>>(
      MaterialPageRoute<Map<String, String>>(
        builder: (_) => QueryIdProbePage(operations: ops, tweetId: sample),
      ),
    );
    if (!mounted) return;
    if (found == null || found.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t('queryid.notFound'))));
      return;
    }
    for (final e in found.entries) {
      app.db.saveQueryId(e.key, e.value);
    }
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(tf('queryid.found', {'n': found.length}))),
    );
  }

  Future<void> _savePlay(AppController app, PlaybackSettings next) async {
    setState(() => _play = next);
    await app.setPlayback(next);
  }

  Future<void> _saveProxy(AppController app) async {
    final port = int.tryParse(_port.text) ?? 0;
    final cfg = _proxy.copyWith(
      host: _host.text.trim(),
      port: port,
      username: _user.text.trim().isEmpty ? null : _user.text.trim(),
      password: _pass.text.isEmpty ? null : _pass.text,
    );
    setState(() => _proxy = cfg);
    await app.applyProxy(cfg);
  }
}

/// 底部导航配置：**每一项都能拖动排序**，除「设置」外都能隐藏。
///
/// 「设置」不能隐藏：关掉之后用户就再也进不来这个页面，没有自救的入口。
/// 被隐藏的项仍然留在列表里（只是没勾），所以想放回来时位置还是原来的，
/// 不用重新拖一遍。
class _NavTabsDialog extends StatefulWidget {
  const _NavTabsDialog({
    required this.initialOrder,
    required this.initialHidden,
  });

  final List<String> initialOrder;
  final Set<String> initialHidden;

  @override
  State<_NavTabsDialog> createState() => _NavTabsDialogState();
}

class _NavTabsDialogState extends State<_NavTabsDialog> {
  late final List<String> _order = _normalize(widget.initialOrder);
  late final Set<String> _hidden = {
    for (final key in widget.initialHidden)
      if (AppSettings.allNavTabs.contains(key) &&
          key != AppSettings.pinnedNavTab)
        key,
  };

  static List<String> _normalize(List<String> input) {
    final out = <String>[];
    for (final key in input) {
      if (!AppSettings.allNavTabs.contains(key) || out.contains(key)) continue;
      out.add(key);
    }
    for (final key in AppSettings.allNavTabs) {
      if (!out.contains(key)) out.add(key);
    }
    return out;
  }

  String label(String key) => switch (key) {
    'bookmarks' => t('nav.bookmarks'),
    'search' => t('nav.search'),
    'swipe' => t('nav.swipe'),
    'grok' => t('nav.grok'),
    'settings' => t('nav.settings'),
    _ => t('nav.browse'),
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(t('settings.navTabs')),
      content: SizedBox(
        width: double.maxFinite,
        height: 400,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              t('settings.navTabsHint'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ReorderableListView.builder(
                itemCount: _order.length,
                // onReorderItem 已经把「先移除再插入」的下标偏移算好了。
                onReorderItem: (oldIndex, newIndex) {
                  setState(() {
                    final key = _order.removeAt(oldIndex);
                    _order.insert(newIndex.clamp(0, _order.length), key);
                  });
                },
                itemBuilder: (context, i) {
                  final key = _order[i];
                  final pinned = key == AppSettings.pinnedNavTab;
                  final shown = pinned || !_hidden.contains(key);
                  return ListTile(
                    key: ValueKey('nav-$key'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.drag_indicator),
                    title: Text(label(key)),
                    subtitle: pinned
                        ? Text(
                            t('settings.navTabsPinned'),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.outline,
                            ),
                          )
                        : null,
                    trailing: pinned
                        // 「设置」用一把小锁代替勾选框：一看就知道它动不了。
                        ? const Icon(
                            Icons.lock_outline,
                            size: 18,
                            color: Colors.grey,
                          )
                        : Checkbox(
                            value: shown,
                            onChanged: (v) => setState(() {
                              if (v == true) {
                                _hidden.remove(key);
                              } else {
                                _hidden.add(key);
                              }
                            }),
                          ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t('action.cancel')),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.pop(context, (order: _order, hidden: _hidden)),
          child: Text(t('action.confirm')),
        ),
      ],
    );
  }
}

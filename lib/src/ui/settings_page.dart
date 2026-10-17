/// 设置页：账号、代理、自动同步、缓存、关于。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_controller.dart';
import '../core/l10n.dart';
import '../core/settings.dart';
import '../net/proxy.dart';
import 'media_image.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late ProxyConfig _proxy;
  late AutoSyncSettings _auto;
  late int _cacheLimitMb;
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
    _cacheLimitMb = app.settings.cacheLimitMb;
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
                          label: Text(t('settings.proxySystem'))),
                      ButtonSegment(
                          value: ProxyMode.manual,
                          label: Text(t('settings.proxyManual'))),
                      ButtonSegment(
                          value: ProxyMode.direct,
                          label: Text(t('settings.proxyDirect'))),
                    ],
                    selected: {_proxy.mode},
                    onSelectionChanged: (s) {
                      setState(() => _proxy = _proxy.copyWith(mode: s.first));
                      _saveProxy(app);
                    },
                  ),
                  if (app.proxyWarning != null) ...[
                    const SizedBox(height: 8),
                    Text(app.proxyWarning!,
                        style: TextStyle(color: theme.colorScheme.error)),
                  ],
                  if (_proxy.mode == ProxyMode.manual) ...[
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        SegmentedButton<ProxyType>(
                          segments: const [
                            ButtonSegment(
                                value: ProxyType.http, label: Text('HTTP')),
                            ButtonSegment(
                                value: ProxyType.socks5, label: Text('SOCKS5')),
                          ],
                          selected: {_proxy.type},
                          onSelectionChanged: (s) {
                            setState(() =>
                                _proxy = _proxy.copyWith(type: s.first));
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
                            decoration:
                                InputDecoration(labelText: t('settings.proxyHost')),
                            onSubmitted: (_) => _saveProxy(app),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: _port,
                            keyboardType: TextInputType.number,
                            decoration:
                                InputDecoration(labelText: t('settings.proxyPort')),
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
                            decoration:
                                InputDecoration(labelText: t('settings.proxyUser')),
                            onSubmitted: (_) => _saveProxy(app),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: _pass,
                            obscureText: true,
                            decoration:
                                InputDecoration(labelText: t('settings.proxyPass')),
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
                              color: d.ok ? Colors.green : theme.colorScheme.error,
                            ),
                            const SizedBox(width: 6),
                            Expanded(child: Text(d.host)),
                            Text('${d.ms}ms · ${d.note ?? ""}',
                                style: theme.textTheme.bodySmall),
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
                        .map((v) => DropdownMenuItem(
                              value: v,
                              child: Text(v >= 60 ? '${v ~/ 60}h' : '${v}m'),
                            ))
                        .toList(),
                    onChanged: (v) async {
                      if (v == null) return;
                      setState(() => _auto = _auto.copyWith(intervalMinutes: v));
                      await app.setAutoSync(_auto);
                    },
                  ),
                ),
                ListTile(
                  title: Text(t('settings.range')),
                  trailing: DropdownButton<int?>(
                    value: _auto.rangeDays,
                    items: [
                      DropdownMenuItem(value: null, child: Text(t('filter.all'))),
                      const DropdownMenuItem(value: 7, child: Text('7d')),
                      const DropdownMenuItem(value: 30, child: Text('30d')),
                    ],
                    onChanged: (v) async {
                      setState(() => _auto = v == null
                          ? _auto.copyWith(clearRange: true)
                          : _auto.copyWith(rangeDays: v));
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
                      onChanged: (v) => setState(() => _cacheLimitMb = v.round()),
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
                      '${((app.mediaCache?.usedBytes ?? app.db.mediaCacheBytes()) / 1024 / 1024).toStringAsFixed(1)} MB'),
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
                  Text('X Like Manage · 0.1.0', style: theme.textTheme.titleSmall),
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

  Widget _section(BuildContext context, String title) => Padding(
        padding: const EdgeInsets.only(bottom: 8, top: 8),
        child: Text(title, style: Theme.of(context).textTheme.titleSmall),
      );

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

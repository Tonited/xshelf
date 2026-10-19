/// 联网集成测试：直接跑 app 自己的代码路径打真实 X 接口。
///
/// 这不是 mock —— 它验证的是：
///   1. `XClient.verify()` 用 GraphQL `Viewer`（而不是已下线的 verify_credentials）
///   2. `kFallbackQueryIds` 里的 queryId 真的能用（首页被 Cloudflare 挡时不至于全废）
///   3. `fetchLikes()` + 解析器能把真实响应变成 LikeItem
///
/// 需要一份真实 cookie（由 `tool/xauto.js google-login` 产出）：
///   build/auth_probe/cookies.json
/// 没有这个文件时自动跳过，所以不会拖累普通 CI。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/io_client.dart';
import 'package:xlikemanage/src/sync/x_client.dart';

const _proxyHost = '127.0.0.1';
const _proxyPort = 7897;

void main() {
  final cookieFile = File('build/auth_probe/cookies.json');
  if (!cookieFile.existsSync()) {
    test('live X integration (skipped: no cookies.json)', () {}, skip: true);
    return;
  }

  final cookies =
      jsonDecode(cookieFile.readAsStringSync()) as Map<String, dynamic>;
  final authToken = cookies['auth_token'] as String?;
  final ct0 = cookies['ct0'] as String?;
  final twid = (cookies['twid'] as String?) ?? '';
  final userId =
      RegExp(r'u=(\d+)').firstMatch(Uri.decodeComponent(twid))?.group(1) ?? '';

  if (authToken == null || ct0 == null) {
    test('live X integration (skipped: cookies incomplete)', () {}, skip: true);
    return;
  }

  late IOClient httpClient;

  setUpAll(() {
    // 和 app 一样走系统/手动代理；这里显式指到本机代理端口。
    final inner = HttpClient()
      ..findProxy = ((uri) => 'PROXY $_proxyHost:$_proxyPort')
      ..connectionTimeout = const Duration(seconds: 20);
    httpClient = IOClient(inner);
  });

  tearDownAll(() => httpClient.close());

  test('Viewer validates the session and returns the account', () async {
    final client = XClient(
      session: XSession(authToken: authToken, ct0: ct0, userId: userId),
      httpClient: httpClient,
    );

    final verified = await client.verify();

    // ignore: avoid_print
    print('verified: @${verified.screenName} (${verified.displayName}) '
        'id=${verified.userId} avatar=${verified.avatarUrl}');
    expect(verified.screenName, isNotNull);
    expect(verified.screenName!.isNotEmpty, isTrue);
    expect(verified.userId, isNotEmpty);
    expect(verified.avatarUrl, isNotNull);
  });

  test('fetchLikes returns real items with authors and media flags', () async {
    final client = XClient(
      session: XSession(authToken: authToken, ct0: ct0, userId: userId),
      httpClient: httpClient,
    );

    final page = await client.fetchLikes(count: 20);

    // ignore: avoid_print
    print('items=${page.items.length} hasMore=${page.hasMore} '
        'topCursor=${page.topCursor != null}');
    for (final item in page.items.take(3)) {
      // ignore: avoid_print
      print(' - @${item.author?.screenName} | '
          '${item.text.replaceAll('\n', ' ').substring(0, item.text.length.clamp(0, 40) > 40 ? 40 : item.text.length)} '
          '| media=${item.media.length}');
    }

    expect(page.items, isNotEmpty);
    expect(page.items.first.tweetId, isNotEmpty);
    expect(page.items.first.author?.screenName, isNotNull);
    expect(page.bottomCursor, isNotNull);
  }, timeout: const Timeout(Duration(minutes: 3)));
}

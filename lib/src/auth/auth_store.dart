/// 登录态存储：cookie 只落在系统安全存储（Windows DPAPI / Android Keystore）。
///
/// 安全存储不是「必须成功」的：某些 Android 机型/ROM 的 Keystore 会直接抛
/// （坏掉的 EncryptedSharedPreferences 密钥、被 root 后禁用的硬件密钥等）。
/// 那种情况下整条启动链会断掉，用户看到的就是「Sign-in failed」而毫无线索。
/// 所以这里把失败降级成「这次运行不记忆登录态」，并把原因记在 [lastError] 里。
library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../sync/x_client.dart';

class AuthStore {
  AuthStore([FlutterSecureStorage? storage])
    : _storage =
          storage ??
          const FlutterSecureStorage(
            // Windows：只用 Dart + DPAPI 的文件存储。上游的「向后兼容」通道是
            // C++/ATL 实现，我们已经在 third_party 里把它去掉了（见 pubspec.yaml），
            // 这里显式关掉，保证永远不会调到那个 MethodChannel。
            wOptions: WindowsOptions(useBackwardCompatibility: false),
          );

  final FlutterSecureStorage _storage;

  /// 最近一次安全存储操作的失败原因（null = 正常）。
  String? lastError;
  bool get degraded => lastError != null;

  static const _key = 'x.session.v1';

  Future<XSession?> load() async {
    final String? raw;
    try {
      raw = await _storage.read(key: _key);
      lastError = null;
    } catch (e) {
      lastError = '$e';
      return null;
    }
    if (raw == null || raw.isEmpty) return null;
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return null;
      final session = XSession.fromJson(Map<String, Object?>.from(json));
      if (session.authToken.isEmpty || session.ct0.isEmpty) return null;
      return session;
    } catch (_) {
      return null;
    }
  }

  Future<void> save(XSession session) async {
    try {
      await _storage.write(key: _key, value: jsonEncode(session.toJson()));
      lastError = null;
    } catch (e) {
      lastError = '$e';
    }
  }

  Future<void> clear() async {
    try {
      await _storage.delete(key: _key);
      lastError = null;
    } catch (e) {
      lastError = '$e';
    }
  }
}

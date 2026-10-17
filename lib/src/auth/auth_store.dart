/// 登录态存储：cookie 只落在系统安全存储（Windows DPAPI / Android Keystore）。
library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../sync/x_client.dart';

class AuthStore {
  AuthStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _key = 'x.session.v1';

  Future<XSession?> load() async {
    final raw = await _storage.read(key: _key);
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

  Future<void> save(XSession session) =>
      _storage.write(key: _key, value: jsonEncode(session.toJson()));

  Future<void> clear() => _storage.delete(key: _key);
}

/// 媒体缓存：按需把图片/视频落盘，超上限按 LRU 淘汰。
///
/// 图片默认不预下载（X 的 CDN 很快，`Image.network` 自带内存缓存），
/// 只有用户点「离线保存」或播放视频时才落盘。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../db/app_database.dart';

class MediaCache {
  MediaCache({
    required this.db,
    required this.httpClient,
    required this.rootDir,
    this.maxBytes = 5 * 1024 * 1024 * 1024,
  });

  final AppDatabase db;
  final http.Client httpClient;
  final Directory rootDir;
  int maxBytes;

  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36';

  String _relPath(String tweetId, int idx, String url) {
    final ext = _extensionOf(url);
    return p.join('media', tweetId, '$idx$ext');
  }

  File fileFor(String tweetId, int idx, String url) =>
      File(p.join(rootDir.path, _relPath(tweetId, idx, url)));

  /// 已缓存则直接返回；否则下载。
  Future<File?> ensureCached({
    required String tweetId,
    required int idx,
    required String url,
    void Function(int received, int? total)? onProgress,
  }) async {
    final existing = db.localMediaPath(tweetId, idx);
    if (existing != null) {
      final f = File(existing);
      if (f.existsSync()) {
        db.touchMedia(tweetId);
        return f;
      }
    }

    final target = fileFor(tweetId, idx, url);
    await target.parent.create(recursive: true);

    try {
      final resp = await httpClient.get(
        Uri.parse(url),
        headers: const {'user-agent': _userAgent, 'referer': 'https://x.com/'},
      );
      if (resp.statusCode != 200) return null;
      final Uint8List bytes = resp.bodyBytes;
      await target.writeAsBytes(bytes, flush: true);
      db.markMediaCached(tweetId, idx, target.path, bytes.length);
      enforceLimit();
      return target;
    } catch (_) {
      return null;
    }
  }

  /// 清到上限以下（LRU）。
  int enforceLimit() {
    if (maxBytes <= 0) return 0;
    return db.evictMediaCache(maxBytes);
  }

  /// 当前占用。
  int get usedBytes => db.mediaCacheBytes();

  /// 清空（设置页用）。
  void clear() {
    final dir = Directory(p.join(rootDir.path, 'media'));
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    db.evictMediaCache(0);
  }

  String _extensionOf(String url) {
    final path = Uri.tryParse(url)?.path ?? '';
    final ext = p.extension(path);
    if (ext.isEmpty || ext.length > 5) return '.bin';
    return ext;
  }
}

/// 媒体缓存：按需把图片/视频落盘，超上限按 LRU 淘汰。
///
/// 图片默认不预下载（X 的 CDN 很快，`Image.network` 自带内存缓存），
/// 只有用户点「离线保存」或播放视频时才落盘。
library;

import 'dart:io';

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

  /// `tweetId/idx` → 本地路径（null 表示没缓存过）。
  ///
  /// 网格里每张卡片都要问一次「本地有吗」，一屏 60 张就是 60 条 SQL；
  /// 这里按需查一次并记住。命中缓存时仍会 `existsSync` 校验，文件被外部删掉
  /// 也能自愈。
  final Map<String, String?> _pathMemo = {};

  /// 正在下载的媒体：同一个文件被两个入口同时请求时只下载一次。
  final Map<String, Future<File?>> _inflight = {};

  String _key(String tweetId, int idx) => '$tweetId/$idx';

  String _relPath(String tweetId, int idx, String url) {
    final ext = _extensionOf(url);
    return p.join('media', tweetId, '$idx$ext');
  }

  File fileFor(String tweetId, int idx, String url) =>
      File(p.join(rootDir.path, _relPath(tweetId, idx, url)));

  /// 已缓存的本地文件；没有则 null。
  File? cachedFile(String tweetId, int idx) {
    final key = _key(tweetId, idx);
    var path = _pathMemo[key];
    if (path == null && !_pathMemo.containsKey(key)) {
      path = db.localMediaPath(tweetId, idx);
      _pathMemo[key] = path;
    }
    if (path == null) return null;
    final file = File(path);
    if (!file.existsSync()) {
      _pathMemo.remove(key);
      return null;
    }
    return file;
  }

  /// 已缓存则直接返回；否则下载。
  Future<File?> ensureCached({
    required String tweetId,
    required int idx,
    required String url,
    void Function(int received, int? total)? onProgress,
  }) {
    final existing = cachedFile(tweetId, idx);
    if (existing != null) {
      db.touchMedia(tweetId);
      return Future.value(existing);
    }
    final key = _key(tweetId, idx);
    final running = _inflight[key];
    if (running != null) return running;
    final future = _download(tweetId, idx, url, onProgress)
        .whenComplete(() => _inflight.remove(key));
    _inflight[key] = future;
    return future;
  }

  Future<File?> _download(
    String tweetId,
    int idx,
    String url,
    void Function(int received, int? total)? onProgress,
  ) async {
    final target = fileFor(tweetId, idx, url);
    await target.parent.create(recursive: true);
    final partial = File('${target.path}.part');

    try {
      final request = http.Request('GET', Uri.parse(url))
        ..headers.addAll(const {
          'user-agent': _userAgent,
          'referer': 'https://x.com/',
        });
      final resp = await httpClient.send(request);
      if (resp.statusCode != 200) {
        _deleteQuietly(partial);
        return null;
      }

      // 边收边写：视频动辄上百 MB，以前把整包 bodyBytes 攒在内存里，
      // Android 上很容易直接 OOM。
      final sink = partial.openWrite();
      var received = 0;
      try {
        await for (final chunk in resp.stream) {
          received += chunk.length;
          sink.add(chunk);
          onProgress?.call(received, resp.contentLength);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }

      if (target.existsSync()) target.deleteSync();
      await partial.rename(target.path);
      db.markMediaCached(tweetId, idx, target.path, received);
      _pathMemo[_key(tweetId, idx)] = target.path;
      enforceLimit();
      return target;
    } catch (_) {
      _deleteQuietly(partial);
      return null;
    }
  }

  /// 清到上限以下（LRU）。
  int enforceLimit() {
    if (maxBytes <= 0) return 0;
    final freed = db.evictMediaCache(maxBytes);
    if (freed > 0) _pathMemo.clear();
    return freed;
  }

  /// 当前占用。
  int get usedBytes => db.mediaCacheBytes();

  /// 清空（设置页用）。
  void clear() {
    final dir = Directory(p.join(rootDir.path, 'media'));
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    db.evictMediaCache(0);
    _pathMemo.clear();
  }

  String _extensionOf(String url) {
    final path = Uri.tryParse(url)?.path ?? '';
    final ext = p.extension(path);
    if (ext.isEmpty || ext.length > 5) return '.bin';
    return ext;
  }
}

/// 小工具：静默删掉临时文件。
void _deleteQuietly(File f) {
  try {
    if (f.existsSync()) f.deleteSync();
  } catch (_) {
    // 删不掉也不影响主流程，下次会覆盖。
  }
}

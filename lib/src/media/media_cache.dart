/// 媒体缓存：按需把图片/视频落盘，超上限按 LRU 淘汰。
///
/// 图片默认不预下载（X 的 CDN 很快，`Image.network` 自带内存缓存），
/// 只有用户点「离线保存」或播放视频时才落盘。
///
/// 这里还兼管**画质记忆**（跨会话）：
/// - `cache_variant`：本地文件到底是哪一档；
/// - `best_variant`：这条媒体**真的播过/显示过**的最高档。
///
/// 为什么要记：用户抱怨「明明升过画质，再点进来还是先糊一下」。原因是以前
/// 起播永远从最低档开始，而且缓存文件不带档位信息 —— 切档读到同一个文件，
/// 看起来就是「切了没反应」。记下来之后，下次打开直接从看过的最好画质起播，
/// 有本地文件时零网络。
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

  /// `tweetId/idx` → 本地路径与画质记录（null 表示没缓存过）。
  ///
  /// 网格里每张卡片都要问一次「本地有吗」，一屏 60 张就是 60 条 SQL；
  /// 这里按需查一次并记住。命中缓存时仍会 `existsSync` 校验，文件被外部删掉
  /// 也能自愈。
  final Map<String, _MediaMeta> _meta = {};

  /// 正在下载的媒体：同一个文件被两个入口同时请求时只下载一次。
  final Map<String, Future<File?>> _inflight = {};

  String _key(String tweetId, int idx) => '$tweetId/$idx';

  String _relPath(String tweetId, int idx, String url) {
    final ext = _extensionOf(url);
    return p.join('media', tweetId, '$idx$ext');
  }

  File fileFor(String tweetId, int idx, String url) =>
      File(p.join(rootDir.path, _relPath(tweetId, idx, url)));

  _MediaMeta _metaOf(String tweetId, int idx) {
    final key = _key(tweetId, idx);
    final memo = _meta[key];
    if (memo != null) return memo;
    final row = db.mediaCacheRow(tweetId, idx);
    final m = _MediaMeta(
      path: row.path,
      cacheVariant: row.cacheVariant,
      bestVariant: row.bestVariant,
      bestRank: row.bestRank,
    );
    // 文件被外部删掉（清缓存/换盘）时自愈：把记录也清掉。
    if (m.path != null && !File(m.path!).existsSync()) {
      m.path = null;
      m.cacheVariant = null;
      db.clearMediaPath(tweetId, idx);
    }
    _meta[key] = m;
    return m;
  }

  /// 已缓存的本地文件；没有则 null。
  File? cachedFile(String tweetId, int idx) {
    final path = _metaOf(tweetId, idx).path;
    if (path == null) return null;
    return File(path);
  }

  /// 只返回「图片」缓存文件。
  ///
  /// 同一个 `(tweetId, idx)` 位置，视频缓存下来的是 **mp4**。以前列表封面也照着
  /// 这个路径去读，`Image.file` 解 mp4 必然失败 —— 表现就是「播放过的视频在列表里
  /// 没有封面了」。所以封面只认真正的图片后缀。
  File? cachedImageFile(String tweetId, int idx) {
    final f = cachedFile(tweetId, idx);
    if (f == null) return null;
    final ext = p.extension(f.path).toLowerCase();
    return _imageExtensions.contains(ext) ? f : null;
  }

  /// 这些后缀的缓存文件才是图片（视频是 mp4/m3u8，不能拿来当封面解码）。
  static const Set<String> _imageExtensions = {
    '.jpg',
    '.jpeg',
    '.png',
    '.webp',
    '.gif',
    '.avif',
    '.heic',
  };

  /// 本地文件是哪一档（[PlaybackSource.key]）；没有文件/老缓存没记过则为 null。
  String? cachedVariant(String tweetId, int idx) => _metaOf(tweetId, idx).cacheVariant;

  /// 这条媒体看过（播过/显示过）的最好档位。
  String? bestVariant(String tweetId, int idx) => _metaOf(tweetId, idx).bestVariant;

  /// 只有「本地文件正是这一档」时才返回文件。
  ///
  /// 这一条是整个画质切换的关键：以前无论请求哪一档都优先读本地文件，
  /// 而缓存里永远是最佳档，于是「切到低画质」切了个寂寞。
  File? fileForVariant(String tweetId, int idx, String variant) {
    final m = _metaOf(tweetId, idx);
    if (m.path == null) return null;
    // 老版本缓存没记档位：它下的就是最高档，按「命中」处理。
    if (m.cacheVariant == null) return File(m.path!);
    if (m.cacheVariant != variant) return null;
    return File(m.path!);
  }

  /// 记住这条媒体用过这一档（只有更高才会覆盖）。
  void rememberVariant(String tweetId, int idx, String variant, int rank) {
    final m = _metaOf(tweetId, idx);
    if (m.bestVariant == variant) return;
    final current = m.bestRank;
    if (current != null && current >= rank) return;
    m.bestVariant = variant;
    m.bestRank = rank;
    db.rememberMediaVariant(tweetId, idx, variant, rank);
  }

  /// 文件坏了：丢掉本地记录（画质记忆保留），下次重下。
  void forgetCachedFile(String? tweetId, int idx) {
    if (tweetId == null) return;
    final m = _metaOf(tweetId, idx);
    final path = m.path;
    m.path = null;
    m.cacheVariant = null;
    db.clearMediaPath(tweetId, idx);
    if (path != null) {
      try {
        final f = File(path);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {
        // 删不掉也无所谓，记录已经清掉了。
      }
    }
  }

  /// 已缓存则直接返回；否则下载。
  ///
  /// [variant]/[rank] 描述「这个 url 是哪一档」，会一并记进库；
  /// 不传也能工作（老调用点），只是无法参与画质记忆。
  Future<File?> ensureCached({
    required String tweetId,
    required int idx,
    required String url,
    String? variant,
    int rank = 0,
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
    final future = _download(tweetId, idx, url, variant, rank, onProgress)
        .whenComplete(() => _inflight.remove(key));
    _inflight[key] = future;
    return future;
  }

  Future<File?> _download(
    String tweetId,
    int idx,
    String url,
    String? variant,
    int rank,
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
      db.markMediaCached(tweetId, idx, target.path, received,
          variant: variant, rank: rank);
      final m = _metaOf(tweetId, idx);
      m.path = target.path;
      m.cacheVariant = variant;
      if (rank > 0 && (m.bestRank == null || rank > m.bestRank!)) {
        m.bestVariant = variant;
        m.bestRank = rank;
      }
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
    if (freed > 0) _meta.clear();
    return freed;
  }

  /// 当前占用。
  int get usedBytes => db.mediaCacheBytes();

  /// 清空（设置页用）。
  void clear() {
    final dir = Directory(p.join(rootDir.path, 'media'));
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    db.evictMediaCache(0);
    _meta.clear();
  }

  String _extensionOf(String url) {
    final path = Uri.tryParse(url)?.path ?? '';
    final ext = p.extension(path);
    if (ext.isEmpty || ext.length > 5) return '.bin';
    return ext;
  }
}

/// 一条媒体的本地缓存与画质记录（内存版，省掉每张卡片的 SQL）。
class _MediaMeta {
  _MediaMeta({
    this.path,
    this.cacheVariant,
    this.bestVariant,
    this.bestRank,
  });

  String? path;
  String? cacheVariant;
  String? bestVariant;
  int? bestRank;
}

// ---------------------------------------------------------------- 图片档位
//
// 图片和视频共用 `media.best_variant / best_rank` 两列：一行媒体只可能是图或视频，
// 不会冲突。图片用 `img:<name>` 当 key，分值是固定的几档。

const String _imageKeyPrefix = 'img:';

/// X 图片的尺寸档位 → 清晰度分值。
int imageVariantRank(String name) => switch (name) {
      'thumb' => 1,
      'small' => 2,
      'medium' => 3,
      'large' => 4,
      'orig' => 5,
      _ => 2,
    };

String imageVariantKey(String name) => '$_imageKeyPrefix$name';

/// 从记忆里的 key 反推分值（不是图片 key 时返回 null）。
int? imageVariantRankFromKey(String key) {
  if (!key.startsWith(_imageKeyPrefix)) return null;
  return imageVariantRank(key.substring(_imageKeyPrefix.length));
}

/// 小工具：静默删掉临时文件。
void _deleteQuietly(File f) {
  try {
    if (f.existsSync()) f.deleteSync();
  } catch (_) {
    // 删不掉也不影响主流程，下次会覆盖。
  }
}

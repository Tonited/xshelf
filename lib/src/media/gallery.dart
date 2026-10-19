/// 把图片/视频存进系统相册。
///
/// 为什么单独一层：`gal` 的 API 很薄（`putImage` / `putVideo` 只吃本地路径），
/// 而我们的媒体本来就是「缓存优先」的 —— 已缓存就直接用缓存文件，没缓存才下载。
/// 这一层把「拿本地文件 → 写相册 → 翻译错误」收在一处，播放页只管调。
///
/// Android 注意：API 29+ 走 MediaStore 不需要权限；26–28 需要
/// `WRITE_EXTERNAL_STORAGE`（已在 AndroidManifest 里用 maxSdkVersion=28 声明）。
library;

import 'dart:io';

import 'package:gal/gal.dart';

import '../core/l10n.dart';
import 'media_cache.dart';

/// 保存结果：null 表示成功，否则是给用户看的错误文案。
Future<String?> saveMediaToGallery({
  required MediaCache cache,
  required String tweetId,
  required int idx,
  required String url,
  required bool isVideo,
}) async {
  try {
    // 1. 本地文件：命中缓存直接用，否则下载（和播放共用同一个缓存，不重复下）。
    final file = await cache.ensureCached(
      tweetId: tweetId,
      idx: idx,
      url: url,
    );
    if (file == null || !file.existsSync()) {
      return t('gallery.downloadFailed');
    }

    // 2. 权限：API 33+ 需要请求一次；29–32 默认有；26–28 需要写外部存储。
    if (!await Gal.hasAccess()) {
      final granted = await Gal.requestAccess();
      if (!granted) return t('gallery.noAccess');
    }

    // 3. 写相册。album 用 App 名，方便用户在相册里找到。
    if (isVideo) {
      await Gal.putVideo(file.path, album: _album);
    } else {
      await Gal.putImage(file.path, album: _album);
    }
    return null;
  } on GalException catch (e) {
    return _translate(e);
  } catch (e) {
    // 相册写入失败的原因（权限/格式/存储满）不值得逐个建模，直接把原始错误
    // 带出去；用户至少能看出是「下载失败」还是「写相册被拒」。
    return '$e';
  }
}

const String _album = 'X Like Manage';

String _translate(GalException e) {
  switch (e.type) {
    case GalExceptionType.accessDenied:
      return t('gallery.noAccess');
    case GalExceptionType.notEnoughSpace:
      return t('gallery.noSpace');
    case GalExceptionType.notSupportedFormat:
      return t('gallery.unsupported');
    case GalExceptionType.unexpected:
      return e.toString();
  }
}

/// 本地已缓存的文件（预览/分享用）。
File? cachedMediaFile({
  required MediaCache cache,
  required String tweetId,
  required int idx,
}) =>
    cache.cachedFile(tweetId, idx);

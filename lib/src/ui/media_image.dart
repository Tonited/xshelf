/// 统一的图片渲染：本地缓存优先，其次 X 的 CDN。
///
/// 为什么单独一个 widget：
/// - 网格/详情/头像三处都要「有本地文件就用本地文件」，否则离线保存后仍然拉网；
/// - `Image.network` 的 `cacheWidth` + `FilterQuality.low` 能显著降低解码内存，
///   在 5 万条级别的浏览里这是主要的卡顿来源。
library;

import 'package:flutter/material.dart';

import '../media/media_cache.dart';

class MediaImage extends StatelessWidget {
  const MediaImage({
    super.key,
    required this.url,
    this.cache,
    this.tweetId,
    this.idx = 0,
    this.fit = BoxFit.cover,
    this.cacheWidth,
    this.alignment = Alignment.center,
  });

  final String url;

  /// 为空时退化成纯网络图片（测试环境就是这样）。
  final MediaCache? cache;
  final String? tweetId;
  final int idx;
  final BoxFit fit;
  final int? cacheWidth;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).colorScheme.surfaceContainerHighest;

    Widget fallback(Widget child) => ColoredBox(
          color: surface,
          child: Center(child: child),
        );

    final local =
        (cache != null && tweetId != null) ? cache!.cachedFile(tweetId!, idx) : null;
    if (local != null) {
      return Image.file(
        local,
        fit: fit,
        alignment: alignment,
        cacheWidth: cacheWidth,
        filterQuality: FilterQuality.low,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) =>
            fallback(const Icon(Icons.broken_image_outlined)),
      );
    }

    return Image.network(
      url,
      fit: fit,
      alignment: alignment,
      cacheWidth: cacheWidth,
      filterQuality: FilterQuality.low,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) =>
          fallback(const Icon(Icons.broken_image_outlined)),
      loadingBuilder: (context, child, progress) =>
          progress == null ? child : fallback(const SizedBox.shrink()),
    );
  }
}

/// 圆形头像（作者）：尺寸很小，单独给一个小的解码宽度。
class AuthorAvatar extends StatelessWidget {
  const AuthorAvatar({super.key, required this.url, this.radius = 14});

  final String url;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      radius: radius,
      backgroundColor:
          Theme.of(context).colorScheme.surfaceContainerHighest,
      child: ClipOval(
        child: SizedBox(
          width: radius * 2,
          height: radius * 2,
          child: MediaImage(
            url: url,
            cacheWidth: (radius * 2 * MediaQuery.devicePixelRatioOf(context))
                .round(),
            fit: BoxFit.cover,
          ),
        ),
      ),
    );
  }
}

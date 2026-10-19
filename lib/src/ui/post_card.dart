/// X 风格的一条「喜欢」：头像 + 作者 + 时间 + 正文 + 媒体网格。
///
/// 这是唯一的主浏览视图（原来的网格已被替换）。设计上贴着 X 自己的时间线：
/// 文字和媒体同等重要，所以纯文字推文也占正常的纵向空间、可读 4~6 行；
/// 图片/视频走 1/2/3/4 张的分形布局，避免所有媒体都是一样大的方块。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../core/l10n.dart';
import '../media/media_cache.dart';
import '../media/quality.dart';
import '../model/like_item.dart';
import 'media_image.dart';
import 'rich_text.dart';
import 'translatable_body.dart';
import 'video_view.dart';
import 'x_nav.dart';
import 'x_web_page.dart';

class PostCard extends StatelessWidget {
  const PostCard({
    super.key,
    required this.item,
    required this.onTap,
    this.onAvatarTap,
    this.cache,
    this.selected = false,
    this.highlights = const [],
    this.autoPlayVideo = false,
  });

  final LikeItem item;
  final VoidCallback onTap;
  final VoidCallback? onAvatarTap;
  final MediaCache? cache;
  final bool selected;

  /// 搜索命中词在正文里的区间（UTF-16 偏移），由 X 的 `textHighlights` 给出。
  /// 本地列表传空即可。
  final List<({int start, int end})> highlights;

  /// 列表里直接播放视频（设置开关）。只对「单条视频」生效。
  final bool autoPlayVideo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final author = item.author;
    final deleted = item.state == LikeState.deleted;

    return Material(
      color: selected
          ? theme.colorScheme.primaryContainer.withValues(alpha: 0.35)
          : theme.colorScheme.surface,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GestureDetector(
                onTap: onAvatarTap,
                child: _avatar(author, theme),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _header(context, theme, author, deleted),
                    if (deleted) ...[
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(
                            Icons.info_outline,
                            size: 13,
                            color: theme.colorScheme.outline,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            t('play.deleted'),
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.outline,
                            ),
                          ),
                        ],
                      ),
                    ],
                    if (item.text.trim().isNotEmpty) ...[
                      const SizedBox(height: 4),
                      TranslatableBody(
                        item: item,
                        highlights: highlights,
                        maxLines: 6,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          height: 1.35,
                        ),
                      ),
                    ],
                    if (item.media.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      _MediaGrid(
                        item: item,
                        cache: cache,
                        onOpen: onTap,
                        autoPlay: autoPlayVideo,
                      ),
                    ],
                    if (item.media.isEmpty) const SizedBox(height: 2),
                    _metricsRow(context, item),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 互动数据行。数字来自最近一次同步带回来的 `raw_json`（见 [MetricsStore]），
  /// 所以离线也有、也不发请求。
  ///
  /// 设置里关掉就整行不出现。
  Widget _metricsRow(BuildContext context, LikeItem item) {
    // 没有 AppScope（单独预览/组件测试）就整行不显示。
    final app = AppScope.maybeRead(context);
    if (app == null) return const SizedBox.shrink();
    if (!app.settings.showMetrics) return const SizedBox.shrink();

    final m = app.metrics.of(item);
    if (m == null || m.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final color = theme.colorScheme.outline;
    final style = theme.textTheme.labelSmall?.copyWith(color: color);

    Widget chip(IconData icon, int? value, {VoidCallback? onTap}) {
      if (value == null) return const SizedBox.shrink();
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.only(right: 16, top: 2, bottom: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 13, color: color),
              const SizedBox(width: 3),
              Text(_fmtCount(value), style: style),
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          // 点回复数直接看 X 自己的回复列表（折叠/排序都是原生行为）。
          chip(
            Icons.mode_comment_outlined,
            m.replies,
            onTap: () {
              unawaited(
                openXPage(
                  context,
                  XWebPage(
                    url: 'https://x.com/i/status/${item.tweetId}',
                    title: t('post.replies'),
                  ),
                ),
              );
            },
          ),
          chip(Icons.repeat, m.retweets),
          chip(Icons.favorite_border, m.likes),
          chip(Icons.bar_chart, m.heat),
        ],
      ),
    );
  }

  Widget _avatar(Author? author, ThemeData theme) {
    final url = author?.avatarUrl;
    if (url == null) {
      return CircleAvatar(
        radius: 21,
        backgroundColor: theme.colorScheme.surfaceContainerHighest,
        child: const Icon(Icons.person, size: 22),
      );
    }
    return AuthorAvatar(url: url, radius: 21);
  }

  Widget _header(
    BuildContext context,
    ThemeData theme,
    Author? author,
    bool deleted,
  ) {
    final small = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.outline,
    );
    return Row(
      children: [
        Flexible(
          child: Text(
            // 主要显示「展示名」：没有展示名时退回 @handle，别给用户看 "unknown"。
            (author?.name.isNotEmpty == true)
                ? author!.name
                : (author?.screenName.isNotEmpty == true
                      ? author!.screenName
                      : 'unknown'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            '@${author?.screenName ?? ''}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: small,
          ),
        ),
        if (item.createdAt != null) ...[
          Text(' · ', style: small),
          Text(_ago(item.createdAt!), style: small),
        ],
      ],
    );
  }
}

/// 1/2/3/4 张图片的分形网格 + 视频封面。
class _MediaGrid extends StatelessWidget {
  const _MediaGrid({
    required this.item,
    required this.onOpen,
    this.cache,
    this.autoPlay = false,
  });

  final LikeItem item;
  final VoidCallback onOpen;
  final MediaCache? cache;

  /// 单条视频是否直接播放（设置里的「列表里自动播放视频」）。
  final bool autoPlay;

  @override
  Widget build(BuildContext context) {
    final media = item.media;
    if (media.length == 1) {
      return _tile(context, media.first, 0, maxHeight: 320, single: true);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        const gap = 4.0;
        if (media.length == 2) {
          return SizedBox(
            height: w * 0.5,
            child: Row(
              children: [
                for (var i = 0; i < 2; i++) ...[
                  if (i > 0) const SizedBox(width: gap),
                  Expanded(child: _tile(context, media[i], i)),
                ],
              ],
            ),
          );
        }
        if (media.length == 3) {
          final h = w * 0.62;
          return SizedBox(
            height: h,
            child: Row(
              children: [
                Expanded(flex: 2, child: _tile(context, media[0], 0)),
                const SizedBox(width: gap),
                Expanded(
                  child: Column(
                    children: [
                      Expanded(child: _tile(context, media[1], 1)),
                      const SizedBox(height: gap),
                      Expanded(child: _tile(context, media[2], 2)),
                    ],
                  ),
                ),
              ],
            ),
          );
        }
        // 4 张及以上：2×2，多余的在最后一张上叠 +N。
        return SizedBox(
          height: w * 0.82,
          child: Column(
            children: [
              for (var row = 0; row < 2; row++) ...[
                if (row > 0) const SizedBox(height: gap),
                Expanded(
                  child: Row(
                    children: [
                      for (var col = 0; col < 2; col++) ...[
                        if (col > 0) const SizedBox(width: gap),
                        Expanded(
                          child: _wrapOverflow(
                            context,
                            child: _tile(
                              context,
                              media[row * 2 + col],
                              row * 2 + col,
                            ),
                            remaining: row * 2 + col == 3
                                ? media.length - 4
                                : 0,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _wrapOverflow(
    BuildContext context, {
    required Widget child,
    required int remaining,
  }) {
    if (remaining <= 0) return child;
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        ColoredBox(
          color: Colors.black.withValues(alpha: 0.55),
          child: Center(
            child: Text(
              '+$remaining',
              style: const TextStyle(color: Colors.white, fontSize: 22),
            ),
          ),
        ),
      ],
    );
  }

  Widget _tile(
    BuildContext context,
    MediaItem m,
    int idx, {
    double? maxHeight,
    bool single = false,
  }) {
    final theme = Theme.of(context);
    final isVideo = m.isPlayable;
    Widget img = MediaImage(
      // 视频封面也必须降尺寸：库里存的视频 url 是 `?name=large`（解析时加的），
      // 直接用它等于在列表里下载**最大尺寸**缩略图 —— 慢到经常出不来。
      // `withImageVariant` 会把已有的 name 换成 small。
      url: withImageVariant(m.url, 'small'),
      // 视频封面不需要"小图→大图"两段：它就是一张封面，清晰了也没用。
      highResUrl: isVideo ? null : withImageVariant(m.url, 'large'),
      cache: cache,
      tweetId: item.tweetId,
      idx: idx,
      fit: BoxFit.cover,
      cacheWidth: 720,
      // 这张图的大图**以前已经加载过**就用大图起播：省掉「先糊一下」，
      // 而且只需一次请求（以前每次都是小图+大图两次）。
      preferRemembered: true,
    );

    Widget content = ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: Stack(
        fit: StackFit.expand,
        children: [
          img,
          if (isVideo)
            Center(
              child: Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.play_arrow_rounded,
                  color: Colors.white,
                  size: 30,
                ),
              ),
            ),
          if (m.kind == MediaKind.gif)
            Positioned(
              left: 6,
              bottom: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text(
                  'GIF',
                  style: TextStyle(color: Colors.white, fontSize: 10),
                ),
              ),
            ),
          if (isVideo && m.durationMs != null)
            Positioned(
              right: 6,
              bottom: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  _fmtDuration(m.durationMs!),
                  style: const TextStyle(color: Colors.white, fontSize: 10),
                ),
              ),
            ),
        ],
      ),
    );

    if (single) {
      final ratio = (m.width != null && m.height != null && m.width! > 0)
          ? m.width! / m.height!
          : 16 / 9;
      final clamped = ratio.clamp(0.62, 1.9);

      // 设为「列表里自动播放」并且这是一条视频：直接用播放器铺满这块区域。
      //
      // 静音 + 循环 + 不升清晰（列表里不值得为预览多占一份带宽），
      // 缓存与全屏播放共用 —— 已经缓存过的直接读本地文件（也就等于最高档）。
      if (autoPlay && m.isPlayable) {
        final opts = VideoQualityOptions.of(m);
        return ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight ?? 320),
          child: AspectRatio(
            aspectRatio: clamped,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: VideoSurface(
                options: opts,
                posterUrl: m.url,
                tier: QualityTier.auto,
                autoUpgrade: false,
                loop: true,
                active: true,
                muted: true,
                cache: cache,
                tweetId: item.tweetId,
                idx: idx,
                fit: BoxFit.cover,
              ),
            ),
          ),
        );
      }

      return ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight ?? 320),
        child: AspectRatio(aspectRatio: clamped, child: content),
      );
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.colorScheme.outlineVariant, width: 0.5),
      ),
      child: content,
    );
  }
}

/// 正文渲染统一走 [PostBody]（见 rich_text.dart）：话题、提及、外链都要能点，
/// 而且列表和播放页必须用同一套规则。
String _fmtDuration(int ms) {
  final d = Duration(milliseconds: ms);
  final m = d.inMinutes;
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$m:$s';
}

/// 大数字压缩成 1.2K / 3.4M，省得一行挤满。
String _fmtCount(int v) {
  if (v < 1000) return '$v';
  if (v < 1000000) {
    final k = v / 1000;
    return '${k < 10 ? k.toStringAsFixed(1) : k.round()}K';
  }
  final m = v / 1000000;
  return '${m < 10 ? m.toStringAsFixed(1) : m.round()}M';
}

/// X 风格相对时间。
///
/// 单位按当前界面语言出：中文是「3秒 / 5分钟 / 2小时 / 1天」，英文还是紧凑的
/// `3s / 5m / 2h / 1d`。以前中文界面也写 `1d`，读起来像型号而不是时间。
String _ago(DateTime time) {
  final local = time.toLocal();
  final diff = DateTime.now().difference(local);
  if (diff.inSeconds < 60) {
    return tf('time.seconds', {'n': diff.inSeconds.clamp(0, 59)});
  }
  if (diff.inMinutes < 60) return tf('time.minutes', {'n': diff.inMinutes});
  if (diff.inHours < 24) return tf('time.hours', {'n': diff.inHours});
  if (diff.inDays < 7) return tf('time.days', {'n': diff.inDays});
  if (local.year == DateTime.now().year) {
    return '${local.month}/${local.day}';
  }
  return '${local.year}/${local.month}/${local.day}';
}

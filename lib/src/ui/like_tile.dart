/// 网格里的一张卡片。
///
/// 性能上做了两件小事，都是「一屏几十张」时才看得出来：
/// 1. 悬停用 [ValueNotifier] 驱动，只有浮层重建，卡片本体（图片）不重建；
/// 2. 图片走 [MediaImage]：本地缓存的直接用文件，否则请求 CDN 的 `name=small`
///    档位并按格子宽度解码。以前是 `name=large` 全尺寸直出。
library;

import 'package:flutter/material.dart';

import '../media/media_cache.dart';
import '../model/like_item.dart';
import 'media_image.dart';

class LikeTile extends StatefulWidget {
  const LikeTile({
    super.key,
    required this.item,
    required this.selected,
    required this.onTap,
    this.cache,
  });

  final LikeItem item;
  final bool selected;
  final VoidCallback onTap;

  /// 有缓存时优先用本地文件（离线保存过的条目）。
  final MediaCache? cache;

  @override
  State<LikeTile> createState() => _LikeTileState();
}

class _LikeTileState extends State<LikeTile> {
  final ValueNotifier<bool> _hover = ValueNotifier<bool>(false);

  @override
  void dispose() {
    _hover.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final theme = Theme.of(context);
    final thumb = item.thumbnailUrl;

    return MouseRegion(
      onEnter: (_) => _hover.value = true,
      onExit: (_) => _hover.value = false,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: widget.selected
                  ? theme.colorScheme.primary
                  : Colors.transparent,
              width: 2,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            fit: StackFit.expand,
            children: [
              _background(context, item, thumb),
              if (item.hasVideo)
                const _Badge(icon: Icons.play_circle_fill),
              if (item.hasGif)
                const _Badge(
                  icon: Icons.gif_box,
                  label: 'GIF',
                  alignment: Alignment.topLeft,
                ),
              if (item.state == LikeState.deleted)
                Align(
                  alignment: Alignment.topRight,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Container(
                      padding: const EdgeInsets.all(3),
                      decoration: const BoxDecoration(
                        color: Colors.black54,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.delete_outline,
                          size: 14, color: Colors.white),
                    ),
                  ),
                ),
              // 浮层只在悬停时进树：不悬停时连 widget 都不建（一屏几十张卡片
              // 少掉几十个 Text），鼠标移上去的代价可以忽略。
              IgnorePointer(
                child: ValueListenableBuilder<bool>(
                  valueListenable: _hover,
                  builder: (context, hover, _) => hover
                      ? _HoverInfo(item: item)
                      : const SizedBox.shrink(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _background(BuildContext context, LikeItem item, String? thumb) {
    if (thumb == null) {
      return Container(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        padding: const EdgeInsets.all(12),
        alignment: Alignment.topLeft,
        child: Text(
          item.text,
          maxLines: 6,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      );
    }
    final deleted = item.state == LikeState.deleted;
    return Stack(
      fit: StackFit.expand,
      children: [
        MediaImage(
          url: thumb,
          cache: widget.cache,
          tweetId: item.tweetId,
          cacheWidth: 480,
        ),
        if (deleted) ColoredBox(color: Colors.black.withValues(alpha: 0.45)),
      ],
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({
    required this.icon,
    this.label = '',
    this.alignment = Alignment.bottomLeft,
  });
  final IconData icon;
  final String label;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: alignment,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: Colors.white),
              if (label.isNotEmpty) ...[
                const SizedBox(width: 4),
                Text(label,
                    style: const TextStyle(color: Colors.white, fontSize: 11)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _HoverInfo extends StatelessWidget {
  const _HoverInfo({required this.item});
  final LikeItem item;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black.withValues(alpha: 0.85)],
        ),
      ),
      padding: const EdgeInsets.all(8),
      alignment: Alignment.bottomLeft,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '@${item.author?.screenName ?? 'unknown'} · ${_date(item.createdAt)}',
            style: const TextStyle(color: Colors.white70, fontSize: 11),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            item.text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ],
      ),
    );
  }

  String _date(DateTime? d) {
    if (d == null) return '';
    final local = d.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
  }
}

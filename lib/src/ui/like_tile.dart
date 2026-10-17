/// 网格里的一张卡片。
library;

import 'package:flutter/material.dart';

import '../../model/like_item.dart';

class LikeTile extends StatefulWidget {
  const LikeTile({
    super.key,
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final LikeItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<LikeTile> createState() => _LikeTileState();
}

class _LikeTileState extends State<LikeTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final theme = Theme.of(context);
    final thumb = item.thumbnailUrl;
    final deleted = item.state == LikeState.deleted;

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
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
              _background(context, thumb, deleted),
              if (item.hasVideo)
                const _Badge(icon: Icons.play_circle_fill, label: ''),
              if (item.hasGif)
                const Positioned(
                  left: 8,
                  top: 8,
                  child: _Badge(icon: Icons.gif_box, label: 'GIF'),
                ),
              if (deleted)
                Positioned(
                  right: 8,
                  top: 8,
                  child: _Badge(icon: Icons.delete_outline, label: ''),
                ),
              // 悬停时浮出信息（桌面）
              if (_hover)
                Positioned.fill(
                  child: _HoverInfo(item: item),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _background(BuildContext context, String? thumb, bool deleted) {
    if (thumb == null) {
      return Container(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        padding: const EdgeInsets.all(12),
        alignment: Alignment.topLeft,
        child: Text(
          widget.item.text,
          maxLines: 6,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.network(
          thumb,
          fit: BoxFit.cover,
          cacheWidth: 480,
          errorBuilder: (_, __, ___) => Container(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: const Center(child: Icon(Icons.broken_image_outlined)),
          ),
          loadingBuilder: (context, child, progress) {
            if (progress == null) return child;
            return Container(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
            );
          },
        ),
        if (deleted)
          ColoredBox(color: Colors.black.withValues(alpha: 0.45)),
      ],
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 8,
      bottom: 8,
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

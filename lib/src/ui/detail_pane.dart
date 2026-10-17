/// 详情/播放面板：桌面右栏与移动端全屏共用。
library;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_controller.dart';
import '../core/l10n.dart';
import '../model/like_item.dart';
import 'video_view.dart';

class DetailPane extends StatefulWidget {
  const DetailPane({super.key, required this.item, this.onClose});

  final LikeItem item;
  final VoidCallback? onClose;

  @override
  State<DetailPane> createState() => _DetailPaneState();
}

class _DetailPaneState extends State<DetailPane> {
  int _page = 0;

  @override
  void didUpdateWidget(covariant DetailPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.tweetId != widget.item.tweetId) _page = 0;
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final theme = Theme.of(context);
    final app = AppScope.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 48,
          child: Row(
            children: [
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  item.author?.name ?? '',
                  style: theme.textTheme.titleSmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (widget.onClose != null)
                IconButton(
                  onPressed: widget.onClose,
                  icon: const Icon(Icons.close),
                ),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _media(context, item),
                if (item.state == LikeState.deleted)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        const Icon(Icons.info_outline, size: 18),
                        const SizedBox(width: 8),
                        Expanded(child: Text(t('detail.deleted'))),
                      ],
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          if (item.author?.avatarUrl != null)
                            CircleAvatar(
                              radius: 14,
                              backgroundImage:
                                  NetworkImage(item.author!.avatarUrl!),
                            ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '@${item.author?.screenName ?? ''} · ${_date(item.createdAt)}',
                              style: theme.textTheme.bodySmall,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      SelectableText(
                        item.text,
                        style: theme.textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 8,
                        children: [
                          OutlinedButton.icon(
                            onPressed: () => _confirmUnlike(context, app, item),
                            icon: const Icon(Icons.favorite_border, size: 18),
                            label: Text(t('detail.unlike')),
                          ),
                          TextButton.icon(
                            onPressed: () => launchUrl(
                              Uri.parse(
                                  'https://x.com/i/status/${item.tweetId}'),
                              mode: LaunchMode.externalApplication,
                            ),
                            icon: const Icon(Icons.open_in_new, size: 18),
                            label: Text(t('detail.openInBrowser')),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _media(BuildContext context, LikeItem item) {
    if (item.media.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Text(t('detail.noMedia')),
      );
    }
    if (item.media.length == 1) return _single(item.media.first);

    return Column(
      children: [
        AspectRatio(
          aspectRatio: 1,
          child: PageView.builder(
            itemCount: item.media.length,
            onPageChanged: (i) => setState(() => _page = i),
            itemBuilder: (_, i) => _single(item.media[i]),
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < item.media.length; i++)
              Padding(
                padding: const EdgeInsets.all(4),
                child: CircleAvatar(
                  radius: 3,
                  backgroundColor: i == _page
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _single(MediaItem m) {
    if (m.isPlayable) {
      final url = m.bestPlaybackUrl!;
      return XVideoView(url: url, posterUrl: m.url);
    }
    return InteractiveViewer(
      maxScale: 4,
      child: Image.network(
        m.url.replaceAll('name=large', 'name=orig'),
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => const Center(
          child: Icon(Icons.broken_image_outlined),
        ),
      ),
    );
  }

  String _date(DateTime? d) {
    if (d == null) return '';
    final local = d.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _confirmUnlike(
      BuildContext context, AppController app, LikeItem item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(t('detail.unlikeConfirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t('action.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t('action.confirm')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final err = await app.unlike(item.tweetId);
    if (err != null && context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(err)));
    }
  }
}

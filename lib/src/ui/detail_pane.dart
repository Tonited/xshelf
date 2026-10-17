/// 详情/播放面板：桌面右栏与移动端全屏共用。
library;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_controller.dart';
import '../core/l10n.dart';
import '../model/like_item.dart';
import 'media_image.dart';
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
  bool _saving = false;
  bool _unliking = false;

  /// 用 read：详情栏不需要跟着外壳状态重建，动作直接调 controller 的方法。
  AppController get _app => AppScope.read(context);

  Future<void> _saveOffline(LikeItem item) async {
    setState(() => _saving = true);
    final err = await _app.saveOffline(item);
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(err ?? t('detail.saved'))),
    );
  }

  @override
  void didUpdateWidget(covariant DetailPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.tweetId != widget.item.tweetId) _page = 0;
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final theme = Theme.of(context);
    final app = _app;

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
                _media(context, item, app),
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
                            AuthorAvatar(
                                url: item.author!.avatarUrl!, radius: 14),
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
                            onPressed: _unliking
                                ? null
                                : () => _confirmUnlike(app, item),
                            icon: _unliking
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child:
                                        CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : const Icon(Icons.favorite_border, size: 18),
                            label: Text(t('detail.unlike')),
                          ),
                          if (item.media.isNotEmpty)
                            OutlinedButton.icon(
                              onPressed:
                                  _saving ? null : () => _saveOffline(item),
                              icon: _saving
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2),
                                    )
                                  : const Icon(Icons.download, size: 18),
                              label: Text(
                                  _saving ? t('detail.saving') : t('detail.save')),
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

  Widget _media(BuildContext context, LikeItem item, AppController app) {
    if (item.media.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Text(t('detail.noMedia')),
      );
    }
    if (item.media.length == 1) {
      return _single(item, item.media.first, app);
    }

    return Column(
      children: [
        AspectRatio(
          aspectRatio: 1,
          child: PageView.builder(
            itemCount: item.media.length,
            onPageChanged: (i) {
              if (i != _page) setState(() => _page = i);
            },
            itemBuilder: (_, i) => _single(item, item.media[i], app),
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

  Widget _single(LikeItem item, MediaItem m, AppController app) {
    final idx = item.media.indexOf(m);
    if (m.isPlayable) {
      // key 里带上地址：DetailPane 是常驻的，换一条选中项时如果沿用同一个
      // State，播放器会继续播上一条视频（画面和内容对不上）。
      return XVideoView(
        key: ValueKey('video:${m.bestPlaybackUrl}'),
        url: m.bestPlaybackUrl!,
        posterUrl: m.url,
      );
    }
    return InteractiveViewer(
      maxScale: 4,
      child: MediaImage(
        key: ValueKey('image:${m.url}'),
        url: withImageVariant(m.url, 'large'),
        cache: app.mediaCache,
        tweetId: item.tweetId,
        idx: idx < 0 ? 0 : idx,
        fit: BoxFit.contain,
        cacheWidth: 1200,
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

  Future<void> _confirmUnlike(AppController app, LikeItem item) async {
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
    setState(() => _unliking = true);
    final err = await app.unlike(item.tweetId);
    if (!mounted) return;
    setState(() => _unliking = false);
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
      return;
    }
    // 已经不在列表里了（手机端的独立路由）：关掉面板，别留一条幽灵内容。
    if (app.browse.items.every((i) => i.tweetId != item.tweetId)) {
      widget.onClose?.call();
    }
  }
}

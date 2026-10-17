/// 视频播放：桌面用 media_kit(libmpv)，移动端用 video_player(ExoPlayer)。
///
/// 两端接口不同但语义相同：给一个 URL 就能播、能控制、能全屏。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:video_player/video_player.dart' as vp;

class XVideoView extends StatefulWidget {
  const XVideoView({
    super.key,
    required this.url,
    this.posterUrl,
    this.loop = false,
    this.autoPlay = true,
  });

  final String url;
  final String? posterUrl;
  final bool loop;
  final bool autoPlay;

  @override
  State<XVideoView> createState() => _XVideoViewState();
}

class _XVideoViewState extends State<XVideoView> {
  // 桌面
  Player? _player;
  VideoController? _controller;

  // 移动端
  vp.VideoPlayerController? _mobile;

  String? _error;
  bool _ready = false;

  bool get _isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  @override
  void initState() {
    super.initState();
    _init();
  }

  /// 同一个 State 被复用到另一个视频时必须重新开流（详情栏是常驻的，
  /// 只换 `item` 不换 widget 位置）。以前没有这一步，会出现「选了 B 却还在播 A」。
  @override
  void didUpdateWidget(covariant XVideoView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _teardown();
      _error = null;
      _ready = false;
      _init();
    }
  }

  void _teardown() {
    _player?.dispose();
    _player = null;
    _controller = null;
    _mobile?.dispose();
    _mobile = null;
  }

  void _init() {
    if (_isDesktop) {
      _initDesktop();
    } else {
      _initMobile();
    }
  }

  Future<void> _initDesktop() async {
    try {
      final player = Player();
      _player = player;
      final controller = VideoController(player);
      _controller = controller;
      await player.setPlaylistMode(
          widget.loop ? PlaylistMode.single : PlaylistMode.none);
      if (!mounted) return;
      setState(() => _ready = true);
      await player.open(Media(widget.url), play: widget.autoPlay);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _initMobile() async {
    try {
      final controller =
          vp.VideoPlayerController.networkUrl(Uri.parse(widget.url));
      _mobile = controller;
      await controller.setLooping(widget.loop);
      await controller.initialize();
      if (!mounted) return;
      setState(() => _ready = true);
      if (widget.autoPlay) await controller.play();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    _teardown();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return _placeholder(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.videocam_off_outlined, color: Colors.white70),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                _error!,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      );
    }

    if (_isDesktop) {
      final c = _controller;
      if (c == null || !_ready) return _placeholder(const CircularProgressIndicator());
      return AspectRatio(
        aspectRatio: 16 / 9,
        child: Video(
          controller: c,
          controls: MaterialVideoControls,
          fit: BoxFit.contain,
        ),
      );
    }

    final m = _mobile;
    if (m == null || !m.value.isInitialized) {
      return _placeholder(const CircularProgressIndicator());
    }
    return AspectRatio(
      aspectRatio: m.value.aspectRatio == 0 ? 16 / 9 : m.value.aspectRatio,
      child: Stack(
        alignment: Alignment.bottomCenter,
        children: [
          vp.VideoPlayer(m),
          MobileControls(
            controller: m,
            onFullscreen: () => _openFullscreen(m),
          ),
        ],
      ),
    );
  }

  /// 全屏：同一个 controller 换个全屏页面播放，返回时继续播。
  Future<void> _openFullscreen(vp.VideoPlayerController m) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Center(
            child: AspectRatio(
              aspectRatio:
                  m.value.aspectRatio == 0 ? 16 / 9 : m.value.aspectRatio,
              child: Stack(
                alignment: Alignment.bottomCenter,
                children: [
                  vp.VideoPlayer(m),
                  MobileControls(controller: m),
                ],
              ),
            ),
          ),
        ),
      ),
    ));
  }

  /// 黑底 + 封面图 + 转圈：缓冲时至少让用户知道点开的是哪条。
  Widget _placeholder(Widget child) => AspectRatio(
        aspectRatio: 16 / 9,
        child: ColoredBox(
          color: Colors.black,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (widget.posterUrl != null)
                Opacity(
                  opacity: 0.35,
                  child: Image.network(
                    widget.posterUrl!,
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
                ),
              Center(child: child),
            ],
          ),
        ),
      );
}

/// 移动端控制条：播放/暂停、进度、倍速、全屏。
class MobileControls extends StatefulWidget {
  const MobileControls({
    super.key,
    required this.controller,
    this.onFullscreen,
  });

  final vp.VideoPlayerController controller;
  final VoidCallback? onFullscreen;

  @override
  State<MobileControls> createState() => _MobileControlsState();
}

class _MobileControlsState extends State<MobileControls> {
  bool _dragging = false;
  double _dragValue = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTick);
  }

  @override
  void didUpdateWidget(covariant MobileControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onTick);
      widget.controller.addListener(_onTick);
    }
  }

  void _onTick() {
    // 拖动进度条时不要被播放进度覆盖。
    if (mounted && !_dragging) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTick);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.controller.value;
    final total = v.duration.inMilliseconds;
    final pos = _dragging ? (_dragValue * total).round() : v.position.inMilliseconds;
    final value = total == 0 ? 0.0 : (pos / total).clamp(0.0, 1.0);

    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black54],
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          IconButton(
            color: Colors.white,
            icon: Icon(v.isPlaying ? Icons.pause : Icons.play_arrow),
            onPressed: () =>
                v.isPlaying ? widget.controller.pause() : widget.controller.play(),
          ),
          Expanded(
            child: Slider(
              value: value,
              onChangeStart: (x) => setState(() {
                _dragging = true;
                _dragValue = x;
              }),
              onChanged: (x) => setState(() => _dragValue = x),
              onChangeEnd: (x) async {
                await widget.controller
                    .seekTo(Duration(milliseconds: (x * total).round()));
                if (mounted) setState(() => _dragging = false);
              },
            ),
          ),
          Text(
            '${_fmt(Duration(milliseconds: pos))} / ${_fmt(v.duration)}',
            style: const TextStyle(color: Colors.white, fontSize: 11),
          ),
          PopupMenuButton<double>(
            color: Colors.black87,
            tooltip: 'speed',
            icon: Text(
              '${v.playbackSpeed}x',
              style: const TextStyle(color: Colors.white, fontSize: 11),
            ),
            onSelected: (s) => widget.controller.setPlaybackSpeed(s),
            itemBuilder: (_) => [
              for (final s in const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0])
                PopupMenuItem(
                  value: s,
                  child: Text('${s}x',
                      style: const TextStyle(color: Colors.white)),
                ),
            ],
          ),
          if (widget.onFullscreen != null)
            IconButton(
              color: Colors.white,
              icon: const Icon(Icons.fullscreen),
              onPressed: widget.onFullscreen,
            ),
        ],
      ),
    );
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}

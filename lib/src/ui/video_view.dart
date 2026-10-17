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

  bool get _isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  @override
  void initState() {
    super.initState();
    if (_isDesktop) {
      _initDesktop();
    } else {
      _initMobile();
    }
  }

  Future<void> _initDesktop() async {
    final player = Player();
    _player = player;
    _controller = VideoController(player);
    await player.setPlaylistMode(
        widget.loop ? PlaylistMode.single : PlaylistMode.none);
    await player.open(Media(widget.url), play: widget.autoPlay);
    if (mounted) setState(() {});
  }

  Future<void> _initMobile() async {
    final controller = vp.VideoPlayerController.networkUrl(Uri.parse(widget.url));
    _mobile = controller;
    controller.setLooping(widget.loop);
    await controller.initialize();
    if (widget.autoPlay) await controller.play();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _player?.dispose();
    _mobile?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isDesktop) {
      final c = _controller;
      if (c == null) {
        return _placeholder(const CircularProgressIndicator());
      }
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
          _MobileControls(controller: m),
        ],
      ),
    );
  }

  Widget _placeholder(Widget child) => AspectRatio(
        aspectRatio: 16 / 9,
        child: ColoredBox(
          color: Colors.black,
          child: Center(child: child),
        ),
      );
}

/// 移动端的最小控制条：播放/暂停 + 进度。
class _MobileControls extends StatefulWidget {
  const _MobileControls({required this.controller});
  final vp.VideoPlayerController controller;

  @override
  State<_MobileControls> createState() => _MobileControlsState();
}

class _MobileControlsState extends State<_MobileControls> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTick);
  }

  void _onTick() {
    if (mounted) setState(() {});
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
    final pos = v.position.inMilliseconds;
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black54],
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8),
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
              value: total == 0 ? 0 : (pos / total).clamp(0.0, 1.0),
              onChanged: (value) => widget.controller
                  .seekTo(Duration(milliseconds: (value * total).round())),
            ),
          ),
          Text(
            '${_fmt(v.position)} / ${_fmt(v.duration)}',
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ],
      ),
    );
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

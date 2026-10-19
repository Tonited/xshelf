/// 短视频播放器：一条视频 + 画质阶梯 + 平滑升清晰。
///
/// 移动端用 `video_player`（ExoPlayer），桌面端（开发机验证用）用 media_kit。
///
/// ## 画质模型（这一版的重点）
/// 一条视频的画质按 `PlaybackSource.key` 走（高度+码率），而不是抽象的三档。
///
/// - **自动**：起播要快，之后**由网络决定能爬到哪一档**。播放中每 900ms 采样
///   一次缓冲余量：余量 ≥5s 才算「这档撑得住」；连续三次在转圈或者余量见底，
///   说明这一档这台网络撑不住，退回一档并把它记成「天花板」，不再来回跳。
/// - **手动**：用户点的档位是**上限**（不是「锁死」）。立刻切过去；网络撑不住时
///   临时降档，余量恢复后再自动爬回所选的那一档 —— 但永远不会超过它。
/// - **一次到位**：无论自动还是手动，切档都是**直接从当前档跳到最终档**，
///   不再一档一档过渡 —— 中间档只是多一次解码器重建，用户并没有多看到什么。
///   本地缓存里已经有更高档的文件时，直接用那个文件（零网络）。
///
/// 两个跨会话的记忆（都落在 `MediaCache` → SQLite `media` 表）：
/// - `best_variant`：这条媒体**真正播过**的最高画质。下次打开直接用它起播 ——
///   用户抱怨的「明明升过画质，再点进来还是先糊一下」就是缺这个。
/// - `cache_variant`：本地缓存文件到底是哪一档。以前缓存一律按「最佳档」下载，
///   但播放时又**无条件**优先读本地文件，于是「切到低画质」看起来毫无变化，
///   画质标签也在说谎。现在只有「请求的档 == 文件那档」才读文件。
///
/// ## 为什么升画质会卡（以及怎么做到丝滑）
/// 换档要另开一个解码器（`video_player` 没有 track 切换 API），而旧的做法是
/// 起播 1.2 秒后**无条件**切：那时旧实例还在缓冲、后台缓存下载还在抢带宽，
/// 新实例再开一路网络流，三份流量互相挤 —— 表现就是画面顿一下、声音抖一下。
///
/// 现在换档有四个前提，缺一个就先不换（稍后重试）：
/// 1. 目标档已经有本地文件（零网络，任何时候都能换）；
/// 2. 或者当前已经缓冲了 ≥3 秒的余量（换了不会立刻缺数据）；
/// 3. 已经播了 ≥1 秒（解码器热起来了，别在起播那一秒抢 CPU）；
/// 4. 剩余时长 ≥4 秒（快播完了不值得折腾）。
///
/// 交接也从「硬切」改成**交叉淡化**：新实例静音、定位到同一进度、先自己播起来，
/// 等两边位置对齐（±200ms）后，旧档留在下面继续出画面、新档在上面 200ms 淡入，
/// 淡完再释放旧解码器。换纹理那一帧的空画面被旧画面盖住，所以看不到黑屏或跳动。
///
/// ## 手势不在这里
/// 长按倍速、左右双击快退快进要覆盖整块屏幕（含视频黑边），放在播放页更合适。
/// 播放器只通过 [PlaybackHandle] 把「能做的动作」暴露出去。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:video_player/video_player.dart' as vp;

import '../core/l10n.dart';
import '../media/media_cache.dart';
import '../media/quality.dart';

/// 播放器对外的控制面：播放页的手势/进度条只认这个，不碰具体实现。
class PlaybackHandle extends ChangeNotifier {
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;
  bool _buffering = false;
  bool _ready = false;
  double _speed = 1.0;
  String? _qualityLabel;
  String? _qualityKey;

  Duration get position => _position;
  Duration get duration => _duration;
  bool get playing => _playing;
  bool get buffering => _buffering;
  bool get ready => _ready;
  double get speed => _speed;

  /// 当前**实际**在播的档位标签（`720p`），未播放时为 null。
  String? get qualityLabel => _qualityLabel;

  /// 当前实际档位的 [PlaybackSource.key]，给界面判断「已是最佳」用。
  String? get qualityKey => _qualityKey;

  /// 当前档位算不算「高清」（>=720p 或 >=1.5Mbps）。
  bool get qualityHd => _qualityHd;
  bool _qualityHd = false;

  /// 换档进行中（已经开了新解码器，正等它对齐）。界面可以给一个小提示。
  bool _switching = false;
  String? _switchingLabel;
  bool get switching => _switching;
  String? get switchingLabel => _switchingLabel;

  double get progress {
    final total = _duration.inMilliseconds;
    if (total <= 0) return 0;
    return (_position.inMilliseconds / total).clamp(0.0, 1.0);
  }

  Future<void> Function(Duration delta)? _seekBy;
  Future<void> Function(Duration absolute)? _seekTo;
  Future<void> Function(double speed)? _setSpeed;
  VoidCallback? _togglePlay;
  VoidCallback? _pauseExternal;
  VoidCallback? _resumeExternal;
  void Function(QualityTier tier)? _pickQuality;
  bool _hasSource = false;
  bool _hasQualitySwitch = false;

  bool get attached => _hasSource;

  /// 这条视频是否有多个码率可切（单变体视频不该出现画质菜单）。
  bool get canSwitchQuality => _hasQualitySwitch;

  void attach({
    required Future<void> Function(Duration delta) seekBy,
    required Future<void> Function(Duration absolute) seekTo,
    required Future<void> Function(double speed) setSpeed,
    required VoidCallback togglePlay,
    required void Function(QualityTier tier) pickQuality,
    required bool canSwitchQuality,
    VoidCallback? pause,
    VoidCallback? resume,
  }) {
    _seekBy = seekBy;
    _seekTo = seekTo;
    _setSpeed = setSpeed;
    _togglePlay = togglePlay;
    _pickQuality = pickQuality;
    _pauseExternal = pause;
    _resumeExternal = resume;
    _hasSource = true;
    _hasQualitySwitch = canSwitchQuality;
  }

  void detach() {
    _seekBy = null;
    _seekTo = null;
    _setSpeed = null;
    _togglePlay = null;
    _pauseExternal = null;
    _resumeExternal = null;
    _pickQuality = null;
    _hasSource = false;
    _hasQualitySwitch = false;
    _ready = false;
    _playing = false;
    _buffering = false;
    _position = Duration.zero;
    _duration = Duration.zero;
    _qualityLabel = null;
    _qualityKey = null;
    _switching = false;
    _switchingLabel = null;
    notifyListeners();
  }

  void _push({
    Duration? position,
    Duration? duration,
    bool? playing,
    bool? buffering,
    bool? ready,
    double? speed,
    String? qualityLabel,
    String? qualityKey,
    bool? qualityHd,
    bool clearQuality = false,
  }) {
    var changed = false;
    if (position != null && position != _position) {
      _position = position;
      changed = true;
    }
    if (duration != null && duration != _duration) {
      _duration = duration;
      changed = true;
    }
    if (playing != null && playing != _playing) {
      _playing = playing;
      changed = true;
    }
    if (buffering != null && buffering != _buffering) {
      _buffering = buffering;
      changed = true;
    }
    if (ready != null && ready != _ready) {
      _ready = ready;
      changed = true;
    }
    if (speed != null && speed != _speed) {
      _speed = speed;
      changed = true;
    }
    if (clearQuality) {
      if (_qualityLabel != null || _qualityKey != null) {
        _qualityLabel = null;
        _qualityKey = null;
        _qualityHd = false;
        changed = true;
      }
    } else {
      if (qualityLabel != null && qualityLabel != _qualityLabel) {
        _qualityLabel = qualityLabel;
        changed = true;
      }
      if (qualityKey != null && qualityKey != _qualityKey) {
        _qualityKey = qualityKey;
        changed = true;
      }
      if (qualityHd != null && qualityHd != _qualityHd) {
        _qualityHd = qualityHd;
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  /// 换档状态单独走一条通道：它不属于「播放器数值」，普通的状态上报
  /// （每帧都会来的 position）不该顺手把它清掉。
  void _setSwitching(bool value, [String? label]) {
    if (_switching == value && _switchingLabel == label) return;
    _switching = value;
    _switchingLabel = value ? label : null;
    notifyListeners();
  }

  Future<void> seekBy(Duration delta) async => _seekBy?.call(delta);
  Future<void> seekTo(Duration absolute) async => _seekTo?.call(absolute);
  Future<void> setSpeed(double speed) async => _setSpeed?.call(speed);
  void togglePlay() => _togglePlay?.call();

  /// 外部原因暂停（进作者空间、App 切后台、弹窗）。
  void pause() => _pauseExternal?.call();

  /// 外部原因恢复。
  void resume() => _resumeExternal?.call();

  /// 选档：`auto` = 自动，其余是「从低往上的第几档」。
  void pickQuality(QualityTier tier) => _pickQuality?.call(tier);
}

/// 一块视频画面。
class VideoSurface extends StatefulWidget {
  const VideoSurface({
    super.key,
    required this.options,
    this.posterUrl,
    this.tier = QualityTier.auto,
    this.autoUpgrade = true,
    this.dataSaver = false,
    this.loop = true,
    this.active = true,
    this.preload = false,
    this.muted = false,
    this.onCompleted,
    this.fit = BoxFit.contain,
    this.handle,
    this.cache,
    this.tweetId,
    this.idx = 0,
    this.onError,
  });

  /// 画质阶梯（低 → 高）。
  final VideoQualityOptions options;
  final String? posterUrl;

  /// 用户选的具体档位（[QualityTier]）；[QualityTier.auto] = 按网络自己爬。
  ///
  /// 这是**全局偏好**：在某条视频上选了「高」，其它视频也按「高」播放 ——
  /// 因为存的是相对档位，换成档数不同的视频也能映射到对应的那一档。
  final QualityTier tier;
  final bool autoUpgrade;

  /// 低数据模式：不切画质、不升档 —— 本地有缓存就用缓存里最好的那档，
  /// 没有就用最低档。播放器连第二路网络都不会开。
  final bool dataSaver;

  /// 循环播放。
  final bool loop;

  /// 是否是当前正在看的那一条。false 时暂停。
  final bool active;

  /// 相邻条目预读：只初始化不播放，滑过去就立刻有画面。
  final bool preload;

  /// 静音播放。列表里的自动预览用它 —— 一屏几个视频同时出声会炸掉。
  final bool muted;

  /// 播到结尾时回调（「连续播放」靠它滑到下一条）。循环时不会触发。
  final VoidCallback? onCompleted;

  final BoxFit fit;

  /// 父级用它来发指令（双击快进等）。
  final PlaybackHandle? handle;

  /// 媒体缓存：既是「本地文件在哪」的来源，也是「这条媒体看过什么画质」的记录处。
  final MediaCache? cache;
  final String? tweetId;
  final int idx;

  final void Function(String? error)? onError;

  @override
  State<VideoSurface> createState() => _VideoSurfaceState();
}

class _VideoSurfaceState extends State<VideoSurface>
    with SingleTickerProviderStateMixin {
  bool get _isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  // ---- 移动端 ----
  vp.VideoPlayerController? _cur;

  /// 换档时**正在淡出**的旧实例。
  ///
  /// 两个实例同时挂在屏幕上，新档从 0 淡到 1、旧档在下面继续放着 ——
  /// 这样「换纹理」的那一帧被旧画面盖住，看不到黑一下或者顿一下。
  /// 淡完再释放旧解码器。
  vp.VideoPlayerController? _prev;
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
    value: 1,
  );
  Timer? _prevReleaseTimer;

  // ---- 桌面端 ----
  Player? _mpv;
  VideoController? _mpvController;

  PlaybackSource? _source;
  String? _error;
  bool _inited = false;
  bool _initializing = false;

  Timer? _upgradeTimer;
  int _upgradeTries = 0;

  /// 换档进行中：挡住递归/重入。
  bool _switching = false;

  /// 每轮初始化/换源自增一次。
  ///
  /// 用来作废「已经飞出去但还没回来的异步续体」：`await` 之后 `mounted` 仍为 true
  /// 也可能已经被 teardown 掉了（换条视频、滑走），那时再 setState / 把旧的
  /// controller 塞回 `_cur` 就会画出一个已经释放的 texture（黑块）甚至 setState
  /// after dispose。所有 `await` 之后都拿它比一次。
  int _epoch = 0;

  /// 「播完」只报一次，位置回到中段才重新武装。
  bool _completedFired = false;

  /// 已经往缓存里记过的档位，避免每帧写库。
  String? _rememberedKey;

  /// 用户手动选的档位；[QualityTier.auto] = 自动。
  QualityTier _chosenTier = QualityTier.auto;

  /// 「换档途中又被点了别的档」的补救次数（防止异常情况下无限重试）。
  int _choiceRetries = 0;

  // ---- 自适应画质 ----
  //
  // 自动模式不是「无脑升到最高档」：真实的网速撑不住 720p 时升上去只会不停转圈。
  // 这里每秒采样一次「缓冲余量」，据此决定还能不能再往上爬，爬不动就退回来。
  Timer? _adaptTimer;
  int _weakSamples = 0;
  int _healthySamples = 0;

  /// 网络证明撑不住的档位（天花板）。null = 没有限制。
  String? _ceilingKey;

  /// 天花板被「放宽」过几次（防止「升上去→卡→退回来」无限循环）。
  int _ceilingRaises = 0;

  /// 已经因为网络不好降过几次档。
  int _downgrades = 0;

  @override
  void initState() {
    super.initState();
    _chosenTier = widget.tier;
    widget.handle?._push(clearQuality: true);
    _bootstrap();
  }

  @override
  void didUpdateWidget(covariant VideoSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tier != widget.tier) {
      // 全局偏好变了（可能在别的视频上选的）：这条也跟着切。
      _chosenTier = widget.tier;
      _choiceRetries = 0;
      _ceilingKey = null;
      _ceilingRaises = 0;
      _downgrades = 0;
      _applyChosen();
    }
    if (oldWidget.active != widget.active) {
      widget.active ? _play() : _pause();
    }
    if (oldWidget.options.sources.length != widget.options.sources.length) {
      _teardown();
      _bootstrap();
    }
  }

  // ------------------------------------------------------------------ 启动

  /// 决定「从哪一档起播」。这是整个「画质记忆」的入口：
  /// - 手动选了档位 → 就从那一档起播（本地文件正好是那档就直接读文件）；
  /// - 自动 → 本地文件是最高档就直接读它，否则用「这条看过的最好画质」，再退最低档。
  PlaybackSource? _startSource(VideoQualityOptions opts) {
    if (opts.isEmpty) return null;

    final cached = _cachedSource(opts);

    // 低数据模式：只认本地缓存（有就用，缓存是什么档就是什么档），
    // 没有缓存就用最低档，之后也不会升。
    if (widget.dataSaver) return cached ?? opts.fastest;

    if (!_chosenTier.isAuto) {
      final want = opts.sourceForTier(_chosenTier);
      if (want == null) return cached ?? opts.fastest;
      if (cached != null && cached.key == want.key) return cached;
      return want;
    }

    if (cached != null && cached.key == opts.best?.key) return cached;
    return cached ?? opts.sourceByKey(_bestRemembered()) ?? opts.fastest;
  }

  /// 本地缓存文件对应的档位。
  ///
  /// 老版本缓存没有记录档位，而它下载的一律是 `bestPlaybackUrl`（最高档），
  /// 所以「有文件但不知道哪档」按最高档处理 —— 顺便把记录补上。
  PlaybackSource? _cachedSource(VideoQualityOptions opts) {
    final cache = widget.cache;
    final id = widget.tweetId;
    if (cache == null || id == null) return null;
    if (cache.cachedFile(id, widget.idx) == null) return null;
    final key = cache.cachedVariant(id, widget.idx);
    if (key == null) {
      final best = opts.best;
      if (best != null) {
        cache.rememberVariant(id, widget.idx, best.key, best.rank);
      }
      return best;
    }
    return opts.sourceByKey(key);
  }

  /// 这条媒体**真正播过**的最好档位（跨会话记忆）。
  String? _bestRemembered() {
    final cache = widget.cache;
    final id = widget.tweetId;
    if (cache == null || id == null) return null;
    return cache.bestVariant(id, widget.idx);
  }

  Future<void> _bootstrap() async {
    if (_initializing) return;
    if (!widget.active && !widget.preload) return;
    _initializing = true;
    _inited = false;
    _error = null;
    _upgradeTimer?.cancel();
    _upgradeTries = 0;
    _ceilingKey = null;
    _ceilingRaises = 0;
    _downgrades = 0;
    _weakSamples = 0;
    _healthySamples = 0;
    final plan = _startSource(widget.options);
    if (plan == null) {
      _fail(t('play.noMedia'));
      _initializing = false;
      return;
    }
    _source = plan;
    _publishQuality();
    try {
      if (_isDesktop) {
        await _initDesktop(plan);
      } else {
        await _initMobile(plan);
      }
    } finally {
      _initializing = false;
    }
  }

  void _publishQuality() {
    final src = _source;
    widget.handle?._push(
      qualityLabel: widget.options.isSwitchable ? src?.label : null,
      qualityKey: src?.key,
      qualityHd: widget.options.isSwitchable ? src?.isHd : null,
    );
  }

  /// 真的播起来了才记录「这条媒体用过这一档」。
  ///
  /// 记在「开始出画面」而不是「开始初始化」：初始化失败/黑屏的档不能算数，
  /// 否则下次会从一个播不动的档起播。
  void _rememberPlayed() {
    final src = _source;
    final cache = widget.cache;
    final id = widget.tweetId;
    if (src == null || cache == null || id == null) return;
    if (_rememberedKey == src.key) return;
    _rememberedKey = src.key;
    cache.rememberVariant(id, widget.idx, src.key, src.rank);
  }

  // ------------------------------------------------------------- 移动端实现

  Future<void> _initMobile(PlaybackSource src) async {
    final epoch = _epoch;
    try {
      final controller = await _makeMobile(src);
      if (!mounted || epoch != _epoch) {
        // 这一轮已被作废（换条/滑走/teardown）：直接释放，别往 _cur 塞。
        await controller.dispose();
        return;
      }
      _cur = controller;
      _listenMobile(controller);
      setState(() {
        _inited = true;
      });
      widget.handle?._push(
        duration: controller.value.duration,
        ready: true,
        clearQuality: false,
      );
      _bindHandle();
      if (widget.active) {
        if (widget.muted) {
          try {
            await controller.setVolume(0);
          } catch (_) {}
        }
        await controller.play();
        _rememberPlayed();
        _startAdapting();
        _planUpgrade();
      }
    } catch (e) {
      if (epoch == _epoch) _fail('$e');
    }
  }

  /// 建一个移动端实例：有对应档位的本地文件就读文件，否则走网络。
  ///
  /// 关键点：**只认「这一档」的文件**。以前无条件优先读本地文件，而缓存里
  /// 永远是最高档，于是「切低画质」切了个寂寞（画面没变，标签却变了）。
  Future<vp.VideoPlayerController> _makeMobile(PlaybackSource src) async {
    final local = _localFileFor(src);
    final controller = local != null
        ? vp.VideoPlayerController.file(local)
        : vp.VideoPlayerController.networkUrl(Uri.parse(src.url));
    try {
      await controller.initialize();
      try {
        await controller.setLooping(widget.loop);
      } catch (_) {}
      return controller;
    } catch (e) {
      // 初始化失败也必须释放：ExoPlayer 在 initialize 过程中就已经占住了解码器，
      // 不 dispose 的话每次「重试」都泄漏一个，五六次之后 MediaCodec 分配失败，
      // 表现是「所有视频突然全黑」—— 看起来像播放器整体坏了。
      await controller.dispose();
      // 本地文件坏了/不完整：删掉记录，让下一次走网络重下。
      if (local != null) {
        widget.cache?.forgetCachedFile(widget.tweetId, widget.idx);
      }
      rethrow;
    }
  }

  File? _localFileFor(PlaybackSource src) {
    final cache = widget.cache;
    final id = widget.tweetId;
    if (cache == null || id == null) return null;
    final f = cache.fileForVariant(id, widget.idx, src.key);
    if (f == null || !f.existsSync()) return null;
    return f;
  }

  void _listenMobile(vp.VideoPlayerController c) {
    c.addListener(() {
      if (!mounted || _cur != c) return;
      final v = c.value;
      widget.handle?._push(
        position: v.position,
        duration: v.duration,
        playing: v.isPlaying,
        buffering: v.isBuffering,
        ready: v.isInitialized,
      );
      if (v.isPlaying && v.isInitialized) _rememberPlayed();
      // 播完检测（连续播放用）。循环时 ExoPlayer 不会停，所以这里也就不会触发。
      if (!_completedFired &&
          v.duration > Duration.zero &&
          v.position >= v.duration - const Duration(milliseconds: 250)) {
        _completedFired = true;
        widget.onCompleted?.call();
      } else if (v.position < v.duration - const Duration(seconds: 1)) {
        _completedFired = false;
      }
    });
  }

  // ------------------------------------------------------------- 桌面端实现

  Future<void> _initDesktop(PlaybackSource src) async {
    try {
      final player = Player();
      _mpv = player;
      final controller = VideoController(player);
      _mpvController = controller;
      player.stream.playing.listen(
        (_) => widget.handle?._push(playing: player.state.playing),
      );
      player.stream.buffering.listen((b) => widget.handle?._push(buffering: b));
      player.stream.position.listen((p) => widget.handle?._push(position: p));
      player.stream.duration.listen((d) {
        widget.handle?._push(duration: d);
      });
      player.stream.error.listen((e) => _fail(e));
      await player.setPlaylistMode(
        widget.loop ? PlaylistMode.single : PlaylistMode.none,
      );
      if (!mounted) return;
      setState(() => _inited = true);
      widget.handle?._push(ready: true);
      _bindHandle();
      await player.open(Media(src.url), play: widget.active);
      if (widget.active) _rememberPlayed();
    } catch (e) {
      _fail('$e');
    }
  }

  // ------------------------------------------------------------------ 控制

  void _bindHandle() {
    final h = widget.handle;
    if (h == null) return;
    h.attach(
      seekBy: _seekBy,
      seekTo: _seekTo,
      setSpeed: _setSpeed,
      togglePlay: _togglePlay,
      pickQuality: _pickQuality,
      canSwitchQuality: widget.options.isSwitchable,
      pause: () => unawaited(_pause()),
      resume: () => unawaited(_play()),
    );
    h._push(
      duration: _duration,
      qualityLabel: widget.options.isSwitchable ? _source?.label : null,
      qualityKey: _source?.key,
      qualityHd: widget.options.isSwitchable ? _source?.isHd : null,
    );
  }

  Duration get _duration => _isDesktop
      ? (_mpv?.state.duration ?? Duration.zero)
      : (_cur?.value.duration ?? Duration.zero);

  Duration get _position => _isDesktop
      ? (_mpv?.state.position ?? Duration.zero)
      : (_cur?.value.position ?? Duration.zero);

  /// 旧实例已经缓冲到多远（当前位置之后的余量）。
  Duration get _bufferAhead {
    final c = _cur;
    if (c == null) return Duration.zero;
    final v = c.value;
    var end = v.position;
    for (final range in v.buffered) {
      if (range.end > end) end = range.end;
    }
    return end - v.position;
  }

  Future<void> _seekBy(Duration delta) async {
    final target = _position + delta;
    final total = _duration;
    var clamped = target;
    if (clamped < Duration.zero) clamped = Duration.zero;
    if (total > Duration.zero && clamped > total) {
      clamped = total - const Duration(milliseconds: 200);
    }
    await _seekTo(clamped);
  }

  Future<void> _seekTo(Duration target) async {
    if (_isDesktop) {
      await _mpv?.seek(target);
      return;
    }
    final c = _cur;
    if (c == null) return;
    await c.seekTo(target);
  }

  Future<void> _setSpeed(double speed) async {
    if (_isDesktop) {
      await _mpv?.setRate(speed);
      return;
    }
    await _cur?.setPlaybackSpeed(speed);
    widget.handle?._push(speed: speed);
  }

  void _togglePlay() {
    if (_isDesktop) {
      final p = _mpv;
      if (p == null) return;
      p.state.playing ? p.pause() : p.play();
      return;
    }
    final c = _cur;
    if (c == null) return;
    c.value.isPlaying ? c.pause() : c.play();
  }

  Future<void> _play() async {
    if (_isDesktop) {
      await _mpv?.play();
      return;
    }
    if (!_inited) {
      await _bootstrap();
      return;
    }
    await _cur?.play();
    // preload 进来的相邻页初始化时 active 还是 false，那时没排「升清晰」；
    // 变成当前页时补排一次，否则它永远停在起播档。
    _startAdapting();
    _planUpgrade();
  }

  Future<void> _pause() async {
    _adaptTimer?.cancel();
    _adaptTimer = null;
    if (_isDesktop) {
      await _mpv?.pause();
      return;
    }
    await _cur?.pause();
  }

  // -------------------------------------------------------------- 自适应画质

  /// 开始每秒采样缓冲余量。
  ///
  /// 「自动」= 让网络决定爬到哪一档：
  /// - 余量充足（≥5s）→ 可以再往上爬一档；
  /// - 一直在转圈 / 余量见底 → 说明这一档这台网络撑不住，退回一档并把它记成
  ///   天花板，别再来回跳。
  void _startAdapting() {
    _adaptTimer?.cancel();
    _adaptTimer = null;
    _weakSamples = 0;
    _healthySamples = 0;
    if (_isDesktop) return;
    if (widget.dataSaver) return; // 低数据模式：不采样、不换档
    if (widget.muted) return; // 列表里的静音预览不升画质，也没必要采样
    _adaptTimer = Timer.periodic(
      const Duration(milliseconds: 900),
      (_) => _adaptTick(),
    );
  }

  void _adaptTick() {
    if (!mounted || !widget.active || _switching || widget.muted) return;
    if (!widget.autoUpgrade) return;
    final cur = _cur;
    if (cur == null || !cur.value.isInitialized || !cur.value.isPlaying) return;

    final ahead = _bufferAhead;
    final struggling =
        cur.value.isBuffering || ahead < const Duration(seconds: 1);
    if (struggling) {
      _weakSamples++;
      _healthySamples = 0;
    } else if (ahead >= const Duration(seconds: 5)) {
      _healthySamples++;
      _weakSamples = 0;
    } else {
      _weakSamples = 0;
      _healthySamples = 0;
    }

    if (_weakSamples >= 3) {
      _weakSamples = 0;
      unawaited(_stepDownForNetwork());
      return;
    }
    if (_healthySamples >= 3) {
      _healthySamples = 0;
      final ceiling = widget.options.sourceByKey(_ceilingKey);
      // 之前退过档：缓冲真的攒厚了才敢再试一次，而且最多放宽两次，
      // 免得「升上去 → 卡 → 退回来」一直循环。
      if (ceiling != null &&
          _ceilingRaises < 2 &&
          ahead >= const Duration(seconds: 8)) {
        _ceilingRaises++;
        _ceilingKey = widget.options.nextAbove(ceiling)?.key;
      }
      _planUpgrade();
    }
  }

  /// 网络撑不住：退回一档，并把这一档记成天花板。
  Future<void> _stepDownForNetwork() async {
    if (_switching || _downgrades >= 2) return;
    final opts = widget.options;
    final cur = _source;
    if (cur == null) return;
    PlaybackSource? lower;
    for (final s in opts.sources) {
      if (s.rank >= cur.rank) continue;
      if (lower == null || s.rank > lower.rank) lower = s;
    }
    if (lower == null) return; // 已经最低档，没什么可降的
    _downgrades++;
    _ceilingKey = lower.key;
    await _switchTo(lower);
  }

  /// 现在应该切到哪一档（null = 不用换 / 已经到位）。
  ///
  /// **一次到位**：不再一档一档往上爬。中间档只是「过渡」，用户既不会因此看得更久，
  /// 反而要经历好几次换档（每次都是一次解码器重建）。所以这里直接给出最终档：
  /// 手选了档就是那一档，自动就是「网络撑得住的最高档」（[`_ceilingKey`]）或最高档。
  PlaybackSource? _targetAbove(PlaybackSource cur) {
    final opts = widget.options;
    final cap = _chosenTier.isAuto
        ? opts.best
        : (_currentTierCap() ?? opts.best);
    if (cap == null) return null;

    final ceiling = opts.sourceByKey(_ceilingKey);
    var top = (ceiling != null && ceiling.rank < cap.rank) ? ceiling : cap;

    // 本地已经缓存了更高的档（最高档的文件就在磁盘上）→ 直接用它：
    // 读文件不花网络，没有理由还停在低档等升档。
    final best = opts.best;
    if (best != null &&
        best.rank > top.rank &&
        _localFileFor(best) != null &&
        (_chosenTier.isAuto || best.rank <= cap.rank)) {
      top = best;
    }

    if (cur.rank >= top.rank) return null;
    return top;
  }

  /// 当前档位在本条视频上对应的地址（自动 → null）。
  PlaybackSource? _currentTierCap() =>
      _chosenTier.isAuto ? null : widget.options.sourceForTier(_chosenTier);

  // -------------------------------------------------------------- 画质切换

  /// 用户选档（[QualityTier.auto] = 自动）。
  ///
  /// 选中的档位是**上限**：立刻切过去，之后网络撑不住会临时降档，恢复了再爬回来。
  /// 这个选择由上层写进全局设置，其它视频也会跟着切。
  Future<void> _pickQuality(QualityTier tier) async {
    _chosenTier = tier;
    _choiceRetries = 0;
    _upgradeTimer?.cancel();
    _upgradeTries = 0;
    // 手选之后就该按用户的意思来，之前因为网络记下的天花板先清掉。
    _ceilingKey = null;
    _ceilingRaises = 0;
    _downgrades = 0;
    await _applyChosen();
  }

  /// 把「当前选择」落到播放器上。
  Future<void> _applyChosen() async {
    final opts = widget.options;
    if (opts.isEmpty) return;

    final next = _startSource(opts);
    if (next == null) return;
    if (next.key == _source?.key) {
      _choiceRetries = 0;
      _publishQuality();
      _planUpgrade();
      return;
    }
    await _switchTo(next);
    _planUpgrade();
  }

  /// 自动升清晰：排一次「试试往上走」。
  void _planUpgrade() {
    if (_isDesktop) return; // 桌面不是重点，也不值得为它多开一个解码器
    if (widget.dataSaver) return; // 低数据模式：不升档
    if (!widget.autoUpgrade) return;
    if (!widget.active) return;

    final opts = widget.options;
    if (!opts.isSwitchable) return;
    final cur = _source;
    if (cur == null) return;
    if (_targetAbove(cur) == null) return; // 已经到上限 / 没有可爬的

    _upgradeTimer?.cancel();
    _upgradeTimer = Timer(const Duration(milliseconds: 900), () {
      unawaited(_tryUpgrade());
    });
  }

  /// 真的动手换档之前的三道闸（见文件头「为什么升画质会卡」）。
  Future<void> _tryUpgrade() async {
    if (!mounted || !widget.active || _switching || !_inited) return;
    final cur = _source;
    if (cur == null) return;

    final target = _targetAbove(cur);
    if (target == null) return;

    // 刚起播的一秒内别动：解码器还在热身，这时候再开一路只会更卡。
    if (_position < const Duration(milliseconds: 1000)) {
      _retryUpgradeLater();
      return;
    }

    // 快播完了就别折腾了 —— 换档本身要重新缓冲，收益抵不过那一下。
    final total = _duration;
    if (total > Duration.zero &&
        total - _position < const Duration(seconds: 4)) {
      return;
    }

    final hasLocal = _localFileFor(target) != null;
    if (!hasLocal && _bufferAhead < const Duration(seconds: 3)) {
      // 旧实例自己都还没缓冲够，这时候再开一路网络流必然互相抢。
      _retryUpgradeLater();
      return;
    }

    final ok = await _switchTo(target);
    if (!ok) {
      _retryUpgradeLater();
      return;
    }
    // 换到位之后再看一眼（正常情况下一次就到了；只有在网络天花板被放宽时才可能再动）。
    final now = _source;
    if (now != null && _targetAbove(now) != null) _planUpgrade();
  }

  void _retryUpgradeLater() {
    if (_upgradeTries >= 14) return; // 十几秒都不行就算了，别一直骚扰
    _upgradeTries++;
    _upgradeTimer?.cancel();
    _upgradeTimer = Timer(const Duration(milliseconds: 700), () {
      unawaited(_tryUpgrade());
    });
  }

  /// 换源。返回是否真的换成功了（失败时旧实例继续播，什么都不变）。
  ///
  /// 移动端流程：新实例静音起播 → 对齐进度 → 瞬时交接 → 释放旧实例。
  /// 细节见文件头注释。
  Future<bool> _switchTo(PlaybackSource target) async {
    if (_switching) return false;
    if (target.key == _source?.key) {
      _publishQuality();
      return true;
    }
    _switching = true;
    _upgradeTimer?.cancel();
    widget.handle?._setSwitching(true, target.displayLabel);
    try {
      if (_isDesktop) {
        return await _switchDesktop(target);
      }
      final old = _cur;
      if (old == null) {
        // 还没有播放器：直接重来一遍初始化更干净。
        _source = target;
        _publishQuality();
        await _bootstrap();
        return true;
      }
      return await _switchMobile(old, target);
    } catch (_) {
      return false;
    } finally {
      _switching = false;
      widget.handle?._setSwitching(false);
      _reconcileChoice();
    }
  }

  /// 换档期间用户又点了别的档：等这一轮结束再落一次。
  ///
  /// 不这么做的话，「正在自动升 720p，用户手动点了 480p」这个操作会被
  /// `_switchTo` 的重入保护直接丢掉 —— 菜单关掉了、画质却没变，很像 bug。
  void _reconcileChoice() {
    if (!mounted || _chosenTier.isAuto) return;
    final want = _currentTierCap();
    if (want == null || want.key == _source?.key) return;
    if (_choiceRetries >= 2) return;
    _choiceRetries++;
    _upgradeTimer?.cancel();
    _upgradeTimer = Timer(const Duration(milliseconds: 120), () {
      unawaited(_applyChosen());
    });
  }

  Future<bool> _switchDesktop(PlaybackSource target) async {
    final wasPlaying = _mpv?.state.playing ?? false;
    final resumeAt = _position;
    _source = target;
    _publishQuality();
    final p = _mpv;
    if (p == null) return false;
    await p.open(Media(target.url), play: wasPlaying);
    if (resumeAt > Duration.zero) await p.seek(resumeAt);
    return true;
  }

  Future<bool> _switchMobile(
    vp.VideoPlayerController old,
    PlaybackSource target,
  ) async {
    final wasPlaying = old.value.isPlaying;
    final speed = old.value.playbackSpeed;
    final epoch = ++_epoch;

    final next = await _makeMobile(target);
    if (!mounted || epoch != _epoch) {
      await next.dispose();
      return false;
    }

    // 1) 静音预备：先定位再起播，新实例的第一帧就是当前进度，
    //    不会出现「从 0 闪一下」。这一段用户听到的仍是旧实例的声音。
    await next.setVolume(0);
    if (speed != 1.0) {
      try {
        await next.setPlaybackSpeed(speed);
      } catch (_) {}
    }
    // 进度要**现在**读：_makeMobile 可能已经花掉一两秒，用旧值等于凭空落后。
    // 稍微往前多给 120ms，正好抵掉「seek 完再 play」这段时间的差距。
    final resumeAt = old.value.position + const Duration(milliseconds: 120);
    await next.seekTo(resumeAt);

    if (!wasPlaying) {
      // 暂停状态换画质：解码器把目标那一帧解出来就够了，不用等播放。
      await Future<void>.delayed(const Duration(milliseconds: 90));
      if (!mounted || epoch != _epoch) {
        await next.dispose();
        return false;
      }
      await _handOver(next, old, target);
      return true;
    }

    // 2) 让它静音播起来，等位置和旧实例对齐。对齐期间用户看到的还是旧画面，
    //    所以这段「追进度」的抖动是看不见的。
    await next.play();
    final aligned = await _waitAligned(next, old);
    if (!mounted || epoch != _epoch) {
      await next.dispose();
      return false;
    }
    if (!aligned) {
      // 追不平（网太慢/解码器忙）：这次不换，旧实例继续好好播。
      try {
        await next.pause();
      } catch (_) {}
      await next.dispose();
      return false;
    }

    // 3) 同一刻完成交接。
    await _handOver(next, old, target);
    return true;
  }

  /// 等新实例真的**在出帧并跟上进度**，再允许交接。
  ///
  /// 这一条是「换档时卡一小下」的根治点：以前只要求「不在缓冲」，但 ExoPlayer
  /// 在 seek 之后会先报 `isBuffering=false`、位置却还没往前走 —— 这时候交接，
  /// 用户就会看到一秒不到的静止画面。现在要求**两次采样的位置在前进**，
  /// 也就是确实在解码了。
  ///
  /// 位置差得多时最多主动 seek 两次（seek 发生在看不见的那个实例上），
  /// 之后差一点也认了 —— 比起多等好几秒，那 200ms 的偏差用户感觉不到。
  Future<bool> _waitAligned(
    vp.VideoPlayerController next,
    vp.VideoPlayerController old, {
    Duration timeout = const Duration(milliseconds: 3000),
  }) async {
    final deadline = DateTime.now().add(timeout);
    var seeks = 0;
    Duration? lastPos;
    while (DateTime.now().isBefore(deadline)) {
      if (!mounted || _cur != old) return false;
      final nv = next.value;
      if (nv.hasError) return false;
      if (!nv.isInitialized) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        continue;
      }
      final pos = nv.position;
      final advancing = lastPos != null && pos > lastPos;
      lastPos = pos;
      if (advancing && !nv.isBuffering) {
        final drift = pos - old.value.position;
        if (drift.abs() <= const Duration(milliseconds: 250)) return true;
        if (seeks < 2) {
          seeks++;
          try {
            lastPos = null; // 重新开始观察「在前进」
            await next.seekTo(
              old.value.position + const Duration(milliseconds: 40),
            );
          } catch (_) {
            return false;
          }
        } else {
          return true; // 差得不多也认了，别无限等下去
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    return false;
  }

  /// 交接：**推进式交叉淡化**。
  ///
  /// 关键是「淡到多少」由新实例是否真的在出帧决定，而不是由时间决定：
  /// - 新实例在动 → 继续往前淡；
  /// - 新实例卡住（缓冲/位置不动）→ 淡入停在 45%，**旧画面继续在下面演**，
  ///   看起来只是分辨率还没变，而不是画面冻住。
  ///
  /// 这样即使新档那一瞬间网络抖了一下，用户也不会看到「暂停」。
  Future<void> _handOver(
    vp.VideoPlayerController next,
    vp.VideoPlayerController old,
    PlaybackSource target,
  ) async {
    // 旧档：只静音，不停 —— 它要继续出画面，充当下面的垫层。
    try {
      await old.setVolume(0);
    } catch (_) {}
    try {
      await next.setVolume(widget.muted ? 0 : 1);
    } catch (_) {}
    _prev = old;
    _cur = next;
    _inited = true;
    _source = target;
    _listenMobile(next);
    _publishQuality();
    // 先把淡入值归零，再 setState：否则会先以 1.0 渲染一帧，等于硬切。
    _fade.value = 0;
    setState(() {});
    widget.handle?._push(
      duration: next.value.duration,
      ready: true,
      playing: next.value.isPlaying,
    );
    _rememberPlayed();

    // 按「新实例是否在出帧」推进淡化。
    final stopwatch = Stopwatch()..start();
    var lastPos = next.value.position;
    while (mounted && _cur == next && stopwatch.elapsedMilliseconds < 900) {
      final nv = next.value;
      final advancing =
          nv.isInitialized && !nv.isBuffering && nv.position > lastPos;
      if (nv.position > lastPos) lastPos = nv.position;
      final t = (stopwatch.elapsedMilliseconds / 420).clamp(0.0, 1.0);
      // 卡住就把不透明度压在 45%：旧画面还占主导，不会出现「冻住」。
      _fade.value = advancing ? t : (t < 0.45 ? t : 0.45);
      if (_fade.value >= 1) break;
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
    _fade.value = 1;

    // 用定时器而不是 await TickerFuture：widget 被回收时 ticker 会被 dispose，
    // 那个 future 永远不会完成，await 会把整个清理流程挂住。
    _prevReleaseTimer?.cancel();
    _prevReleaseTimer = Timer(const Duration(milliseconds: 260), () {
      unawaited(_releasePrev());
    });
  }

  /// 淡出结束：把旧实例摘下来释放。
  Future<void> _releasePrev() async {
    final old = _prev;
    if (old == null) return;
    _prev = null;
    _fade.value = 1;
    if (mounted) setState(() {});
    try {
      await old.pause();
    } catch (_) {}
    try {
      await old.dispose();
    } catch (_) {}
  }

  // ---------------------------------------------------------------- 收尾

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _error = message;
      _inited = false;
    });
    widget.handle?._push(ready: false, buffering: false, playing: false);
    widget.onError?.call(message);
  }

  void _teardown() {
    // 作废所有飞出去的异步续体：它们回来时会发现 epoch 变了。
    _epoch++;
    _upgradeTimer?.cancel();
    _upgradeTimer = null;
    _adaptTimer?.cancel();
    _adaptTimer = null;
    _prevReleaseTimer?.cancel();
    _prevReleaseTimer = null;
    _prev?.dispose();
    _prev = null;
    _fade.value = 1;
    _cur?.dispose();
    _cur = null;
    _mpv?.dispose();
    _mpv = null;
    _mpvController = null;
    // 必须一起重置：不重置的话 _bootstrap 里的 `if (_initializing) return`
    // 或 `_play()` 里的 `if (!_inited)` 会误判，出现「永久转圈」。
    _inited = false;
  }

  Future<void> _retry() async {
    _teardown();
    widget.handle?._push(ready: false, clearQuality: true);
    setState(() {
      _error = null;
      _inited = false;
    });
    _initializing = false;
    await _bootstrap();
  }

  @override
  void dispose() {
    widget.handle?.detach();
    _teardown();
    _fade.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ 渲染

  @override
  Widget build(BuildContext context) {
    final source = _source;
    final showPoster = widget.posterUrl != null;

    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 封面图垫底：初始化/缓冲时至少能看见这是哪条。
          if (showPoster)
            Opacity(
              opacity: _inited ? 0.0 : 0.55,
              child: Image.network(
                widget.posterUrl!,
                fit: BoxFit.contain,
                cacheWidth: 720,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
          if (_error == null && source != null) _videoLayer(),
          if (_error != null) _errorLayer(),
        ],
      ),
    );
  }

  Widget _videoLayer() {
    if (_isDesktop) {
      final c = _mpvController;
      if (c == null || !_inited) return _spinner();
      return Video(controller: c, controls: NoVideoControls, fit: widget.fit);
    }
    final cur = _cur;
    if (cur == null || !cur.value.isInitialized) return _spinner();

    final prev = _prev;
    if (prev == null || !prev.value.isInitialized) return _surface(cur);

    // 换档中：旧档在下、新档在上淡入。两层都是同一段同一进度，
    // 所以看起来只是「变清楚了」。
    return Stack(
      fit: StackFit.expand,
      children: [
        _surface(prev),
        AnimatedBuilder(
          animation: _fade,
          builder: (context, child) =>
              Opacity(opacity: _fade.value, child: child),
          child: _surface(cur),
        ),
      ],
    );
  }

  Widget _surface(vp.VideoPlayerController c) {
    final ar = c.value.aspectRatio == 0 ? 16 / 9 : c.value.aspectRatio;
    return FittedBox(
      fit: widget.fit,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(width: ar * 100, height: 100, child: vp.VideoPlayer(c)),
    );
  }

  Widget _spinner() => const Center(
    child: SizedBox(
      width: 28,
      height: 28,
      child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white70),
    ),
  );

  Widget _errorLayer() {
    return Center(
      child: GestureDetector(
        onTap: _retry,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.videocam_off_outlined, color: Colors.white70),
              const SizedBox(height: 8),
              Text(
                t('play.error'),
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 4),
              Text(
                _error ?? '',
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white38, fontSize: 11),
              ),
              const SizedBox(height: 10),
              OutlinedButton(
                onPressed: _retry,
                style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
                child: Text(t('play.retry')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

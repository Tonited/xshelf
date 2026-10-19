/// 抖音式全屏滑播页（移动端唯一的内容页）。
///
/// 交互（都按手机上的直觉来）：
/// - 上/下滑切换上一条/下一条，滑到临近末尾自动续页；
/// - 单击画面暂停/继续；**双击右半屏快进、左半屏快退**（秒数在设置里可改）；
/// - 长按临时倍速（默认 2×），松手恢复；
/// - 右侧动作栏：头像（进作者空间）/ 喜欢（取消喜欢）/ 关注 / 画质 / 更多；
/// - 正文在底部，点一下向上展开成可滚动全文，再点收起。
///
/// 每条内容自己管自己的播放器：只有「当前页」在播，下一页只预读首帧，
/// 其余全部释放 —— 这是滑得动、不烫手的关键。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_controller.dart';
import '../core/l10n.dart';
import '../core/settings.dart';
import '../media/gallery.dart';
import '../media/media_cache.dart';
import '../media/quality.dart';
import '../model/like_item.dart';
import '../state/feed_source.dart';
import 'author_page.dart';
import 'media_image.dart';
import 'rich_text.dart';
import 'video_view.dart';
import 'x_action_host.dart';

class FeedPage extends StatefulWidget {
  const FeedPage({
    super.key,
    required this.source,
    this.initialIndex = 0,
    this.initialTweetId,
    this.cache,
    this.extraTopAction,
    this.onCurrentChanged,
  });

  final FeedSource source;
  final int initialIndex;

  /// 优先按 id 定位（列表页可能滤掉了本次取消喜欢的条目，下标会对不上）。
  final String? initialTweetId;
  final MediaCache? cache;

  /// 顶部栏右侧的额外按钮（刷视频页用它放「切换来源」）。
  /// 放在这里而不是外面叠一层，是为了跟着沉浸模式一起显隐。
  final Widget? extraTopAction;

  /// 当前页变化时上报一次（列表页用它记住「最后看的是哪条」）。
  ///
  /// 之所以不靠 pop 结果：Android 的系统返回键、侧滑返回都是 Navigator 直接
  /// pop，不带 result —— 靠 result 的话这两条路上就定位不回去。
  final ValueChanged<String>? onCurrentChanged;

  @override
  State<FeedPage> createState() => _FeedPageState();
}

class _FeedPageState extends State<FeedPage> {
  late final PageController _page;
  int _index = 0;

  /// 「只看内容」放在父级：它是**跨条**的偏好，用户按一下之后滑到下一条
  /// 也应该保持沉浸。放在 `_FeedItem` 里会随 State 重建被重置。
  bool _immersive = false;

  @override
  void initState() {
    super.initState();
    // 按 id 定位：列表页的可见项可能比源头少（本次取消喜欢的被滤掉了），
    // 直接沿用列表里的下标会打开错的那一条。
    var index = widget.initialIndex;
    final id = widget.initialTweetId;
    if (id != null && id.isNotEmpty) {
      final at = widget.source.items.indexWhere((i) => i.tweetId == id);
      if (at >= 0) index = at;
    }
    _index = index.clamp(
      0,
      widget.source.items.isEmpty ? 0 : widget.source.items.length - 1,
    );
    _page = PageController(initialPage: _index);
    // 进来就往前后各预读一条，滑动时才不会白一下。
    _maybeLoadMore(_index);
    _reportCurrent();
  }

  /// 把「当前正在看的那条」报给外层（列表页靠它做返回定位）。
  void _reportCurrent() {
    final items = widget.source.items;
    if (_index < 0 || _index >= items.length) return;
    widget.onCurrentChanged?.call(items[_index].tweetId);
  }

  @override
  void dispose() {
    _page.dispose();
    super.dispose();
  }

  /// 视频播完自动滑到下一条（「连续播放」）。
  void _goNext() {
    final settings = AppScope.read(context).settings.playback;
    if (!settings.autoNext || settings.loop) return;
    if (!_page.hasClients) return;
    final next = _index + 1;
    final total = widget.source.items.length;
    if (next >= total) return;
    _page.animateToPage(
      next,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOut,
    );
  }

  void _maybeLoadMore(int index) {
    final items = widget.source.items;
    if (index >= items.length - 3) {
      unawaited(widget.source.loadMore());
    }
  }

  void _onPageChanged(int index) {
    setState(() => _index = index);
    _maybeLoadMore(index);
    _reportCurrent();
  }

  /// 取消喜欢之后列表少了一条：把当前页码拉回合法范围，别停在空白上。
  ///
  /// 主列表（BrowseState）自己会删；但作者空间/搜索结果这些内存源不会，
  /// 所以这里统一调一次 `dropLocal`（幂等）。
  void _afterRemoved(String tweetId) {
    widget.source.dropLocal(tweetId);
    final items = widget.source.items;
    final next = _index.clamp(0, items.isEmpty ? 0 : items.length - 1);
    if (next != _index) {
      setState(() => _index = next);
      if (_page.hasClients) _page.jumpToPage(next);
    } else {
      setState(() {});
    }
  }

  /// 关闭播放页，并把**当前正在看的那一条**带回去。
  ///
  /// 列表页拿到这个 id 就把自己锚定到该条 —— 否则用户在播放页里滑了十几条，
  /// 一返回又被丢回进入时那一条，只能自己再滚一遍找回来。
  /// 在播放页里被取消、但还没落库的条目（退出时统一处理）。
  ///
  /// 不放在点击当下落库，是为了让那一条留在原处：一旦从 `items` 里消失，
  /// PageView 的下标就指到别的条目上，看起来就像「取消个喜欢，页面自己翻走了」。
  final Set<String> _deferredUnlike = {};
  final Set<String> _deferredUnbookmark = {};

  void _markDeferred(String tweetId, {required bool like}) {
    (like ? _deferredUnlike : _deferredUnbookmark).add(tweetId);
  }

  void _close() {
    // pop 之后 context 就失效了，所以先把 app 取出来。
    final app = AppScope.read(context);
    final items = widget.source.items;
    final id = (_index >= 0 && _index < items.length)
        ? items[_index].tweetId
        : null;
    Navigator.of(context).maybePop(id);
    _flushDeferred(app);
  }

  Future<void> _flushDeferred(AppController app) async {
    for (final id in _deferredUnlike.toList()) {
      await app.unlikeLocally(id);
    }
    for (final id in _deferredUnbookmark.toList()) {
      await app.unbookmarkLocally(id);
    }
    _deferredUnlike.clear();
    _deferredUnbookmark.clear();
  }

  @override
  Widget build(BuildContext context) {
    // 用 of 而不是 read：设置一变（比如在别的视频上选了画质）整页跟着重建，
    // 正在播的这条和其它条目都会切到新档位。
    final app = AppScope.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      body: ListenableBuilder(
        listenable: widget.source,
        builder: (context, _) {
          final items = widget.source.items;
          if (items.isEmpty) {
            return const Center(
              child: Text('—', style: TextStyle(color: Colors.white38)),
            );
          }
          final settings = app.settings.playback;
          return PageView.builder(
            controller: _page,
            scrollDirection: Axis.vertical,
            allowImplicitScrolling: true,
            onPageChanged: _onPageChanged,
            itemCount: items.length,
            itemBuilder: (context, i) {
              final item = items[i];
              return _FeedItem(
                key: ValueKey(item.tweetId),
                item: item,
                index: i,
                active: i == _index,
                preload: i == _index + 1,
                cache: widget.cache,
                settings: settings,
                immersive: _immersive,
                onImmersiveChanged: (v) {
                  if (v == _immersive) return;
                  setState(() => _immersive = v);
                },
                extraTopAction: widget.extraTopAction,
                onRequestNext: _goNext,
                onClose: _close,
                onRemoved: _afterRemoved,
                onDeferredRemove: _markDeferred,
              );
            },
          );
        },
      ),
    );
  }
}

/// 一屏内容。
class _FeedItem extends StatefulWidget {
  const _FeedItem({
    super.key,
    required this.item,
    required this.index,
    required this.active,
    required this.preload,
    required this.settings,
    required this.onClose,
    required this.onRemoved,
    required this.immersive,
    required this.onImmersiveChanged,
    this.extraTopAction,
    this.onRequestNext,
    this.onDeferredRemove,
    this.cache,
  });

  final LikeItem item;
  final int index;
  final bool active;
  final bool preload;
  final PlaybackSettings settings;
  final VoidCallback onClose;
  final void Function(String tweetId) onRemoved;

  /// 「这条被取消了喜欢/书签」——先记在外层，退出播放页时才落库。
  final void Function(String tweetId, {required bool like})? onDeferredRemove;
  final MediaCache? cache;

  /// 是否「只看内容」（由 FeedPage 持有，跨条保持）。
  final bool immersive;
  final ValueChanged<bool> onImmersiveChanged;

  /// 顶部栏右侧的额外按钮（刷视频页放「切换来源」）。
  final Widget? extraTopAction;

  /// 视频播完请求滑到下一条（连续播放）。
  final VoidCallback? onRequestNext;

  @override
  State<_FeedItem> createState() => _FeedItemState();
}

class _FeedItemState extends State<_FeedItem> with WidgetsBindingObserver {
  final PlaybackHandle _handle = PlaybackHandle();

  /// 画质档位是**全局设置**（[PlaybackSettings.qualityTier]），这里不再存副本。
  QualityTier get _tier => widget.settings.qualityTier;

  bool _textExpanded = false;
  bool _boost = false;
  String? _hint;
  bool _hintFlash = false;
  Timer? _hintTimer;
  Offset _doubleTapAt = Offset.zero;
  bool _busyUnlike = false;
  bool _busyGallery = false;

  /// 这条是否已在书签里（本地记录；进入时查一次，之后跟着切换更新）。
  bool _bookmarked = false;
  bool _busyBookmark = false;

  /// 画面右上角的画质提示（升级完成/切换到高档时闪一下）。
  String? _qualityToast;
  Timer? _qualityToastTimer;
  String? _lastQualityLabel;

  /// 本条里「刚刚取消了喜欢」的推文。取消后仍留在列表里（可以点回来），
  /// 所以状态只能记在内存里，不能只靠库。
  final Set<String> _unliked = {};

  /// 这个作者我关注了没。先读本地记录，进页面时再向 X 核对一次。
  bool _following = false;

  // ---- 单击 / 双击的自定义判定 ----
  //
  // 直接用 GestureDetector 的 onTap + onDoubleTap 会让**每一次**单击都等
  // 300ms（它要先排除双击）。抖音式浏览里「点一下立刻停」是核心手感，
  // 所以单击自己用 Listener 判（位移小 + 时间短），双击仍交给 GestureDetector。
  Timer? _tapTimer;
  Offset _downAt = Offset.zero;
  DateTime _downAtTime = DateTime.now();
  bool _suppressTap = false;

  // ---- 进度条拖动 ----
  bool _dragging = false;
  int _dragMs = 0;
  bool _wasPlayingBeforeSeek = false;

  /// 多图 / 多视频推文当前看到第几个（底部横线指示器用）。
  int _pageIndex = 0;

  /// 「划过最后一张」的节流时间戳（同一个手势只进一次作者页）。
  DateTime? _pastLastAt;

  /// 在最后一张上继续往左拖的累积距离。
  ///
  /// 原来这里用 `OverscrollNotification.velocity < -600` 判断，但 Android 默认的
  /// Clamping 物理下这个 velocity 恒为 0 —— 条件永远不成立，「划过最后一张进作者页」
  /// 其实**从没生效过**。改成累积位移，手感也更接近「拖出去一段才触发」。
  double _overscrollAccum = 0;

  /// 播放页专用横屏。退出页面时恢复成跟随系统。
  bool _landscape = false;

  /// 顶部 / 右侧 / 底部这圈界面元素是否可见。
  ///
  /// **只由右下角那颗按钮决定**：点屏幕不唤出、也不再有 4 秒自动隐藏。
  /// 之前「点一下唤出」和「点一下暂停」抢同一个手势，用户常常想暂停却先把
  /// 按钮叫出来了；现在屏幕点击只负责播放/暂停，界面归那个按钮管。
  bool get _chromeVisible => !widget.immersive;

  AppController get _app => AppScope.read(context);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _handle.addListener(_onHandleChanged);
    // 画质档位来自全局设置（在任意一条视频上选过就全局生效），这里不用初始化。
    _following = _app.db.isFollowing(widget.item.author?.id ?? '');
    _bookmarked = _app.db.hasTweet(widget.item.tweetId, kind: 'bookmark');
    unawaited(_syncFollowState());
    if (widget.active) _cacheVideoInBackground();
  }

  /// 画质变化 → 右上角闪一下「720p」。
  ///
  /// 用户之前完全看不出「到底升了没有」：画面是慢慢变清楚的，标签又藏在菜单里。
  /// 现在切档完成的那一刻给一个不打扰的提示，另外换档过程中还有一个更小的
  /// 「切换到 720p…」小条（见 [_qualityIndicator]）。
  void _onHandleChanged() {
    final label = _handle.qualityLabel;
    if (label == null) {
      _lastQualityLabel = null;
      return;
    }
    if (label == _lastQualityLabel) return;
    final first = _lastQualityLabel == null;
    _lastQualityLabel = label;
    // 起播那一下只在「一上来就是高清」（命中缓存/记忆）时提示，
    // 如果是从低档起播，提示等真正升档时再出。
    if (first && !_handle.qualityHd) return;
    // 提示里也用 `1280P` 这种写法（和右上角按钮统一）。
    final shown =
        _currentPlayable()?.opts
            .sourceByKey(_handle.qualityKey)
            ?.displayLabel ??
        label;
    _flashQuality(shown);
  }

  void _flashQuality(String label) {
    if (!mounted) return;
    _qualityToastTimer?.cancel();
    setState(() => _qualityToast = label);
    _qualityToastTimer = Timer(const Duration(milliseconds: 1800), () {
      if (mounted) setState(() => _qualityToast = null);
    });
  }

  /// 关注状态向 X 核对一次（本地记录只知道在 App 里点过的）。
  Future<void> _syncFollowState() async {
    final author = widget.item.author;
    if (author == null || author.screenName.isEmpty) return;
    if (!widget.active) return;
    final remote = await _app.isFollowingRemote(author.screenName);
    if (remote == null || !mounted || remote == _following) return;
    setState(() => _following = remote);
    if (author.id.isNotEmpty) {
      _app.db.setFollowing(author.id, remote);
    }
  }

  /// 视频默认缓存到本地：滑到哪条就后台把它的最佳档落盘。
  ///
  /// 只做当前这条（不预缓存相邻页）：否则滑十条就吞掉十条视频的流量。
  /// 存进同一个 MediaCache，和「保存到相册」共用文件，不会重复下载。
  ///
  /// **等播放器稳定了再下**：刚起播那一两秒，ExoPlayer 自己还在拉首帧，
  /// 这时候再开一路下载会把带宽分走，表现就是「刚点开就卡」。
  void _cacheVideoInBackground() {
    // 低数据模式：不预下载视频（那是最费流量的一项）。
    if (_app.settings.lowDataMode) return;
    final cache = _app.mediaCache;
    if (cache == null) return;
    unawaited(_cacheAfterSettled(cache));
  }

  Future<void> _cacheAfterSettled(MediaCache cache) async {
    // 最多等 12 秒；期间只要播放器在缓冲就继续等。
    for (var i = 0; i < 15; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 800));
      if (!mounted || !widget.active) return;
      if (!_handle.ready) continue;
      if (_handle.buffering) continue;
      break;
    }
    if (!mounted) return;
    final item = widget.item;
    for (var i = 0; i < item.media.length; i++) {
      final m = item.media[i];
      if (!m.isPlayable) continue;
      if (cache.cachedFile(item.tweetId, i) != null) continue;
      final best = VideoQualityOptions.of(m).best;
      if (best == null) continue;
      unawaited(
        cache.ensureCached(
          tweetId: item.tweetId,
          idx: i,
          url: best.url,
          variant: best.key,
          rank: best.rank,
        ),
      );
    }
  }

  /// 播放页专用横屏。退出页面时统一恢复成「跟随系统」，
  /// 否则用户回到列表还是横的，会以为 App 卡住了。
  Future<void> _toggleOrientation() async {
    final next = !_landscape;
    setState(() => _landscape = next);
    // 横屏基本都是为了看画面，顺手进沉浸模式（跨条保持）。
    if (next) widget.onImmersiveChanged(true);
    await SystemChrome.setPreferredOrientations(
      next
          ? const [
              DeviceOrientation.landscapeLeft,
              DeviceOrientation.landscapeRight,
            ]
          : const [],
    );
  }

  /// 切后台/锁屏时把声音停掉 —— ExoPlayer 不会自己停，锁屏后视频还在放。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!widget.active || !_handle.attached) return;
    if (state == AppLifecycleState.resumed) {
      _handle.resume();
    } else {
      _handle.pause();
    }
  }

  @override
  void didUpdateWidget(covariant _FeedItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.active && widget.active) {
      _textExpanded = false;
      // 注意：**不**重置沉浸状态 —— 那是跨条的偏好，不是本条的状态。
      _pageIndex = 0;
      _cacheVideoInBackground();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tapTimer?.cancel();
    _hintTimer?.cancel();
    _qualityToastTimer?.cancel();
    _handle.removeListener(_onHandleChanged);
    // 从播放页离开时把方向还回去，不然列表页会留在横屏。
    if (_landscape) {
      SystemChrome.setPreferredOrientations(const []);
    }
    _handle.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ 交互

  void _flashHint(String text) {
    _hintTimer?.cancel();
    setState(() {
      _hint = text;
      _hintFlash = true;
    });
    _hintTimer = Timer(const Duration(milliseconds: 650), () {
      if (mounted) setState(() => _hintFlash = false);
    });
  }

  void _onTap() {
    // 界面显隐只归右下角按钮管，所以屏幕点击在这里只有一个职责：
    // 暂停 / 继续。（沉浸状态下同理 —— 想调出按钮就点那个按钮。）
    if (_handle.attached) _handle.togglePlay();
  }

  void _onDoubleTap() {
    if (!_handle.attached) return;
    final width = MediaQuery.sizeOf(context).width;
    final seconds = widget.settings.doubleTapSeconds;
    final dx = _doubleTapAt.dx;
    if (dx < width * 0.38) {
      unawaited(_handle.seekBy(Duration(seconds: -seconds)));
      _flashHint(tf('play.jumpBack', {'s': seconds}));
    } else if (dx > width * 0.62) {
      unawaited(_handle.seekBy(Duration(seconds: seconds)));
      _flashHint(tf('play.jumpForward', {'s': seconds}));
    }
  }

  void _startBoost() {
    if (!_handle.attached) return;
    setState(() => _boost = true);
    unawaited(_handle.setSpeed(widget.settings.longPressSpeed));
  }

  void _endBoost() {
    if (!_boost) return;
    setState(() => _boost = false);
    unawaited(_handle.setSpeed(1.0));
  }

  /// 取消 / 恢复喜欢。
  ///
  /// 刻意**不做二次确认**：误点了就在同一页再点一次「喜欢」—— 数据只是被标记
  /// 成 `removed`，缓存和整行内容都还在，点回来是原样恢复。
  ///
  /// 两处表现刻意不同：
  /// - **播放页**：当前这条留着，心形变空心、文字变「喜欢」，点一下就能点回来；
  /// - **列表**（[BrowseState.listItems]）：立刻不显示它，重进 App 也不会回来。
  Future<void> _toggleUnlike() async {
    final item = widget.item;
    if (_busyUnlike) return;

    final alreadyUnliked = _unliked.contains(item.tweetId);
    // 再点一次 = 恢复喜欢。
    final targetLike = alreadyUnliked;
    setState(() {
      _busyUnlike = true;
      // 乐观：点下去先翻转，写回慢（要走网页）也不让按钮「没反应」。
      targetLike ? _unliked.remove(item.tweetId) : _unliked.add(item.tweetId);
    });
    // 恢复喜欢要落库（让它重新出现）；取消只发网络 —— 本地等退出时才移除，
    // 这样这条会留在原地，不会「点一下页面自己翻走」。
    final err = targetLike
        ? await _app.like(item.tweetId)
        : await _app.unlikeRemote(item.tweetId);
    if (!mounted) return;
    if (err == null) {
      setState(() => _busyUnlike = false);
      if (!targetLike) {
        widget.onDeferredRemove?.call(item.tweetId, like: true);
      }
      _flashHint(targetLike ? t('play.liked') : t('play.unliked'));
      return;
    }
    // 直连被 X 的签名门槛挡住（它返回空 404）→ 交给屏幕外的网页去点。
    final ok = await XActionHost.toggle(
      tweetId: item.tweetId,
      action: XWriteAction.like,
      add: targetLike,
    );
    if (!mounted) return;
    setState(() => _busyUnlike = false);
    if (!ok) {
      setState(() {
        // 回滚
        targetLike ? _unliked.add(item.tweetId) : _unliked.remove(item.tweetId);
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
      return;
    }
    if (targetLike) {
      await _app.likeLocally(item.tweetId);
    } else {
      // 取消喜欢：本地先不动，退出播放页时统一落地（见 _flushDeferred）。
      widget.onDeferredRemove?.call(item.tweetId, like: true);
    }
    if (!mounted) return;
    _flashHint(targetLike ? t('play.liked') : t('play.unliked'));
  }

  /// 加入 / 移除书签。
  ///
  /// 写回现在有两条路（直连多半会被 X 的签名门槛挡下，见 [XActionHost]），
  /// 两条都慢，所以这里做**乐观更新**：点下去先翻转，失败再回滚并提示。
  Future<void> _toggleBookmark() async {
    if (_busyBookmark) return;
    final item = widget.item;
    final wasBookmarked = _bookmarked;
    final target = !wasBookmarked;
    setState(() {
      _busyBookmark = true;
      _bookmarked = target; // 乐观
    });
    // 加上书签要落库（立刻出现在书签列表里）；移除只发网络。
    final err = target
        ? await _app.bookmark(item)
        : await _app.unbookmarkRemote(item.tweetId);
    if (!mounted) return;
    if (err == null) {
      setState(() => _busyBookmark = false);
      if (!target) {
        // 取消书签：本地先不动，退出播放页时统一落地。
        widget.onDeferredRemove?.call(item.tweetId, like: false);
      }
      _flashHint(
        _bookmarked ? t('play.bookmarkAdded') : t('play.bookmarkRemoved'),
      );
      return;
    }
    // 直连失败：X 对写操作要求 `x-client-transaction-id` 签名（它自家 JS 签的），
    // 缺了会返回空 404。这时交给屏幕外的网页去点，界面不被打断。
    final ok = await XActionHost.toggle(
      tweetId: item.tweetId,
      action: XWriteAction.bookmark,
      add: target,
    );
    if (!mounted) return;
    setState(() => _busyBookmark = false);
    if (!ok) {
      setState(() => _bookmarked = wasBookmarked); // 回滚
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
      return;
    }
    if (target) {
      await _app.bookmarkLocally(item);
    } else {
      // 取消书签：本地先不动，退出播放页时统一落地（见 _flushDeferred）。
      widget.onDeferredRemove?.call(item.tweetId, like: false);
    }
    if (!mounted) return;
    _flashHint(
      _bookmarked ? t('play.bookmarkAdded') : t('play.bookmarkRemoved'),
    );
  }

  /// 把当前这张图/这条视频存进系统相册。
  ///
  /// 复用的是媒体缓存（命中缓存就不重新下载），所以「看过一遍再存相册」是零下载。
  Future<void> _saveToGallery() async {
    final cache = _app.mediaCache;
    if (cache == null || _busyGallery) return;
    final item = widget.item;
    if (item.media.isEmpty) return;

    final idx = (_pageIndex >= 0 && _pageIndex < item.media.length)
        ? _pageIndex
        : 0;
    final media = item.media[idx];
    // 图片存 orig（相册里当然要原图），视频存最佳 mp4。
    final url = media.isPlayable
        ? (media.bestPlaybackUrl ?? media.url)
        : withImageVariant(media.url, 'orig');

    setState(() => _busyGallery = true);
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(SnackBar(content: Text(t('play.savingGallery'))));
    final err = await saveMediaToGallery(
      cache: cache,
      tweetId: item.tweetId,
      idx: idx,
      url: url,
      isVideo: media.isPlayable,
    );
    if (!mounted) return;
    setState(() => _busyGallery = false);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(content: Text(err ?? t('play.savedGallery'))),
    );
  }

  /// 点头像：进本地「作者空间」，看这个人在你这里被喜欢过的全部内容。
  ///
  /// 进页面之前先暂停：FeedPage 还留在路由栈里，不停就是「背后放声音」。
  Future<void> _openAuthor() async {
    final author = widget.item.author;
    if (author == null || author.screenName.isEmpty) return;
    _handle.pause();
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AuthorPage(author: author, cache: widget.cache),
      ),
    );
    if (!mounted) return;
    if (widget.active) _handle.resume();
  }

  // ------------------------------------------------------------------ 渲染

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    // 一条推文可以有多个视频（X 允许 4 个），所以「当前这一屏是视频还是图」
    // 由当前轮播位置决定，而不是「有没有视频」。
    final media = item.media;
    final currentIdx = media.isEmpty
        ? 0
        : _pageIndex.clamp(0, media.length - 1);
    final hasVideo = media.isNotEmpty && media[currentIdx].isPlayable;

    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 手势层在**最底下**：只有「没被界面元素挡住的地方」才吃得到点击。
          //
          // 以前手势层包着整个 Stack（包括界面），于是点右侧动作栏、点底部正文
          // 也会顺手把视频暂停 —— 用户点「在 X 打开」，回来发现视频停了。
          // 现在界面在上层，有内容的地方自己把点击吃掉（见 [_overlay] 里的
          // opaque 手势），空白处才落到这一层 = 暂停/继续。
          // 沉浸模式把界面整个 IgnorePointer 掉，于是点哪儿都能暂停。
          Positioned.fill(child: _gestureLayer(item, hasVideo)),
          Positioned.fill(
            child: AnimatedOpacity(
              // 渐变是给底部文字垫底的：界面藏起来之后它就是一块脏东西，
              // 盖在最该露出来的画面上。跟着按钮一起淡出。
              opacity: _chromeVisible ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: _bottomScrim(),
            ),
          ),
          _overlay(item, hasVideo),
        ],
      ),
    );
  }

  /// 纯文字帖子：没有媒体可铺，就把正文放大排好。
  ///
  /// 以前这里直接返回一块纯黑 —— 整屏空着，文字只能挤在底部那条小字里。
  /// 现在按阅读排布（字号放大、行高放宽）；太长时截断，底部仍然可以点开看全文。
  Widget _textPage(LikeItem item) {
    final text = item.text.trim();
    return ColoredBox(
      color: Colors.black,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 72, 22, 210),
          child: Align(
            alignment: Alignment.topLeft,
            child: Text(
              text.isEmpty ? '—' : text,
              maxLines: 22,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                height: 1.5,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 画面上的手势：单击暂停/继续、双击快进快退、长按倍速。
  Widget _gestureLayer(LikeItem item, bool hasVideo) {
    return Listener(
      onPointerDown: (e) {
        _downAt = e.localPosition;
        _downAtTime = DateTime.now();
        _suppressTap = false;
      },
      onPointerUp: (e) {
        _tapTimer?.cancel();
        // 正在拖进度条：松手不能当成「单击暂停」。
        if (_dragging) return;
        if (_suppressTap) {
          _suppressTap = false;
          return;
        }
        // 拖动翻页、长按倍速都不算「单击」：看位移和按住时长。
        final moved = (e.localPosition - _downAt).distance;
        final held = DateTime.now().difference(_downAtTime);
        if (moved > 14 || held > const Duration(milliseconds: 420)) return;
        // 260ms 内没有第二下，就认定是单击。
        _tapTimer = Timer(const Duration(milliseconds: 260), () {
          if (mounted) _onTap();
        });
      },
      onPointerCancel: (_) => _tapTimer?.cancel(),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onDoubleTapDown: (d) {
          _tapTimer?.cancel();
          _doubleTapAt = d.localPosition;
        },
        onDoubleTap: () {
          _tapTimer?.cancel();
          _onDoubleTap();
        },
        onLongPressStart: hasVideo
            ? (_) {
                _tapTimer?.cancel();
                _suppressTap = true;
                _startBoost();
              }
            : null,
        onLongPressEnd: hasVideo ? (_) => _endBoost() : null,
        onLongPressCancel: hasVideo ? _endBoost : null,
        child: _media(item),
      ),
    );
  }

  /// 媒体区。一条推文的 `media` 可以是「图 + 视频」混排，也可以是好几个视频，
  /// 所以统一按「轮播页」处理：每一页要么是视频播放器，要么是一张图。
  ///
  /// 只有**当前页**真的起播：PageView 会预建相邻页，如果相邻页也去
  /// initialize 一个 ExoPlayer，翻两条就吃掉好几个解码器。
  ///
  /// 关键：**每一页都用同一个 widget 结构**（`_mediaPage(current:)`），
  /// 而不是「当前页一种、相邻页另一种」。以前相邻页是小图、翻过去换成大图，
  /// 解码尺寸也跟着变 —— 等于重新拉一次图、重新解码，翻页就是肉眼可见的一闪。
  ///
  /// 另外：滑到最后一张（或这条只有一个视频）还往左划 → 进作者空间。
  Widget _media(LikeItem item) {
    final media = item.media;
    if (media.isEmpty) return _textPage(item);
    if (media.length == 1) {
      // 单媒体：没有 PageView 可翻，直接听「快速左划」这个手势。
      // 阈值故意设得很高：随手一划（尤其斜着划）不该跳到作者页 ——
      // 那会闪出一个浅色页面，看起来就像「划一下冒出灰底」。
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragEnd: (details) {
          final v = details.primaryVelocity ?? 0;
          if (v < -900) _openAuthor(); // 明确地往左甩
        },
        child: _mediaPage(item, 0, current: true),
      );
    }

    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        // 已经停在最后一页还继续往左拖：把用户送到作者空间，而不是让画面原地弹一下。
        //
        // 判据用**累积位移**而不是 velocity（Clamping 下 velocity 恒为 0，见
        // [_overscrollAccum] 的注释）。够远才算，避免滑到边缘时轻微一顿就跳页。
        if (n is OverscrollNotification) {
          if (_pageIndex >= media.length - 1 && n.overscroll > 0) {
            _overscrollAccum += n.overscroll;
            if (_overscrollAccum > 90) _swipedPastLast();
          }
        } else if (n is ScrollEndNotification) {
          _overscrollAccum = 0;
        }
        return false;
      },
      child: PageView.builder(
        itemCount: media.length,
        onPageChanged: (i) {
          if (i != _pageIndex) setState(() => _pageIndex = i);
        },
        itemBuilder: (context, i) =>
            _mediaPage(item, i, current: i == _pageIndex),
      ),
    );
  }

  /// 划过了最后一张：进作者空间（同一个手势只触发一次）。
  void _swipedPastLast() {
    if (_pastLastAt != null) return;
    _pastLastAt = DateTime.now();
    _openAuthor();
    Future<void>.delayed(const Duration(seconds: 1), () {
      if (mounted) _pastLastAt = null;
    });
  }

  Widget _mediaPage(LikeItem item, int idx, {required bool current}) {
    // 每一页自己铺一层纯黑底：横向拖动时 PageView 会把相邻页拉进来，
    // 任何透出来的地方都必须是黑 —— 不然浅色主题的 surface 会露出来，
    // 看起来就是「横着划一下有一块灰色」。
    return ColoredBox(
      color: Colors.black,
      child: _mediaPageContent(item, idx, current: current),
    );
  }

  Widget _mediaPageContent(LikeItem item, int idx, {required bool current}) {
    final m = item.media[idx];
    if (m.isPlayable) {
      if (!current) return _mediaPoster(item, idx, current: false);
      final opts = VideoQualityOptions.of(m);
      final dataSaver = _app.settings.lowDataMode;
      return VideoSurface(
        // key 带上 tweetId + 序号 + 地址：换页/换条时必须重新开流，
        // 否则沿用同一个 State 会出现「播的还是上一条」。
        key: ValueKey('v:${item.tweetId}:$idx:${opts.best?.url}'),
        options: opts,
        // 封面也用 small：poster 只是"视频还没出画面时的垫底"，不需要大图。
        posterUrl: withImageVariant(m.url, 'small'),
        tier: dataSaver ? QualityTier.auto : _tier,
        // 低数据模式不升档；其它情况「自动」= 网络决定能到哪一档，手选的那一档是上限。
        autoUpgrade: !dataSaver,
        dataSaver: dataSaver,
        loop: widget.settings.loop,
        active: widget.active,
        preload: widget.preload,
        handle: _handle,
        // 缓存既提供「本地文件在哪」，又记住「这条媒体看过什么画质」——
        // 下次打开直接从看过的最好档起播，有文件时零网络。
        cache: widget.cache,
        tweetId: item.tweetId,
        idx: idx,
        fit: BoxFit.contain,
        // 只有「连续播放」开着、且没开循环时才接：循环时视频永远不会播完。
        onCompleted: (widget.settings.autoNext && !widget.settings.loop)
            ? widget.onRequestNext
            : null,
      );
    }
    return _mediaPoster(item, idx, current: current);
  }

  /// 一张图。**当前页和相邻页用同一套参数**（同 URL 同解码宽度），
  /// 翻页时 Flutter 直接从图片缓存里取，不会再闪一下。
  ///
  /// 当前页额外挂一条「large → orig」的升级链：先出能看的，再把原图补上；
  /// 看过原图的记住了档位，下次直接是原图。
  Widget _mediaPoster(LikeItem item, int idx, {required bool current}) {
    final m = item.media[idx];
    return Center(
      child: MediaImage(
        // 同一张图在「当前页/相邻页」之间必须保持同一个 key 和同一个解码宽度，
        // 否则翻页会当成另一张图重新解码 —— 这就是以前闪屏的来源。
        key: ValueKey('img:${item.tweetId}:$idx'),
        url: withImageVariant(m.url, 'small'),
        highResUrl: current ? withImageVariant(m.url, 'orig') : null,
        cache: widget.cache,
        tweetId: item.tweetId,
        idx: idx,
        fit: BoxFit.contain,
        cacheWidth: 1080,
        // 播放页是黑底：占位也要黑，否则图片没出来时整块是白的。
        darkFallback: true,
        preferRemembered: current,
      ),
    );
  }

  Widget _bottomScrim() => const IgnorePointer(
    child: DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          stops: [0.0, 0.45, 0.72, 1.0],
          colors: [
            Color(0x66000000),
            Color(0x00000000),
            Color(0xAA000000),
            Color(0xEE000000),
          ],
        ),
      ),
    ),
  );

  Widget _overlay(LikeItem item, bool hasVideo) {
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;

    return Stack(
      fit: StackFit.expand,
      children: [
        // 顶部：返回 + 提示
        Positioned(
          top: MediaQuery.viewPaddingOf(context).top + 4,
          left: 4,
          right: 4,
          child: AnimatedOpacity(
            opacity: _chromeVisible ? 1 : 0,
            duration: const Duration(milliseconds: 200),
            // AnimatedOpacity(0) 只是「不画」，命中测试照样生效 —— 按钮藏起来
            // 之后用户点左上角想暂停，会直接把播放页关掉。必须屏蔽。
            child: IgnorePointer(
              ignoring: !_chromeVisible,
              child: Row(
                children: [
                  IconButton(
                    onPressed: widget.onClose,
                    icon: const Icon(
                      Icons.arrow_back_ios_new,
                      size: 20,
                      color: Colors.white,
                    ),
                    tooltip: t('play.back'),
                  ),
                  const Spacer(),
                  if (widget.extraTopAction != null) widget.extraTopAction!,
                  // 右上角的画质按钮：显示当前档位（自动 / 高）和实际分辨率。
                  // 点开是「自动 + 低 320P + 中下 480P + …」，选了之后全局生效。
                  _qualityTopButton(),
                  IconButton(
                    tooltip: _landscape
                        ? t('play.rotateBack')
                        : t('play.rotate'),
                    onPressed: _toggleOrientation,
                    icon: Icon(
                      _landscape
                          ? Icons.stay_current_portrait
                          : Icons.stay_current_landscape,
                      size: 20,
                      color: Colors.white,
                    ),
                  ),
                  IconButton(
                    onPressed: _showMoreSheet,
                    icon: const Icon(Icons.more_horiz, color: Colors.white),
                  ),
                ],
              ),
            ),
          ),
        ),

        // 暂停标记：画面中间一个浅浅的播放图标，一眼就知道「是我按停了」，
        // 而不是卡住了。永远不吃点击（IgnorePointer），点它还是继续播放。
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedBuilder(
              animation: _handle,
              builder: (context, _) {
                final show = _handle.attached && !_handle.playing;
                return AnimatedOpacity(
                  opacity: show ? 1 : 0,
                  duration: const Duration(milliseconds: 160),
                  child: Center(
                    child: Icon(
                      Icons.play_arrow_rounded,
                      size: 92,
                      // 浅浅的：只做状态提示，不抢画面。
                      color: Colors.white.withValues(alpha: 0.32),
                    ),
                  ),
                );
              },
            ),
          ),
        ),

        // 画质提示：换档过程中「切换到 720p…」，升好后「画质 720p」。
        // 放在顶部栏下面，不挡画面中心，也不跟双击提示抢位置。
        Positioned(
          top: MediaQuery.viewPaddingOf(context).top + 48,
          right: 12,
          child: IgnorePointer(child: _qualityIndicator()),
        ),

        // 长按倍速徽标
        if (_boost)
          IgnorePointer(
            child: Align(
              alignment: const Alignment(0, -0.45),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.fast_forward_rounded,
                      color: Colors.white,
                      size: 18,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '${widget.settings.longPressSpeed}x',
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                    ),
                  ],
                ),
              ),
            ),
          ),

        // 双击快进/快退提示
        IgnorePointer(
          child: AnimatedOpacity(
            opacity: _hintFlash ? 1 : 0,
            duration: const Duration(milliseconds: 160),
            child: Align(
              alignment: Alignment.center,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Text(
                  _hint ?? '',
                  style: const TextStyle(color: Colors.white, fontSize: 15),
                ),
              ),
            ),
          ),
        ),

        // 右侧动作栏
        Positioned(
          right: 8,
          bottom: bottomInset + 108,
          child: AnimatedOpacity(
            opacity: _chromeVisible ? 1 : 0.0,
            duration: const Duration(milliseconds: 200),
            // 同上：藏起来的按钮不能还能点（点了就是「取消喜欢」确认框）。
            child: IgnorePointer(
              ignoring: !_chromeVisible,
              child: _swallowTap(_actionRail(item, hasVideo)),
            ),
          ),
        ),

        // 底部正文 + 进度
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: AnimatedOpacity(
            opacity: _chromeVisible ? 1 : 0,
            duration: const Duration(milliseconds: 200),
            child: IgnorePointer(
              ignoring: !_chromeVisible,
              child: _swallowTap(
                Padding(
                  padding: EdgeInsets.fromLTRB(14, 0, 76, bottomInset + 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 纯文字帖子的正文已经放大铺在画面上了，底部不再重复。
                      _caption(item, theme, showText: item.media.isNotEmpty),
                      if (hasVideo) ...[
                        const SizedBox(height: 10),
                        _progressBar(),
                      ],
                      // 多页时始终显示横线；当前页是视频的话上面还有进度条，
                      // 两者不冲突（一个说「第几页」，一个说「播到哪」）。
                      if (item.media.length > 1) ...[
                        const SizedBox(height: 8),
                        _imageIndicator(item.media.length),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),

        // 右下角：只看内容 / 显示界面
        Positioned(
          right: 10,
          bottom: bottomInset + 46,
          child: _immersiveButton(),
        ),
      ],
    );
  }

  /// 让一块界面**吃掉**落在它身上的点击。
  ///
  /// 界面层在手势层上面：有内容的地方（右侧动作栏、底部正文）自己把点击吃掉，
  /// 底下的「单击暂停」就收不到 —— 用户点喜欢/点作者/点展开正文时，
  /// 视频不会莫名其妙地停一下。空白处没有这层，点击自然落到手势层。
  Widget _swallowTap(Widget child) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {},
      child: child,
    );
  }

  /// 右下角那颗按钮：在「只看内容」与「显示界面」之间切换。
  ///
  /// 界面显隐**只有**这一个开关；沉浸状态下它自己也压暗但仍可点，
  /// 否则用户就没有出口了。
  Widget _immersiveButton() {
    return Opacity(
      opacity: widget.immersive ? 0.45 : 0.85,
      child: GestureDetector(
        onTap: () => widget.onImmersiveChanged(!widget.immersive),
        child: Container(
          width: 36,
          height: 36,
          decoration: const BoxDecoration(
            color: Colors.black45,
            shape: BoxShape.circle,
          ),
          child: Icon(
            widget.immersive
                ? Icons.visibility_outlined
                : Icons.visibility_off_outlined,
            color: Colors.white,
            size: 19,
          ),
        ),
      ),
    );
  }

  /// 顶部栏里的画质按钮：`自动 720P` / `高 1080P`。
  ///
  /// 只对「当前这屏是视频」有意义；图片时返回一个占位，保持顶部栏布局稳定。
  /// 低数据模式下画质是**锁死**的（缓存优先、否则最低档），所以按钮直接不显示。
  Widget _qualityTopButton() {
    if (_app.settings.lowDataMode) return const SizedBox(width: 4);
    final playable = _currentPlayable();
    if (playable == null) return const SizedBox(width: 4);
    return AnimatedBuilder(
      animation: _handle,
      builder: (context, _) {
        final opts = playable.opts;
        final tier = _tier;
        final manual = tier.isAuto ? null : opts.sourceForTier(tier);
        final playing = opts.sourceByKey(_handle.qualityKey);
        final res = (manual ?? playing)?.displayLabel;
        final text = res == null
            ? _tierLabel(tier)
            : '${_tierLabel(tier)} $res';
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => unawaited(_showQualitySheet()),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.hd_outlined, size: 14, color: Colors.white),
                  const SizedBox(width: 4),
                  Text(
                    text,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 右上角那一小块画质提示。
  ///
  /// 两个状态共用一个位置：
  /// - 换档进行中：小转圈 + 「切换到 720p…」—— 让用户知道「正在变清楚」，
  ///   而不是「卡了一下不知道在干嘛」；
  /// - 换好了：图标 + 「画质 720p」，1.8 秒后自动消失。
  Widget _qualityIndicator() {
    return AnimatedBuilder(
      animation: _handle,
      builder: (context, _) {
        final switching = _handle.switching && widget.active;
        final label = switching ? _handle.switchingLabel : _qualityToast;
        if (label == null || label.isEmpty) return const SizedBox.shrink();
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          child: Container(
            key: ValueKey('${switching ? 'w' : 'd'}:$label'),
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (switching)
                  const SizedBox(
                    width: 10,
                    height: 10,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.6,
                      color: Colors.white70,
                    ),
                  )
                else
                  const Icon(
                    Icons.hd_outlined,
                    size: 14,
                    color: Colors.white70,
                  ),
                const SizedBox(width: 5),
                Text(
                  switching
                      ? tf('play.qualitySwitching', {'q': label})
                      : tf('play.qualityNow', {'q': label}),
                  style: const TextStyle(color: Colors.white, fontSize: 11),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _actionRail(LikeItem item, bool hasVideo) {
    final author = item.author;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 头像 = 去 X 看这个人。原来这里会推到本地的「作者空间」，
        // 但真正想了解一个作者时还是 X 官方主页信息最全（简介/关注数/置顶）。
        //
        // 关注状态用「骑在头像底边的小对勾」表示：一半压在图上、一半露在图外。
        // 已关注才出现；未关注不显示任何字 —— 以前挂一行「关注」小字，
        // 既像按钮又不能点，反而误导。
        SizedBox(
          width: 48,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.topCenter,
            children: [
              GestureDetector(
                onTap: _openAuthor,
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 1.5),
                  ),
                  child: author?.avatarUrl == null
                      ? const CircleAvatar(
                          radius: 21,
                          backgroundColor: Colors.white24,
                          child: Icon(Icons.person, color: Colors.white),
                        )
                      : AuthorAvatar(
                          url: author!.avatarUrl!,
                          radius: 21,
                          cache: widget.cache,
                        ),
                ),
              ),
              if (_following)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: -8,
                  child: Center(
                    child: Container(
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        color: const Color(0xFF6CC7F5),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.black, width: 1.5),
                      ),
                      child: const Icon(
                        Icons.check,
                        size: 11,
                        color: Colors.black,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        // 徽标有一半露在头像外面，下面留够 8px 再放按钮。
        SizedBox(height: _following ? 16 : 12),
        _railButton(
          icon: _busyUnlike
              ? null
              : (_unliked.contains(item.tweetId)
                    ? Icons.favorite_border
                    : Icons.favorite),
          label: _unliked.contains(item.tweetId)
              ? t('play.like')
              : t('play.liked'),
          onTap: _toggleUnlike,
          busy: _busyUnlike,
          // 取消之后变空心、不再染红：一眼看出「再点一下就回来了」。
          accent: _unliked.contains(item.tweetId)
              ? Colors.white
              : const Color(0xFFFF2D55),
          big: true,
        ),
        const SizedBox(height: 14),
        _railButton(
          icon: _bookmarked ? Icons.bookmark : Icons.bookmark_border,
          label: _bookmarked ? t('play.bookmarked') : t('play.bookmark'),
          onTap: _toggleBookmark,
          busy: _busyBookmark,
          accent: _bookmarked ? const Color(0xFF6CC7F5) : Colors.white,
        ),
        const SizedBox(height: 14),
        _railButton(
          icon: Icons.open_in_new,
          label: t('play.openX'),
          onTap: () => launchUrl(
            Uri.parse('https://x.com/i/status/${item.tweetId}'),
            mode: LaunchMode.externalApplication,
          ),
        ),
      ],
    );
  }

  Widget _railButton({
    required IconData? icon,
    required String label,
    required VoidCallback onTap,
    bool busy = false,
    Color accent = Colors.white,
    bool big = false,
  }) {
    return GestureDetector(
      onTap: busy ? null : onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 30,
            height: big ? 32 : 28,
            child: busy
                ? const Center(
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    ),
                  )
                : Icon(icon, color: accent, size: big ? 30 : 25),
          ),
          const SizedBox(height: 3),
          Text(
            label,
            style: const TextStyle(color: Colors.white, fontSize: 10.5),
          ),
        ],
      ),
    );
  }

  Widget _caption(LikeItem item, ThemeData theme, {bool showText = true}) {
    final author = item.author;
    final text = item.text.trim();
    final long = text.length > 90 || '\n'.allMatches(text).length >= 3;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            // 主要展示「显示名」，@handle 作为次要信息跟在后面 ——
            // 和 X 自己的时间线一致，名字比 handle 更容易认人。
            if ((author?.name ?? '').isNotEmpty) ...[
              Flexible(
                child: Text(
                  author!.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 6),
            ],
            Flexible(
              child: Text(
                '@${author?.screenName ?? ''}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white54, fontSize: 12.5),
              ),
            ),
            if (item.createdAt != null) ...[
              const SizedBox(width: 8),
              Text(
                _date(item.createdAt!),
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ],
          ],
        ),
        if (showText && text.isNotEmpty) ...[
          const SizedBox(height: 6),
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            alignment: Alignment.bottomLeft,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: _textExpanded
                    ? MediaQuery.sizeOf(context).height * 0.46
                    : 76,
              ),
              child: SingleChildScrollView(
                physics: _textExpanded
                    ? const ClampingScrollPhysics()
                    : const NeverScrollableScrollPhysics(),
                child: GestureDetector(
                  onTap: long
                      ? () => setState(() => _textExpanded = !_textExpanded)
                      : null,
                  child: PostBody(
                    item: item,
                    maxLines: _textExpanded ? null : 2,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13.5,
                      height: 1.4,
                    ),
                    // 深色底上主题色偏暗，链接提亮一点才看得清。
                    linkStyle: const TextStyle(
                      color: Color(0xFF6CC7F5),
                      fontSize: 13.5,
                      height: 1.4,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (long)
            GestureDetector(
              onTap: () => setState(() => _textExpanded = !_textExpanded),
              child: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  _textExpanded ? t('play.collapse') : t('play.expand'),
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
        ],
      ],
    );
  }

  /// 底部进度条：视觉上还是抖音那种细线，但**按住可以拖动**。
  ///
  /// 拖动期间先暂停（否则画面会跟着 seek 一帧一帧跳），松手 seek 到位再恢复播放。
  /// 拖的时候时间文字跟着手指走，这样「拖到哪」有明确反馈。
  Widget _progressBar() {
    return AnimatedBuilder(
      animation: _handle,
      builder: (context, _) {
        final duration = _handle.duration;
        if (duration.inMilliseconds <= 0) return const SizedBox(height: 18);
        final total = duration.inMilliseconds;
        final posMs = _dragging ? _dragMs : _handle.position.inMilliseconds;
        final value = (posMs / total).clamp(0.0, 1.0);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: 24,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  activeTrackColor: Colors.white,
                  inactiveTrackColor: Colors.white24,
                  thumbColor: Colors.white,
                  thumbShape: RoundSliderThumbShape(
                    enabledThumbRadius: _dragging ? 7.5 : 4,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 14,
                  ),
                  overlayColor: Colors.white24,
                  // 细直条：默认的圆角轨道在 3px 高度上看着像胶囊，太抢戏。
                  trackShape: const RectangularSliderTrackShape(),
                  showValueIndicator: ShowValueIndicator.never,
                ),
                child: Slider(
                  value: value,
                  onChangeStart: _onSeekStart,
                  onChanged: (v) =>
                      setState(() => _dragMs = (v * total).round()),
                  onChangeEnd: (v) => _onSeekEnd(v, total),
                ),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '${_fmt(Duration(milliseconds: posMs))} / ${_fmt(duration)}',
              style: const TextStyle(color: Colors.white54, fontSize: 10.5),
            ),
          ],
        );
      },
    );
  }

  /// 多图的横线指示器（抖音式）：等宽短横线，当前那张亮、其余压低。
  ///
  /// 只做指示不做交互 —— 切换靠左右滑，横线太细不适合当点击目标（48dp 规则）。
  Widget _imageIndicator(int count) {
    return Row(
      children: [
        for (var i = 0; i < count; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            margin: const EdgeInsets.only(right: 4),
            width: 16,
            height: 3,
            decoration: BoxDecoration(
              color: i == _pageIndex ? Colors.white : Colors.white30,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        const SizedBox(width: 6),
        Text(
          '${_pageIndex + 1}/$count',
          style: const TextStyle(color: Colors.white54, fontSize: 10.5),
        ),
      ],
    );
  }

  void _onSeekStart(double v) {
    _tapTimer?.cancel();
    final total = _handle.duration.inMilliseconds;
    _wasPlayingBeforeSeek = _handle.playing;
    if (_wasPlayingBeforeSeek) _handle.pause();
    setState(() {
      _dragging = true;
      _dragMs = (v * total).round();
    });
  }

  Future<void> _onSeekEnd(double v, int total) async {
    await _handle.seekTo(Duration(milliseconds: (v * total).round()));
    if (!mounted) return;
    setState(() => _dragging = false);
    if (_wasPlayingBeforeSeek) _handle.resume();
  }

  /// 「更多」菜单：清晰度、循环、连续播放、作者、保存到相册。
  ///
  /// 这几项以前散在设置页里，但它们都是「当前这条」的即时选择 ——
  /// 想调一下还得退出播放页去翻设置，回来又得重新找到这一条。
  void _showMoreSheet() {
    final app = _app;
    const white = TextStyle(color: Colors.white);

    void savePlay(PlaybackSettings next) => app.setPlayback(next);

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF15181D),
      builder: (ctx) => SafeArea(
        child: StatefulBuilder(
          builder: (ctx, setLocal) {
            final play = app.settings.playback;
            return SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 循环 / 连续 / 关闭：一个按钮轮转三态。
                  // 拆成两个开关太像「设置」，而用户脑子里只有一个问题：
                  // 「播完怎么办」。
                  ListTile(
                    leading: Icon(
                      play.loop
                          ? Icons.repeat
                          : play.autoNext
                          ? Icons.skip_next
                          : Icons.pause_circle_outline,
                      color: Colors.white70,
                    ),
                    title: Text(
                      play.loop
                          ? t('play.modeLoop')
                          : play.autoNext
                          ? t('play.modeNext')
                          : t('play.modeOff'),
                      style: white,
                    ),
                    subtitle: Text(
                      t('play.modeHint'),
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 11,
                      ),
                    ),
                    trailing: const Icon(
                      Icons.swap_horiz,
                      size: 18,
                      color: Colors.white38,
                    ),
                    onTap: () {
                      final next = play.loop
                          ? play.copyWith(loop: false, autoNext: true)
                          : play.autoNext
                          ? play.copyWith(loop: false, autoNext: false)
                          : play.copyWith(loop: true, autoNext: false);
                      savePlay(next);
                      setLocal(() {});
                    },
                  ),
                  const Divider(height: 1, color: Colors.white12),
                  ListTile(
                    leading: const Icon(
                      Icons.photo_library_outlined,
                      color: Colors.white70,
                    ),
                    title: Text(t('play.saveToGallery'), style: white),
                    onTap: () {
                      Navigator.pop(ctx);
                      _saveToGallery();
                    },
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  /// 当前这一屏对应的可播放媒体（多图/多视频时优先当前页）。
  ({VideoQualityOptions opts, int idx})? _currentPlayable() {
    final media = widget.item.media;
    if (media.isEmpty) return null;
    var idx = _pageIndex.clamp(0, media.length - 1);
    if (!media[idx].isPlayable) {
      idx = media.indexWhere((m) => m.isPlayable);
      if (idx < 0) return null;
    }
    return (opts: VideoQualityOptions.of(media[idx]), idx: idx);
  }

  /// 画质选择面板。
  ///
  /// 直接列出 X 给的每一档（270p / 360p / 480p / 720p …），不再用「高/中/低」
  /// 三个抽象层：X 经常给 4 档，抽象层会白白丢掉一个，用户也没法精确选。
  /// 每一档后面标出码率和「已缓存」，这样「为什么这一档起得快」也是一目了然的。
  /// 档位名（低/中下/中/中上/高）。
  String _tierLabel(QualityTier tier) =>
      tier.isAuto ? t('play.qualityAuto') : t('quality.${tier.name}');

  /// 当前这条视频上的档位菜单（最多 5 档 + 自动）。
  ///
  /// 每一项标「档名 + 分辨率 P」，这样「高」到底是 720P 还是 1080P 一眼可见。
  /// 选中的档位会写进全局设置，其它视频也跟着走这一档。
  Future<void> _showQualitySheet() async {
    final playable = _currentPlayable();
    if (playable == null) return;
    final opts = playable.opts;
    final idx = playable.idx;
    final cachedKey = widget.cache?.cachedVariant(widget.item.tweetId, idx);
    final selected = await showModalBottomSheet<QualityTier>(
      context: context,
      backgroundColor: const Color(0xFF15181D),
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
                child: Row(
                  children: [
                    Text(
                      t('play.quality'),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    if (_handle.qualityLabel != null)
                      Text(
                        tf('play.qualityNow', {'q': _handle.qualityLabel!}),
                        style: const TextStyle(
                          color: Colors.white38,
                          fontSize: 11,
                        ),
                      ),
                  ],
                ),
              ),
              ListTile(
                dense: true,
                title: Text(
                  t('play.qualityAuto'),
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
                subtitle: Text(
                  t('play.qualityAutoHint'),
                  style: const TextStyle(color: Colors.white38, fontSize: 11),
                ),
                trailing: _tier.isAuto
                    ? const Icon(
                        Icons.check,
                        color: Color(0xFF6CC7F5),
                        size: 20,
                      )
                    : null,
                onTap: () => Navigator.pop(ctx, QualityTier.auto),
              ),
              for (final slot in opts.slots())
                ListTile(
                  dense: true,
                  title: Text(
                    '${_tierLabel(slot.tier)} ${slot.resolution}',
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  ),
                  subtitle: Text(
                    [
                      if (slot.source.bitRate > 0)
                        '${(slot.source.bitRate / 1000).round()} kbps',
                      if (cachedKey == slot.source.key) t('play.qualityLocal'),
                    ].join(' · '),
                    style: const TextStyle(color: Colors.white38, fontSize: 11),
                  ),
                  trailing: !_tier.isAuto && _tier == slot.tier
                      ? const Icon(
                          Icons.check,
                          color: Color(0xFF6CC7F5),
                          size: 20,
                        )
                      : null,
                  onTap: () => Navigator.pop(ctx, slot.tier),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
    if (selected == null || !mounted) return;
    if (selected == _tier) return;
    // 写进全局设置：**其它视频也跟着切**，不用每条都点一次。
    await _app.setPlayback(widget.settings.copyWith(qualityTier: selected));
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  String _date(DateTime d) {
    final local = d.toLocal();
    final now = DateTime.now();
    if (local.year == now.year) return '${local.month}/${local.day}';
    return '${local.year}/${local.month}/${local.day}';
  }
}

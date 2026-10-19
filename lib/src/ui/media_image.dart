/// 统一的图片渲染：本地缓存优先，其次 X 的 CDN。
///
/// 为什么单独一个 widget：
/// - 网格/详情/头像三处都要「有本地文件就用本地文件」，否则离线保存后仍然拉网；
/// - `Image.network` 的 `cacheWidth` + `FilterQuality.low` 能显著降低解码内存，
///   在 5 万条级别的浏览里这是主要的卡顿来源；
/// - CDN 偶发超时/403 时自动重试一次：视频封面这类图失败一次就永远空着，
///   用户看到的就是「加载不出来」。
///
/// ## 两段式画质（和视频同一套思路）
/// 先出小图，解码完再换上清晰图；小图是「马上有内容」，清晰图是「看清」。
/// 和以前不同的是**记得住**：清晰图解码成功过一次就写进媒体缓存
/// （`img:large` / `img:orig`），下次打开直接按那个档位请求，
/// 不再经历一次「先糊后清」。`preferRemembered` 用来关掉这个行为 ——
/// 列表里快速滚动时，先出小图的手感比「一进来就等大图」重要得多。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../media/media_cache.dart';

class MediaImage extends StatefulWidget {
  const MediaImage({
    super.key,
    required this.url,
    this.highResUrl,
    this.cache,
    this.tweetId,
    this.idx = 0,
    this.fit = BoxFit.cover,
    this.cacheWidth,
    this.alignment = Alignment.center,
    this.darkFallback = false,
    this.preferRemembered = false,
  });

  /// 先显示的地址（通常是 `name=small`）。
  final String url;

  /// 解码完成后再换上的清晰版本（`name=large`）。为空表示只显示 [url]，
  /// 此时也不会参与画质记忆（视频封面就是这种情况）。
  final String? highResUrl;

  /// 为空时退化成纯网络图片（测试环境就是这样）。
  final MediaCache? cache;
  final String? tweetId;
  final int idx;
  final BoxFit fit;
  final int? cacheWidth;
  final Alignment alignment;

  /// 占位色用黑而不是主题色。
  ///
  /// 播放页是黑底，主题色在浅色模式下接近白 —— 图片还没加载出来的那一下
  /// 会闪出一整块白，看起来就像「点开白屏」。
  final bool darkFallback;

  /// 记住过的高清档位直接用高清起播，跳过「先糊一下」。
  ///
  /// 全屏看图（一眼就要看清）打开它；列表里关掉 —— 滚动时首帧速度更重要。
  final bool preferRemembered;

  @override
  State<MediaImage> createState() => _MediaImageState();
}

class _MediaImageState extends State<MediaImage> {
  /// 最多自动重试几次。间隔递增（0.6s / 1.2s / 1.8s）。
  static const int _maxAttempts = 3;

  int _attempt = 0;
  bool _retryScheduled = false;
  Timer? _retryTimer;

  /// 小图已就位、清晰图也已解码 —— 换到清晰图。
  bool _showHighRes = false;
  bool _highResRequested = false;

  /// 见过的最清晰地址。**只增不减**。
  ///
  /// 播放页的多图轮播里，`highResUrl` 只给「当前页」传（省流量）：用户翻到
  /// 下一张后，上一张的参数会变成 `null`。若这里跟着丢，[build] 里
  /// `_showHighRes ? highResUrl! : url` 就会撞上 null 断言 —— 表现就是
  /// 「切到下一张，上一张变成一块灰」。记住地址后，上一张继续用自己的高清图，
  /// 既不闪也不崩。
  String? _highUrl;

  /// 一进来就直接用清晰图（记住过的情况）。
  bool _startedHigh = false;

  /// 已经在缓存里记过的档位，避免重复写。
  String? _recorded;

  @override
  void initState() {
    super.initState();
    _highUrl = widget.highResUrl;
    _startedHigh = _shouldStartHigh();
    if (_startedHigh) _showHighRes = true;
  }

  bool _shouldStartHigh() {
    if (!widget.preferRemembered) return false;
    final high = _highUrl;
    final cache = widget.cache;
    final id = widget.tweetId;
    if (high == null || cache == null || id == null) return false;
    final remembered = cache.bestVariant(id, widget.idx);
    if (remembered == null) return false;
    final rememberedRank = imageVariantRankFromKey(remembered);
    if (rememberedRank == null) return false;
    return rememberedRank >= imageVariantRank(_variantName(high));
  }

  @override
  void didUpdateWidget(covariant MediaImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      // 底图换了（真的是另一张图）：一切重来。
      _attempt = 0;
      _retryScheduled = false;
      _highResRequested = false;
      _startedHigh = _shouldStartHigh();
      _showHighRes = _startedHigh;
      _recorded = null;
      return;
    }
    if (oldWidget.highResUrl != widget.highResUrl) {
      // 只是「清晰版可用/不可用」变了（滑动切页时会这样）。
      //
      // 高清地址**只记住、不回退**：翻页后上一张会从「当前页」变成「相邻页」，
      // 调用方随之把 `highResUrl` 传成 null。这里若把地址丢掉，那张图要么退回
      // 小图闪一下，要么在 build 里撞上 null 断言变成灰块。
      if (widget.highResUrl != null) _highUrl = widget.highResUrl;
      if (widget.highResUrl == null) _highResRequested = false;
    }
  }

  /// 小图出来了，后台把清晰版也解码进 image cache，好了再换上。
  ///
  /// 用 `resolve` 而不是直接再渲染一个 `Image`：这样换的时候图片已经解码完毕，
  /// 不会出现「先闪一下灰块再清晰」。
  void _warmHighRes() {
    final high = _highUrl;
    if (_showHighRes || _highResRequested) return;
    if (high == null || high == widget.url) return;
    _highResRequested = true;

    final stream = NetworkImage(high).resolve(const ImageConfiguration());
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (_, _) {
        if (!mounted) return;
        _remember(_variantName(high));
        setState(() => _showHighRes = true);
        stream.removeListener(listener);
      },
      onError: (_, _) {
        // 清晰版拿不到就算了，小图继续显示。
        stream.removeListener(listener);
      },
    );
    stream.addListener(listener);
  }

  /// 记下「这条媒体显示过这一档」。
  void _remember(String variantName) {
    final cache = widget.cache;
    final id = widget.tweetId;
    if (cache == null || id == null) return;
    // 视频封面也会走这里，但它没有 highResUrl，档位记忆归播放器管。
    if (_highUrl == null) return;
    final key = imageVariantKey(variantName);
    if (_recorded == key) return;
    _recorded = key;
    cache.rememberVariant(id, widget.idx, key, imageVariantRank(variantName));
  }

  /// `https://pbs.twimg.com/media/x.jpg?name=large` → `large`。
  String _variantName(String url) {
    final q = Uri.tryParse(url)?.queryParameters['name'];
    if (q != null && q.isNotEmpty) return q;
    return 'large';
  }

  @override
  Widget build(BuildContext context) {
    Widget fallback(Widget child) => ColoredBox(
          color: widget.darkFallback
              ? Colors.black
              : Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Center(child: child),
        );

    // 只认图片缓存：视频位置缓存的是 mp4，拿它去 Image.file 会解不出来，
    // 于是「播放过的视频在列表里没有封面」。
    final local = (widget.cache != null && widget.tweetId != null)
        ? widget.cache!.cachedImageFile(widget.tweetId!, widget.idx)
        : null;
    if (local != null) {
      return Image.file(
        local,
        fit: widget.fit,
        alignment: widget.alignment,
        cacheWidth: widget.cacheWidth,
        filterQuality: FilterQuality.low,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) =>
            fallback(const Icon(Icons.broken_image_outlined)),
      );
    }

    // 用记住的地址，而不是 `widget.highResUrl!`：见 [_highUrl] 的注释。
    final url = (_showHighRes && _highUrl != null) ? _highUrl! : widget.url;
    if (_showHighRes) _remember(_variantName(url));

    // 带上登录态去要图。
    //
    // pbs.twimg.com 对普通图片是公开的，但**敏感内容的缩略图**在未认证时
    // 会返回一张灰色占位图 —— 状态码 200、没有报错，所以表现为「加载成功
    // 但永远是灰块」。加上 cookie 才拿到真正的缩略图。
    String? cookie;
    try {
      final session = AppScope.read(context).session;
      if (session != null) {
        cookie = 'auth_token=${session.authToken}; ct0=${session.ct0}';
      }
    } catch (_) {
      // 不在 AppScope 下（比如单独预览这个 widget）就按公开图处理。
    }

    return Image.network(
      url,
      // 重试/换清晰度时换 key，强制 Image 重新发起请求（否则它记住上次的失败）。
      key: ValueKey('$url#$_attempt'),
      headers: url.contains('twimg.com')
          ? {
              'Referer': 'https://x.com/',
              'cookie': ?cookie,
            }
          : null,
      fit: widget.fit,
      alignment: widget.alignment,
      cacheWidth: widget.cacheWidth,
      filterQuality: FilterQuality.low,
      // 换清晰图时保留上一帧，避免闪黑。
      gaplessPlayback: true,
      errorBuilder: (context, error, _) {
        debugPrint('[img] FAIL $url -> $error');
        // 到重试上限：给一个能点的刷新图标。用户常常是「当时没网」，
        // 后来有网了却因为失败结果被记住而一直空着。
        if (_attempt >= _maxAttempts) {
          return fallback(
            InkWell(
              onTap: () => setState(() {
                _attempt = 0;
                _retryScheduled = false;
              }),
              child: const Icon(Icons.refresh, size: 20),
            ),
          );
        }
        _scheduleRetry();
        return fallback(const Icon(Icons.broken_image_outlined));
      },
      loadingBuilder: (context, child, progress) {
        if (progress == null) {
          // 第一帧出来了：记录档位；如果当前还是小图，顺手预热清晰版。
          _remember(_variantName(url));
          if (!_showHighRes && !_highResRequested) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _warmHighRes();
            });
          }
          return child;
        }
        // 加载中给一个转圈：灰块什么都不显示时，用户分不清「在加载」还是「坏了」。
        return fallback(
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        );
      },
    );
  }

  /// 失败后补一次重试（最多 [_maxAttempts] 次，间隔递增）。
  ///
  /// 在 errorBuilder 里不能直接 setState（构建过程中），所以推到下一帧之后。
  /// 定时器要留着引用：列表滚走/页面关掉时必须能取消，否则会在已经 dispose 的
  /// State 上安排重建（测试里表现为「有没有结束的定时器」而整条失败）。
  void _scheduleRetry() {
    if (_retryScheduled || _attempt >= _maxAttempts) return;
    _retryScheduled = true;
    final delay = Duration(milliseconds: 600 * (_attempt + 1));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _retryTimer?.cancel();
      _retryTimer = Timer(delay, () {
        if (!mounted) return;
        setState(() {
          _attempt++;
          _retryScheduled = false;
        });
      });
    });
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    super.dispose();
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

/// 领域模型：一条「喜欢」以及它携带的媒体。
///
/// 这些类不依赖 Flutter，纯 Dart，方便单测。
library;

enum MediaKind { image, video, gif }

class MediaVariant {
  const MediaVariant({
    required this.url,
    required this.contentType,
    this.bitRate,
  });

  final String url;
  final String contentType;
  final int? bitRate;

  bool get isMp4 => contentType == 'video/mp4';
  bool get isHls =>
      contentType == 'application/x-mpegURL' ||
      contentType == 'application/vnd.apple.mpegurl';

  Map<String, Object?> toJson() => {
    'url': url,
    'contentType': contentType,
    if (bitRate != null) 'bitRate': bitRate,
  };

  factory MediaVariant.fromJson(Map<String, Object?> j) => MediaVariant(
    url: j['url'] as String? ?? '',
    contentType: j['contentType'] as String? ?? '',
    bitRate: (j['bitRate'] as num?)?.toInt(),
  );
}

class MediaItem {
  const MediaItem({
    required this.kind,
    required this.url,
    this.variants = const [],
    this.width,
    this.height,
    this.durationMs,
    this.altText,
  });

  final MediaKind kind;

  /// 图片的直链；视频则是封面图（poster）。
  final String url;
  final List<MediaVariant> variants;
  final int? width;
  final int? height;
  final int? durationMs;
  final String? altText;

  /// 播放/下载时优先用的地址：最佳 mp4，其次 HLS，最后回落到封面。
  String? get bestPlaybackUrl {
    final mp4s = variants.where((v) => v.isMp4).toList()
      ..sort((a, b) => (b.bitRate ?? 0).compareTo(a.bitRate ?? 0));
    if (mp4s.isNotEmpty) return mp4s.first.url;
    final hls = variants.where((v) => v.isHls).toList();
    if (hls.isNotEmpty) return hls.first.url;
    return null;
  }

  bool get isPlayable => kind != MediaKind.image && bestPlaybackUrl != null;

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'url': url,
    'variants': [for (final v in variants) v.toJson()],
    if (width != null) 'width': width,
    if (height != null) 'height': height,
    if (durationMs != null) 'durationMs': durationMs,
    if (altText != null) 'altText': altText,
  };

  factory MediaItem.fromJson(Map<String, Object?> j) => MediaItem(
    kind: MediaKind.values.firstWhere(
      (k) => k.name == j['kind'],
      orElse: () => MediaKind.image,
    ),
    url: j['url'] as String? ?? '',
    variants: [
      for (final v in (j['variants'] as List? ?? const []))
        MediaVariant.fromJson(Map<String, Object?>.from(v as Map)),
    ],
    width: (j['width'] as num?)?.toInt(),
    height: (j['height'] as num?)?.toInt(),
    durationMs: (j['durationMs'] as num?)?.toInt(),
    altText: j['altText'] as String?,
  );
}

class Author {
  const Author({
    required this.id,
    required this.screenName,
    required this.name,
    this.avatarUrl,
  });

  final String id;
  final String screenName;
  final String name;
  final String? avatarUrl;

  Map<String, Object?> toJson() => {
    'id': id,
    'screenName': screenName,
    'name': name,
    if (avatarUrl != null) 'avatarUrl': avatarUrl,
  };

  factory Author.fromJson(Map<String, Object?> j) => Author(
    id: j['id'] as String? ?? '',
    screenName: j['screenName'] as String? ?? '',
    name: j['name'] as String? ?? '',
    avatarUrl: j['avatarUrl'] as String?,
  );
}

/// 本地记录状态。
enum LikeState {
  /// 正常的喜欢条目。
  normal,

  /// 在 X 上被取消喜欢（本地已移除，一般不会留在库里）。
  removed,

  /// 推文被作者删除 / 账号受保护：保留本地记录与已缓存媒体，标「已删除」。
  deleted,
}

/// X **自带**的译文（服务端随喜欢列表一起下发）。
///
/// 关键点：它不是一个「翻译接口」，而是时间线里本来就带回来的字段
/// （`grok_translated_post_with_availability`），所以：
/// - **零额外请求**，不会因为翻译再打一次 X 的接口（少一分被限流的风险）；
/// - 它存在 `raw_json` 里，重新打开 App 也还在，不用重翻。
class PostTranslation {
  const PostTranslation({required this.text, this.sourceLang, this.destLang});

  final String text;

  /// 原文语言（`pt` / `en` / `ja` …）；X 没给就是 null。
  final String? sourceLang;

  /// X 翻成的语言（通常等于账号的语言设置）。
  final String? destLang;

  bool get isChinese => sourceLang == 'zh' || sourceLang == 'zh-cn';
}

class LikeItem {
  const LikeItem({
    required this.tweetId,
    required this.text,
    this.createdAt,
    this.lang,
    this.author,
    this.media = const [],
    this.sensitive = false,
    this.replyTo,
    this.quoteOf,
    this.retweetOf,
    this.state = LikeState.normal,
    this.feedRank,
    this.randKey,
    this.verifiedAt,
    this.raw,
  });

  final String tweetId;
  final String text;
  final DateTime? createdAt;
  final String? lang;
  final Author? author;
  final List<MediaItem> media;
  final bool sensitive;
  final String? replyTo;
  final String? quoteOf;
  final String? retweetOf;
  final LikeState state;

  /// 在「喜欢顺序」里的位置：0 = 最新喜欢的一条。由同步过程赋值。
  final int? feedRank;

  /// 随机模式用的稳定随机键（64 位，存 SQLite INTEGER）。
  final int? randKey;
  final DateTime? verifiedAt;

  /// X 返回的原始 JSON（保留，便于回溯字段与后续升级）。
  final Map<String, Object?>? raw;

  /// X 自带的译文（没有就是 null）。
  ///
  /// 直接从 [raw] 里取，不落新列：`raw_json` 本来就整条存着，重启后照样能读。
  PostTranslation? get translation {
    final r = raw;
    if (r == null) return null;
    var node = r['grok_translated_post_with_availability'];
    // 少数情况下再包一层 TweetWithVisibilityResults。
    final inner = r['tweet'];
    if (node == null && inner is Map) {
      node = inner['grok_translated_post_with_availability'];
    }
    if (node is! Map) return null;
    if (node['is_available'] == false) return null;
    final data = node['data'];
    if (data is! Map) return null;
    final text = data['translation'];
    if (text is! String || text.trim().isEmpty) return null;
    return PostTranslation(
      text: text,
      sourceLang: data['source_language'] as String?,
      destLang: data['destination_language'] as String?,
    );
  }

  bool get hasVideo => media.any((m) => m.kind != MediaKind.image);
  bool get hasImage => media.any((m) => m.kind == MediaKind.image);
  bool get hasGif => media.any((m) => m.kind == MediaKind.gif);

  /// 网格里用来做缩略图的第一张图。
  ///
  /// 库里存的是 `?name=large`（约 2048px、几百 KB）。网格格子只有 200~300dp，
  /// 直接拿 large 去铺一屏 60 张图就是几十 MB 流量 —— 这里换成 CDN 的
  /// `name=small`（约 680px、几十 KB），肉眼几乎无差别。
  String? get thumbnailUrl {
    if (media.isEmpty) return null;
    return withImageVariant(media.first.url, 'small');
  }

  /// 详情/放大浏览用的原图（`name=orig`）。
  String get fullImageUrl => withImageVariant(media.first.url, 'orig');

  LikeItem copyWith({
    LikeState? state,
    int? feedRank,
    int? randKey,
    DateTime? verifiedAt,
  }) => LikeItem(
    tweetId: tweetId,
    text: text,
    createdAt: createdAt,
    lang: lang,
    author: author,
    media: media,
    sensitive: sensitive,
    replyTo: replyTo,
    quoteOf: quoteOf,
    retweetOf: retweetOf,
    state: state ?? this.state,
    feedRank: feedRank ?? this.feedRank,
    randKey: randKey ?? this.randKey,
    verifiedAt: verifiedAt ?? this.verifiedAt,
    raw: raw,
  );
}

/// 改写 X 图片 URL 的尺寸档位（`name=small|medium|large|orig`）。
///
/// 没有 `name` 参数的 URL（比如本地缓存或测试里的假地址）原样返回。
String withImageVariant(String url, String name) {
  final uri = Uri.tryParse(url);
  if (uri == null) return url;
  // 只处理 X 的图片 CDN：本地文件路径、data: 之类原样返回。
  if (!uri.host.endsWith('twimg.com')) return url;
  // 关键：X 的 `media_url_https` **不带** `name`，以前这里只在参数已存在时
  // 才替换，于是列表一直在下载原图（几百 KB），表现就是「封面经常加载不出来」。
  // 现在主动补上，`small` 真的生效，列表快一个数量级。
  return uri
      .replace(queryParameters: {...uri.queryParameters, 'name': name})
      .toString();
}

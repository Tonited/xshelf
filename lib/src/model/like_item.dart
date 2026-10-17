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
      contentType == 'application/x-mpegURL' || contentType == 'application/vnd.apple.mpegurl';

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

  bool get hasVideo => media.any((m) => m.kind != MediaKind.image);
  bool get hasImage => media.any((m) => m.kind == MediaKind.image);
  bool get hasGif => media.any((m) => m.kind == MediaKind.gif);

  /// 网格里用来做缩略图的第一张图。
  String? get thumbnailUrl {
    if (media.isEmpty) return null;
    return media.first.url;
  }

  LikeItem copyWith({
    LikeState? state,
    int? feedRank,
    int? randKey,
    DateTime? verifiedAt,
  }) =>
      LikeItem(
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

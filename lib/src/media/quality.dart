/// 视频画质档位：把 X 返回的一堆 variant 整理成「低 → 高」的阶梯。
///
/// X 对同一条视频通常给 3~4 个 mp4（144p/360p/480p/720p 之类，码率递增）外加一个
/// HLS manifest。桌面网页端播放器就是先拿最低档秒开、再偷偷换成高档 —— 这里把
/// 这一步抽成纯函数，播放器只负责「换源并把进度接上」。
///
/// 纯 Dart，可单测。
library;

import '../model/like_item.dart';

/// 用户可选的画质档位。
///
/// 这里刻意**不用具体分辨率**：同一条视频 X 可能给 270p/360p/480p/720p，
/// 换一条可能只有 360p/720p。用户想要的是「清晰一点/省点流量」这种相对档位，
/// 所以存的是「从低往上的第几档」，换任何视频都能映射过去。
///
/// [auto] 才是默认：按网络情况自己爬，并且记住这条媒体看过的最好画质。
enum QualityTier {
  auto,
  low,
  mediumLow,
  medium,
  mediumHigh,
  high;

  String get key => name;

  /// 相对位置（0 = 最低档，1 = 最高档）。用来在档数不同的视频之间映射。
  double get fraction => switch (this) {
    QualityTier.auto => 0,
    QualityTier.low => 0,
    QualityTier.mediumLow => 0.25,
    QualityTier.medium => 0.5,
    QualityTier.mediumHigh => 0.75,
    QualityTier.high => 1,
  };

  bool get isAuto => this == QualityTier.auto;

  static QualityTier fromName(String? name) => QualityTier.values.firstWhere(
    (t) => t.name == name,
    orElse: () => QualityTier.auto,
  );
}

/// 老版本的档位枚举，只为兼容旧设置文件保留。
enum VideoQuality {
  auto,
  high,
  medium,
  low;

  String get key => name;

  static VideoQuality fromName(String? name) => VideoQuality.values.firstWhere(
    (q) => q.name == name,
    orElse: () => VideoQuality.auto,
  );
}

/// 菜单里的一档：抽象档位 + 这条视频上对应的具体地址。
class QualitySlot {
  const QualitySlot(this.tier, this.source);

  final QualityTier tier;
  final PlaybackSource source;

  /// 例如 `720P`。
  String get resolution => source.displayLabel;
}

/// 一个可播放的地址。
class PlaybackSource {
  const PlaybackSource({
    required this.url,
    required this.bitRate,
    this.height,
    this.isHls = false,
  });

  final String url;
  final int bitRate;

  /// 从 URL 里的 `480x270` 解析出的高度；解析不到为 null。
  final int? height;
  final bool isHls;

  /// 跨会话稳定的档位标识：用它记住「这条媒体看过的最好画质」。
  ///
  /// 不用 URL 当标识，是因为同一条视频的 URL 可能带不同的 `tag=` 参数；
  /// 也不用 label，因为「1080p」在两条视频里是两个不同的文件。
  String get key => '${height ?? 0}_$bitRate';

  /// 越大越清晰。码率是 X 真正给的排序依据，拿不到时才退回高度。
  int get rank => bitRate > 0 ? bitRate : (height ?? 0) * 1000;

  /// 画质菜单上的标签，例如 `720p` / `1.2 Mbps`。
  String get label {
    final h = height;
    if (h != null && h > 0) return '${h}p';
    if (bitRate > 0) return '${(bitRate / 1000).toStringAsFixed(0)}k';
    return isHls ? 'HLS' : 'auto';
  }

  /// 菜单里显示的分辨率：`720P`（用户说的「后面会显示画质的 P」）。
  String get displayLabel {
    final h = height;
    if (h != null && h > 0) return '${h}P';
    if (bitRate > 0) return '${(bitRate / 1000).toStringAsFixed(0)}K';
    return isHls ? 'HLS' : 'AUTO';
  }

  /// 界面上「有没有到高清」的粗判：>=720p 或 >=1.5 Mbps。
  bool get isHd => (height ?? 0) >= 720 || bitRate >= 1500000;

  Map<String, Object?> toJson() => {
    'url': url,
    'bitRate': bitRate,
    if (height != null) 'height': height,
    'isHls': isHls,
  };

  factory PlaybackSource.fromJson(Map<String, Object?> j) => PlaybackSource(
    url: j['url'] as String? ?? '',
    bitRate: (j['bitRate'] as num?)?.toInt() ?? 0,
    height: (j['height'] as num?)?.toInt(),
    isHls: j['isHls'] == true,
  );
}

/// 一条视频的画质阶梯（低 → 高）。
class VideoQualityOptions {
  const VideoQualityOptions(this.sources);

  /// 按码率/分辨率从低到高排列；至少 1 项（没有可播地址时为空）。
  final List<PlaybackSource> sources;

  static const VideoQualityOptions empty = VideoQualityOptions([]);

  /// 单变体视频（X 上很常见）没有可切的东西 —— UI 里就不该出现画质菜单。
  bool get isSwitchable => sources.length >= 2;

  bool get isEmpty => sources.isEmpty;

  PlaybackSource? pick(VideoQuality q) {
    if (sources.isEmpty) return null;
    switch (q) {
      case VideoQuality.low:
        return sources.first;
      case VideoQuality.high:
        return sources.last;
      case VideoQuality.medium:
        if (sources.length == 1) return sources.first;
        return sources[(sources.length - 1) ~/ 2];
      case VideoQuality.auto:
        return sources.last;
    }
  }

  /// 自动模式下的起播档：最低档，保证「秒开」。
  PlaybackSource? get fastest => sources.isEmpty ? null : sources.first;

  /// 自动模式下的目标档：最高档。
  PlaybackSource? get best => sources.isEmpty ? null : sources.last;

  /// 除 [current] 之外的最高档（已经是最高的就返回 null）。
  PlaybackSource? upgradeFrom(PlaybackSource current) {
    if (sources.length < 2) return null;
    final best = sources.last;
    return best.url == current.url ? null : best;
  }

  /// 按 [key] 找回档位（记住的画质跨会话用）。
  PlaybackSource? sourceByKey(String? key) {
    if (key == null || key.isEmpty) return null;
    for (final s in sources) {
      if (s.key == key) return s;
    }
    return null;
  }

  /// 比 [current] 高的档里最接近的一档；已经最高返回 null。
  ///
  /// 用来「一级一级往上爬」：直接从 270p 跳 1080p 会因为要重新缓冲一大段而卡一下，
  /// 一档一档升的每一次都更短、更不容易被用户察觉。
  PlaybackSource? nextAbove(PlaybackSource? current) {
    if (current == null) return best;
    for (final s in sources) {
      if (s.rank > current.rank) return s;
    }
    return null;
  }

  /// 菜单用的档位列表（高 → 低），同一个文件只出现一次。
  List<PlaybackSource> get menuSources {
    final seen = <String>{};
    final out = <PlaybackSource>[];
    for (final s in sources.reversed) {
      if (seen.add(s.key)) out.add(s);
    }
    return out.toList(growable: false);
  }

  /// 档位菜单（低 → 高），最多 [max] 档。
  ///
  /// 「最多也就六个画质切换」：加上「自动」一共 6 行，所以这里最多 5 档。
  /// 变体比 5 个多时**均匀抽稀**（保留最低、最高和中间几个），而不是把菜单
  /// 拉成一长条 —— 6 个 1080p 变体对用户没有意义，它们只差码率。
  List<QualitySlot> slots({int max = 5}) {
    if (sources.isEmpty) return const [];
    final distinct = <PlaybackSource>[];
    final seen = <String>{};
    for (final s in sources) {
      if (seen.add(s.key)) distinct.add(s);
    }
    final total = distinct.length;
    if (total <= max) {
      final tiers = _tierNames(total);
      return [
        for (var i = 0; i < total; i++) QualitySlot(tiers[i], distinct[i]),
      ];
    }
    // 抽稀：i/(max-1) 映射到 0..total-1，去重后档名按实际条数分配。
    final picked = <PlaybackSource>[];
    for (var i = 0; i < max; i++) {
      final idx = ((total - 1) * (i / (max - 1))).round();
      final src = distinct[idx];
      if (picked.isEmpty || picked.last.key != src.key) picked.add(src);
    }
    final tiers = _tierNames(picked.length);
    return [
      for (var i = 0; i < picked.length; i++) QualitySlot(tiers[i], picked[i]),
    ];
  }

  /// 抽象档位 → 这条视频上的具体地址。
  PlaybackSource? sourceForTier(QualityTier tier) {
    if (tier == QualityTier.auto) return best;
    final list = slots();
    if (list.isEmpty) return best;
    for (final slot in list) {
      if (slot.tier == tier) return slot.source;
    }
    // 兜底（档位数少于一共有 5 档）按相对位置取。
    final idx = (tier.fraction * (sources.length - 1)).round().clamp(
      0,
      sources.length - 1,
    );
    return sources[idx];
  }

  /// 档名：按档数取「低 / 中下 / 中 / 中上 / 高」。
  static List<QualityTier> _tierNames(int count) => switch (count) {
    0 => const [],
    1 => const [QualityTier.medium],
    2 => const [QualityTier.low, QualityTier.high],
    3 => const [QualityTier.low, QualityTier.medium, QualityTier.high],
    4 => const [
      QualityTier.low,
      QualityTier.mediumLow,
      QualityTier.mediumHigh,
      QualityTier.high,
    ],
    _ => const [
      QualityTier.low,
      QualityTier.mediumLow,
      QualityTier.medium,
      QualityTier.mediumHigh,
      QualityTier.high,
    ],
  };

  static VideoQualityOptions of(MediaItem media) {
    final mp4 = <PlaybackSource>[];
    PlaybackSource? hls;

    for (final v in media.variants) {
      final url = v.url;
      if (url.isEmpty) continue;
      if (v.isMp4) {
        mp4.add(
          PlaybackSource(
            url: url,
            bitRate: v.bitRate ?? 0,
            height: _heightOf(url),
          ),
        );
      } else if (v.isHls) {
        hls ??= PlaybackSource(url: url, bitRate: 0, isHls: true);
      }
    }

    // 同一分辨率只留码率最高的那个（X 偶尔给两个编码变体）。
    mp4.sort((a, b) {
      final ah = a.height ?? 0;
      final bh = b.height ?? 0;
      if (ah != bh) return ah.compareTo(bh);
      return a.bitRate.compareTo(b.bitRate);
    });
    final deduped = <PlaybackSource>[];
    for (final s in mp4) {
      final h = s.height;
      if (h == null || h <= 0) {
        deduped.add(s);
        continue;
      }
      final sameHeight = deduped.indexWhere((x) => x.height == h);
      if (sameHeight < 0) {
        deduped.add(s);
      } else if (s.bitRate > deduped[sameHeight].bitRate) {
        deduped[sameHeight] = s;
      }
    }

    if (deduped.isNotEmpty) return VideoQualityOptions(deduped);
    if (hls != null) return VideoQualityOptions([hls]);
    // 兜底：variants 里没有 mp4/HLS 但模型认为可播（老数据）。
    final best = media.bestPlaybackUrl;
    if (best != null) {
      return VideoQualityOptions([PlaybackSource(url: best, bitRate: 0)]);
    }
    return empty;
  }
}

/// 从 `.../480x270/abc.mp4` 里抠出档位高度。
///
/// 取的是**短边**：竖屏视频的 URL 是 `720x1280`，它其实就是大家嘴里的「720p」，
/// 直接拿第二个数字会显示成 `1280P`，看着像比 1080p 还清楚。
int? _heightOf(String url) {
  final m = RegExp(r'/(\d{2,4})x(\d{2,4})/').firstMatch(url);
  if (m == null) return null;
  final a = int.tryParse(m.group(1) ?? '');
  final b = int.tryParse(m.group(2) ?? '');
  if (a == null || b == null) return null;
  final h = a < b ? a : b;
  if (h < 64 || h > 4320) return null;
  return h;
}

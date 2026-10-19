/// 把「结构化条件」拼成 X 搜索语法（也就是 `rawQuery`）。
///
/// 为什么需要这一层：X 对**写错的操作符不报错**，只会静默返回不相干的结果。
/// 用户看到的是「搜不到」，而不是「你写错了」。把常用操作符做成字段，就能在本地
/// 拦掉全角冒号、空值、值里带空格这些低级错误 —— 这比多支持三个冷门操作符更能
/// 提升「搜索能力」的体感。
///
/// 纯 Dart，可单测。
library;

/// 媒体类型筛选。这几个 filter 在 X 侧取交集，同给两个会搜出空集，
/// 所以用 enum 而不是 bitmask。
enum SearchMediaFilter {
  any,
  media,
  images,
  videos,
  nativeVideo;

  static SearchMediaFilter fromName(String? name) =>
      SearchMediaFilter.values.firstWhere(
        (v) => v.name == name,
        orElse: () => SearchMediaFilter.any,
      );
}

class XSearchQuery {
  const XSearchQuery({
    this.text,
    this.from,
    this.to,
    this.since,
    this.until,
    this.lang,
    this.minFaves,
    this.minRetweets,
    this.minReplies,
    this.media = SearchMediaFilter.any,
    this.excludeReplies = false,
    this.excludeRetweets = false,
    this.excludeLinks = false,
    this.verifiedOnly = false,
    this.hashtags = const [],
    this.anyOf = const [],
    this.noneOf = const [],
  });

  final String? text;
  final String? from;
  final String? to;

  /// `yyyy-MM-dd`（或带时分秒的 `yyyy-MM-dd_HH:mm:ss_UTC`），原样拼进去。
  final String? since;
  final String? until;
  final String? lang;
  final int? minFaves;
  final int? minRetweets;
  final int? minReplies;
  final SearchMediaFilter media;
  final bool excludeReplies;
  final bool excludeRetweets;
  final bool excludeLinks;
  final bool verifiedOnly;
  final List<String> hashtags;

  /// `OR` 组：命中任意一个即可（X 的 `OR` 必须大写）。
  final List<String> anyOf;

  /// 排除词。
  final List<String> noneOf;

  /// 是否没有任何有效条件。
  ///
  /// 直接由 [build] 推导，而不是再手写一遍字段清单 —— 之前手写时漏了
  /// `excludeReplies` / `excludeRetweets` / `excludeLinks` / `verifiedOnly`，
  /// 结果是「搜索框为空 + 只勾了排除回复」时 `isEmpty` 为 true，
  /// 调用方（搜索页）就把这条查询整个丢掉了。
  bool get isEmpty => build().trim().isEmpty;

  XSearchQuery copyWith({
    String? text,
    String? from,
    String? to,
    String? since,
    String? until,
    String? lang,
    int? minFaves,
    int? minRetweets,
    int? minReplies,
    SearchMediaFilter? media,
    bool? excludeReplies,
    bool? excludeRetweets,
    bool? excludeLinks,
    bool? verifiedOnly,
    List<String>? hashtags,
    List<String>? anyOf,
    List<String>? noneOf,
    bool clearFrom = false,
    bool clearTo = false,
    bool clearSince = false,
    bool clearUntil = false,
    bool clearLang = false,
    bool clearMinFaves = false,
    bool clearMinRetweets = false,
    bool clearMinReplies = false,
  }) =>
      XSearchQuery(
        text: text ?? this.text,
        from: clearFrom ? null : (from ?? this.from),
        to: clearTo ? null : (to ?? this.to),
        since: clearSince ? null : (since ?? this.since),
        until: clearUntil ? null : (until ?? this.until),
        lang: clearLang ? null : (lang ?? this.lang),
        minFaves: clearMinFaves ? null : (minFaves ?? this.minFaves),
        minRetweets:
            clearMinRetweets ? null : (minRetweets ?? this.minRetweets),
        minReplies: clearMinReplies ? null : (minReplies ?? this.minReplies),
        media: media ?? this.media,
        excludeReplies: excludeReplies ?? this.excludeReplies,
        excludeRetweets: excludeRetweets ?? this.excludeRetweets,
        excludeLinks: excludeLinks ?? this.excludeLinks,
        verifiedOnly: verifiedOnly ?? this.verifiedOnly,
        hashtags: hashtags ?? this.hashtags,
        anyOf: anyOf ?? this.anyOf,
        noneOf: noneOf ?? this.noneOf,
      );

  /// 拼成 `rawQuery`。空条件返回空串，由调用方拦下（X 不接受空查询）。
  String build() {
    final parts = <String>[];

    if (text != null && text!.trim().isNotEmpty) parts.add(_phrase(text!));

    // `from:` / `to:` 里的 @ 可写可不写，统一去掉，避免出现 `from:@@a`。
    if (from != null && from!.trim().isNotEmpty) {
      parts.add('from:${_bare(from!)}');
    }
    if (to != null && to!.trim().isNotEmpty) {
      parts.add('to:${_bare(to!)}');
    }

    if (since != null && since!.trim().isNotEmpty) {
      parts.add('since:${_dateValue(since!)}');
    }
    if (until != null && until!.trim().isNotEmpty) {
      parts.add('until:${_dateValue(until!)}');
    }

    switch (media) {
      case SearchMediaFilter.any:
        break;
      case SearchMediaFilter.media:
        parts.add('filter:media');
      case SearchMediaFilter.images:
        parts.add('filter:images');
      case SearchMediaFilter.videos:
        parts.add('filter:videos');
      case SearchMediaFilter.nativeVideo:
        parts.add('filter:native_video');
    }

    // 排除项一律用 `-filter:`：`exclude:links` 只是它的别名，
    // 取反形式在冷门操作符上更通用。
    if (excludeReplies) parts.add('-filter:replies');
    if (excludeRetweets) parts.add('-filter:retweets');
    if (excludeLinks) parts.add('-filter:links');
    if (verifiedOnly) parts.add('filter:verified');

    // `-min_faves:100` 是「点赞数**不超过** 100」，不是「至少」。这里只暴露下限，
    // 避免用户在 UI 上填了负数还以为有 bug。
    if (minFaves != null && minFaves! > 0) parts.add('min_faves:$minFaves');
    if (minRetweets != null && minRetweets! > 0) {
      parts.add('min_retweets:$minRetweets');
    }
    if (minReplies != null && minReplies! > 0) {
      parts.add('min_replies:$minReplies');
    }

    for (final t in hashtags) {
      final v = _bare(t).replaceFirst(RegExp(r'^#'), '');
      if (v.isNotEmpty) parts.add('#$v');
    }

    // 过滤掉空白项：`( )` 这种畸形表达式 X 不报错，只会默默返回不相干的结果，
    // 正是这一层要拦掉的低级错误。
    final orTerms = anyOf.map(_phrase).where((s) => s.isNotEmpty).toList();
    if (orTerms.isNotEmpty) {
      // `OR` 必须大写，且整体加括号，否则会跟前面的条件混成畸形表达式。
      parts.add('(${orTerms.join(' OR ')})');
    }
    if (lang != null && lang!.trim().isNotEmpty) {
      parts.add('lang:${_bare(lang!)}');
    }
    for (final n in noneOf) {
      final v = _phrase(n);
      if (v.isNotEmpty) parts.add('-$v');
    }

    return parts.join(' ');
  }

  /// 值里含空格/引号时必须加引号，否则会被拆成「隐式 AND」。
  static String _phrase(String raw) {
    final v = _normalize(raw);
    if (v.isEmpty) return '';
    final needsQuote =
        v.contains(' ') || v.contains(':') || v.contains('(') || v.contains(')');
    if (!needsQuote) return v;
    // 引号内的引号会把查询语法打断，直接剥掉而不是转义（X 不认反斜杠转义）。
    return '"${v.replaceAll('"', '')}"';
  }

  /// 操作符冒号后的值：不能有空格/冒号，否则 X 会当成别的东西。
  ///
  /// `from:` / `to:` 里的 `@` 一律去掉 —— X 两种写法都认，但拼出 `from:@@a`
  /// 就什么都不返回，而且不报错。
  static String _bare(String raw) {
    final v = _normalize(raw);
    return v.replaceAll(RegExp('[\\s:@"\']'), '');
  }

  /// 时间值：`2024-01-01` 或 `2024-01-01_00:00:00_UTC`。
  ///
  /// 这里**必须保留冒号**（精到秒的写法里有），只去掉空格和引号。
  static String _dateValue(String raw) {
    final v = _normalize(raw);
    return v.replaceAll(RegExp(r'[\s"]'), '');
  }

  /// 全角 → 半角。中文输入法下 `from：user` 是极高频的手误。
  static String _normalize(String raw) => raw
      .trim()
      .replaceAll('：', ':')
      .replaceAll('＃', '#')
      .replaceAll('＄', r'$')
      .replaceAll('（', '(')
      .replaceAll('）', ')');
}

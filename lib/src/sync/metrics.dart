/// 一条推文的互动数据（回复 / 转发 / 喜欢 / 引用 / 浏览）。
///
/// ## 数据从哪来（这一版的重点）
/// 以前是「现拉」：走 v1.1 `statuses/lookup.json`。X 已经把 v1.1 那批公开端点
/// 整个下线了（`account/verify_credentials` 返回 404 `code 34`，`users/show`
/// 直接吃 Cloudflare 挑战页），于是这条路径变成 **请求 → 404 → 整行不显示**，
/// 用户看到的就是「互动数据打不开」。
///
/// 现在改成**用同步时就带回来的数字**：Likes 的 GraphQL 响应里每条推文自带
/// `legacy.reply_count / retweet_count / favorite_count / quote_count`（还有
/// `bookmark_count`），而我们本来就把整条 JSON 存进了 `raw_json`。所以这里
/// 只是把它解析出来 —— 零请求、零限流风险、离线也有数字。
///
/// 代价是「数字停在最后一次同步」。对一个「我的喜欢归档」来说可以接受：
/// 这里的推文大多是天到年前喜欢的，数字本来就不太再动；卡片上的数字是
/// 「值不值得点进去」的参考，不是实时看板。想要最准的数字，点进 X 看。
library;

import 'package:flutter/foundation.dart';

import '../model/like_item.dart';

class TweetMetrics {
  const TweetMetrics({
    this.replies,
    this.retweets,
    this.likes,
    this.quotes,
    this.bookmarks,
    this.views,
  });

  final int? replies;
  final int? retweets;
  final int? likes;
  final int? quotes;
  final int? bookmarks;

  /// 浏览量。只有部分推文带，拿不到就是 null。
  final int? views;

  bool get isEmpty =>
      replies == null &&
      retweets == null &&
      likes == null &&
      quotes == null &&
      bookmarks == null &&
      views == null;

  /// 「热度」：优先用浏览量；没有就用 喜欢 + 转发 + 引用 的加权和估一个。
  ///
  /// 只是个排序/直观参考，所以宁可给个估算值，也不留空。
  int? get heat {
    if (views != null) return views;
    if (likes == null && retweets == null && quotes == null) return null;
    return (likes ?? 0) + (retweets ?? 0) * 2 + (quotes ?? 0) * 2;
  }

  /// 从 `raw_json` 里抠出互动数据（字段名按 X 的 GraphQL 结构来）。
  static TweetMetrics? fromRaw(Map<String, Object?>? raw) {
    if (raw == null) return null;
    // 被限制可见的推文会多包一层 TweetWithVisibilityResults。
    final tweet = raw['tweet'] is Map
        ? Map<String, Object?>.from(raw['tweet'] as Map)
        : raw;
    final legacy = tweet['legacy'];
    final l = legacy is Map ? legacy : tweet;
    final views =
        _intOf(tweet['views']) ??
        _intOf(tweet['ext_views']) ??
        _intOf(tweet['view_count_info']);
    final m = TweetMetrics(
      replies: _intOf(l['reply_count']),
      retweets: _intOf(l['retweet_count']),
      likes: _intOf(l['favorite_count']),
      quotes: _intOf(l['quote_count']),
      bookmarks: _intOf(l['bookmark_count']),
      views: views,
    );
    return m.isEmpty ? null : m;
  }

  /// 数字在 X 的响应里有时是 int、有时是字符串、有时包在 `{count: …}` 里。
  static int? _intOf(Object? v) {
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    if (v is Map) {
      for (final key in const ['count', 'value', 'total']) {
        final inner = _intOf(v[key]);
        if (inner != null) return inner;
      }
    }
    return null;
  }
}

/// 互动数据的内存快照表。
///
/// 不落库（新加两列不值当，而且这些数字是随 `raw_json` 一起进来的）；
/// 首次用到某条推文时解析一次并记住，5 万条也只是每张卡片一次 Map 取值。
class MetricsStore extends ChangeNotifier {
  final Map<String, TweetMetrics?> _cache = {};

  TweetMetrics? operator [](String tweetId) => _cache[tweetId];

  /// 取这条推文的互动数据（第一次访问时从 [LikeItem.raw] 解析）。
  TweetMetrics? of(LikeItem item) {
    final id = item.tweetId;
    if (_cache.containsKey(id)) return _cache[id];
    final m = TweetMetrics.fromRaw(item.raw);
    _cache[id] = m;
    return m;
  }

  /// 换了账号/退出登录时清空。
  void clear() {
    _cache.clear();
    notifyListeners();
  }
}

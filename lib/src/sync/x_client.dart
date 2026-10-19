/// X 网页端 GraphQL 客户端（非官方接口）。
///
/// 设计要点：
/// - 只依赖 `package:http`，方便替换代理客户端；
/// - queryId 运行时发现 + 内存缓存（X 改版后多数情况能自愈）；
/// - 错误分类（会话失效 / 限流 / 接口变更），让 UI 能给出可执行的提示。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'likes_parser.dart';
import 'metrics.dart';
import 'search_parser.dart';

/// 公开的 web Bearer（X 网页端硬编码在 JS 里，非个人凭证）。
const String kWebBearer =
    'AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA';

const String kWebUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36';

/// 需要记 queryId 的 GraphQL 操作（缓存到本地，失效时自动重发现）。
const List<String> kQueryIdOperations = [
  'Viewer',
  'Likes',
  'UnfavoriteTweet',
  'Friendships/Create',
  'Friendships/Destroy',
  'SearchTimeline',
];

/// 同一操作可以有多个候选 queryId，按「最近一次实测」排序。
///
/// 为什么搜索要多个：`SearchTimeline` 的 queryId 比 `Likes` 换得更勤（它的操作
/// 定义被打进懒加载 chunk，发版时更容易连带变动），而且几个开源实现的实测值
/// 互不相同。只有一个兜底值时，值一过期用户就只能等发版；有候选列表就能在
/// **一次会话内**自动退到下一个。
const Map<String, List<String>> kFallbackQueryIdCandidates = {
  'SearchTimeline': [
    'hyPfJYJ_XAtDYoslQc-Rgg',
    'mjP9fB_MpScfXblKwpTDBg',
    'flaR-PUMshxFWZWPNpq4zA',
  ],
};

/// 内置兜底的 queryId（2026-10 实测有效）。
///
/// 为什么要内置：X 首页 HTML 现在会被 Cloudflare 拦（直接请求返回 403
/// 「Just a moment...」），我们「抓首页 → 解析 JS bundle → 正则找 queryId」
/// 的自动发现通道基本走不通。没有兜底时，全新安装会因为发现失败而完全
/// 用不了。发现成功时仍以内置值为准、并以发现值覆盖。
///
/// 这些值随 X 前端发版会变；变了就更新这里（或在 app 里点重新发现）。
const Map<String, String> kFallbackQueryIds = {
  'Viewer': 'TpQxQtWMTMnIAMPlMGMqNw',
  'Likes': 'mu4us66Q6RRNOywVQhGtRg',
  'UnfavoriteTweet': 'ZYKSe-w7KEslx3JhSIk5LA',
  'UserByScreenName': 'AMIBMjtxEEATh4z8V9GtRg',
};

class XSession {
  const XSession({
    required this.authToken,
    required this.ct0,
    required this.userId,
    this.screenName,
    this.displayName,
    this.avatarUrl,
  });

  final String authToken;
  final String ct0;
  final String userId;
  final String? screenName;
  final String? displayName;
  final String? avatarUrl;

  String get cookieHeader => 'auth_token=$authToken; ct0=$ct0';

  XSession copyWith({
    String? screenName,
    String? displayName,
    String? avatarUrl,
  }) =>
      XSession(
        authToken: authToken,
        ct0: ct0,
        userId: userId,
        screenName: screenName ?? this.screenName,
        displayName: displayName ?? this.displayName,
        avatarUrl: avatarUrl ?? this.avatarUrl,
      );

  XSession copyWithId(String newId) => XSession(
        authToken: authToken,
        ct0: ct0,
        userId: newId,
        screenName: screenName,
        displayName: displayName,
        avatarUrl: avatarUrl,
      );

  Map<String, Object?> toJson() => {
        'authToken': authToken,
        'ct0': ct0,
        'userId': userId,
        if (screenName != null) 'screenName': screenName,
        if (displayName != null) 'displayName': displayName,
        if (avatarUrl != null) 'avatarUrl': avatarUrl,
      };

  factory XSession.fromJson(Map<String, Object?> j) => XSession(
        authToken: j['authToken'] as String? ?? '',
        ct0: j['ct0'] as String? ?? '',
        userId: j['userId'] as String? ?? '',
        screenName: j['screenName'] as String?,
        displayName: j['displayName'] as String?,
        avatarUrl: j['avatarUrl'] as String?,
      );
}

enum XErrorKind {
  /// cookie 失效 / 被登出
  sessionExpired,

  /// 429 或触发风控
  rateLimited,

  /// 接口结构变了（queryId 失效、features 变更）
  apiChanged,

  /// 网络/代理问题
  network,

  /// 其他
  unknown,
}

class XRequestException implements Exception {
  XRequestException(this.kind, this.message, {this.status, this.resetAt});

  final XErrorKind kind;
  final String message;
  final int? status;
  final DateTime? resetAt;

  @override
  String toString() => 'XRequestException($kind, $status): $message';
}

/// 解析 cookie 字符串（浏览器复制来的 `auth_token=..; ct0=..`）。
/// 缺失的字段返回 null。
({String? authToken, String? ct0, String? userId}) parseCookieString(String raw) {
  final map = <String, String>{};
  for (final part in raw.split(';')) {
    final idx = part.indexOf('=');
    if (idx <= 0) continue;
    map[part.substring(0, idx).trim()] = part.substring(idx + 1).trim();
  }
  final twid = map['twid'] ?? '';
  final decoded = Uri.decodeComponent(twid);
  String? userId;
  final m = RegExp(r'u%3D(\d+)|u=(\d+)').firstMatch(twid) ??
      RegExp(r'^u=(\d+)$').firstMatch(decoded);
  if (m != null) userId = m.group(1) ?? m.group(2);
  return (
    authToken: map['auth_token'],
    ct0: map['ct0'],
    userId: userId,
  );
}

class XClient {
  XClient({
    required this.session,
    required this.httpClient,
    Map<String, String> presetQueryIds = const {},
    this.onQueryId,
    this.onQueryIdInvalid,
  }) {
    _queryIds.addAll(presetQueryIds);
  }

  final XSession session;
  final http.Client httpClient;

  /// 预置的 queryId（来自本地缓存或测试）；发现成功后会通过 [onQueryId] 回写。
  final Map<String, String> _queryIds = {};

  /// 每个操作已经用到第几个候选（SearchTimeline 这类操作发现不到，只能靠候选轮换）。
  final Map<String, int> _candidateCursor = {};

  /// 本次运行里已经确认「抓首页找 JS」拿不到的操作。
  ///
  /// 不记的话，每次 `_queryId` 调用都会先白花一个请求去撞 Cloudflare 403，
  /// 搜索翻页时会非常明显。
  final Set<String> _undiscoverable = {};

  /// 发现到新的 queryId 时回调（落库，下次启动直接用）。
  final void Function(String operation, String queryId)? onQueryId;

  /// 缓存的 queryId 失效时回调（清库，下次重新抓 JS）。
  final void Function(String operation)? onQueryIdInvalid;

  Map<String, String> get _baseHeaders => {
        'authorization': 'Bearer $kWebBearer',
        'x-csrf-token': session.ct0,
        'x-twitter-auth-type': 'OAuth2Session',
        'x-twitter-active-user': 'yes',
        'x-twitter-client-language': 'en',
        'content-type': 'application/json',
        'accept': '*/*',
        'accept-language': 'en-US,en;q=0.9',
        'referer': 'https://x.com/',
        'user-agent': kWebUserAgent,
        'cookie': session.cookieHeader,
      };

  /// 校验登录态并补全账号信息。
  ///
  /// 以前用 `i/api/1.1/account/verify_credentials.json`，X 已经把这个 v1.1
  /// 端点整个下线了（返回 404 code 34），继续用会让「明明登录成功」变成
  /// 「登录失败」。现在改用网页端自己的 GraphQL `Viewer`：它返回当前会话的
  /// 完整账号信息，X 前端自己也靠它渲染自己的头像/昵称。
  Future<XSession> verify() async {
    final qid = await _queryId('Viewer');
    final uri = Uri.https('x.com', '/i/api/graphql/$qid/Viewer', {
      'variables': jsonEncode(const <String, Object?>{}),
      'features': jsonEncode(kLikesFeatures),
    });
    final body = await _get(uri);
    final viewer = _digPath(body, const ['data', 'viewer']);
    final user = _digPath(viewer, const ['user_results', 'result']);
    if (user is! Map) {
      // 200 但没有 viewer：cookie 无效（被登出）而不是接口坏了。
      throw XRequestException(
        XErrorKind.sessionExpired,
        '登录态无效：X 没有返回当前账号，请重新登录',
        status: 200,
      );
    }
    final id = user['rest_id'] as String? ?? session.userId;
    final core = user['core'];
    final legacy = user['legacy'];
    String? pick(String key) =>
        (core is Map ? core[key] as String? : null) ??
        (legacy is Map ? legacy[key] as String? : null);
    final avatar = (user['avatar'] is Map
            ? (user['avatar'] as Map)['image_url'] as String?
            : null) ??
        pick('profile_image_url_https');
    return session
        .copyWith(
          screenName: pick('screen_name'),
          displayName: pick('name'),
          avatarUrl: avatar?.replaceAll('_normal', '_bigger'),
        )
        .copyWithId(id);
  }

  /// 拉一页喜欢。
  Future<LikesPage> fetchLikes({String? cursor, int count = 100}) =>
      _withQueryIdRecovery('Likes', () => _fetchLikesOnce(cursor: cursor, count: count));

  Future<LikesPage> _fetchLikesOnce({String? cursor, int count = 100}) async {
    final qid = await _queryId('Likes');
    final variables = <String, Object?>{
      'userId': session.userId,
      'count': count,
      'includePromotedContent': false,
      'withClientEventToken': false,
      'withBirdwatchNotes': false,
      'withVoice': false,
      'withV2Timeline': true,
      if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
    };
    final uri = Uri.https('x.com', '/i/api/graphql/$qid/Likes', {
      'variables': jsonEncode(variables),
      'features': jsonEncode(kLikesFeatures),
      'fieldToggles': jsonEncode(const {'withArticlePlainText': false}),
    });

    final body = await _get(uri);
    return parseLikesPageInBackground(body);
  }

  /// 在 X 上搜索内容（语料是**全网**推文，不是本地已同步的喜欢）。
  ///
  /// [rawQuery] 原样传给服务端，因此支持 X 的全部搜索操作符
  /// （`from:` / `since:` / `filter:media` / `min_faves:` / `OR` …）。
  /// 需要「拼查询」时用 `XSearchQuery`，别让用户手打整串 —— X 对写错的操作符
  /// 不报错，只会静默返回不相干结果。
  Future<SearchResultPage> fetchSearch({
    required String rawQuery,
    SearchProduct product = SearchProduct.latest,
    String? cursor,
    int count = 20,
  }) {
    final q = rawQuery.trim();
    if (q.isEmpty) {
      throw XRequestException(XErrorKind.unknown, '搜索词不能为空');
    }
    return _withQueryIdRecovery(
      'SearchTimeline',
      () => _fetchSearchOnce(q, product, cursor, count),
    );
  }

  Future<SearchResultPage> _fetchSearchOnce(
    String rawQuery,
    SearchProduct product,
    String? cursor,
    int count,
  ) async {
    final qid = await _queryId('SearchTimeline');

    final variables = <String, Object?>{
      'rawQuery': rawQuery,
      // 搜索的分页粒度由服务端固定（20 左右），给更大不会多返，别学 Likes 用 100。
      'count': count,
      'product': product.wireName,
      // 网页端就是这个 camelCase 写法（`query_source` 是更早的变体）。
      'querySource': 'typed_query',
      if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
    };

    final uri = Uri.https('x.com', '/i/api/graphql/$qid/SearchTimeline', {
      'variables': jsonEncode(variables),
      'features': jsonEncode(kSearchFeatures),
      // 搜索的 fieldToggles 与 Likes 不同：它要的是 rich content state。
      'fieldToggles': jsonEncode(const {'withArticleRichContentState': true}),
    });

    final body = await _get(uri);

    // 语法层面的拒绝（如 code 220 / "Query is empty"）也是 200 + errors，
    // 但它不是 queryId 失效：若判成 apiChanged，_withQueryIdRecovery 会白白
    // 丢掉一个还能用的 queryId，还多花一次「抓首页找 JS」的请求。
    final errors = graphqlErrors(body);
    if (errors.isNotEmpty && body is Map && body['data'] == null) {
      final message = errors.join('; ');
      final looksLikeQueryProblem =
          message.toLowerCase().contains('query') ||
              message.toLowerCase().contains('invalid');
      throw XRequestException(
        looksLikeQueryProblem ? XErrorKind.unknown : XErrorKind.apiChanged,
        looksLikeQueryProblem ? '查询有问题：$message' : message,
      );
    }

    return parseSearchPageInBackground(body);
  }

  /// 取消喜欢。
  Future<void> unlike(String tweetId) =>
      _withQueryIdRecovery('UnfavoriteTweet', () => _unlikeOnce(tweetId));

  /// 重新喜欢（取消之后又点回来）。
  Future<void> like(String tweetId) =>
      _withQueryIdRecovery('FavoriteTweet', () => _likeOnce(tweetId));

  Future<void> _likeOnce(String tweetId) async {
    final qid = await _queryId('FavoriteTweet');
    final uri = Uri.https('x.com', '/i/api/graphql/$qid/FavoriteTweet');
    final payload = jsonEncode({
      'variables': {'tweet_id': tweetId},
      'queryId': qid,
    });
    final body = await _post(uri, payload);
    final errors = graphqlErrors(body);
    if (errors.isNotEmpty) {
      throw XRequestException(XErrorKind.unknown, errors.join('; '));
    }
  }

  Future<void> _unlikeOnce(String tweetId) async {
    final qid = await _queryId('UnfavoriteTweet');
    final uri = Uri.https('x.com', '/i/api/graphql/$qid/UnfavoriteTweet');
    final payload = jsonEncode({
      'variables': {'tweet_id': tweetId},
      'queryId': qid,
    });
    final body = await _post(uri, payload);
    final errors = graphqlErrors(body);
    if (errors.isNotEmpty) {
      throw XRequestException(XErrorKind.unknown, errors.join('; '));
    }
  }

  /// 查「我是否关注了这个作者」。
  ///
  /// 本地 kv 只记我们自己在 App 里的操作；用户在 X 网页/客户端里关注的人
  /// 我们并不知道，所以进作者页时要向 X 核对一次。任何失败都返回 null，
  /// 由调用方退回本地记录 —— 这个查询不该让页面打不开。
  Future<bool?> isFollowing(String screenName) async {
    if (screenName.isEmpty) return null;
    try {
      return await _withQueryIdRecovery<bool?>('UserByScreenName', () async {
        final qid = await _queryId('UserByScreenName');
        final uri = Uri.https('x.com', '/i/api/graphql/$qid/UserByScreenName', {
          'variables': jsonEncode({
            'screen_name': screenName,
            'withSafetyModeUserFields': true,
          }),
          'features': jsonEncode(kLikesFeatures),
          'fieldToggles': jsonEncode(const {'withAuxiliaryUserLabels': false}),
        });
        final body = await _get(uri);
        final value = _digPath(body, [
          'data',
          'user',
          'result',
          'relationship_perspectives',
          'following',
        ]);
        return value is bool ? value : null;
      });
    } catch (_) {
      return null;
    }
  }

  /// 关注 / 取关一个作者。
  ///
  /// 走 **v1.1 REST**（`friendships/create|destroy.json`），不走 GraphQL。
  ///
  /// 原来用 GraphQL 的 `Friendships/Create|Destroy`，这两个 mutation 也要求
  /// transaction-id 签名，queryId 发现一失败就整条挂掉 —— 用户看到的就是
  /// 「无法取消关注」。v1.1 这两个端点只要 csrf + cookie，稳得多。
  Future<void> follow(String userId) => _friendship(userId, create: true);

  Future<void> unfollow(String userId) => _friendship(userId, create: false);

  Future<void> _friendship(String userId, {required bool create}) async {
    if (userId.isEmpty) {
      throw XRequestException(XErrorKind.unknown, '作者 id 为空，无法关注');
    }
    final uri = Uri.https(
      'x.com',
      '/i/api/1.1/friendships/${create ? 'create' : 'destroy'}.json',
    );
    final body = await _postForm(uri, {'user_id': userId});
    if (body is! Map) {
      throw XRequestException(XErrorKind.unknown, '关注接口返回异常');
    }
    final errors = body['errors'];
    if (errors is List && errors.isNotEmpty) {
      final first = errors.first;
      final message =
          first is Map ? (first['message'] as String? ?? '$first') : '$first';
      throw XRequestException(XErrorKind.unknown, message);
    }
  }

  /// 批量取互动数据（回复/转发/喜欢/引用/浏览）。
  ///
  /// **已废弃，不要在 UI 里接回来**：走的是 v1.1 `statuses/lookup.json`，而 X 把
  /// v1.1 那批公开端点整个下线了（`account/verify_credentials` → 404 `code 34`，
  /// `users/show` → Cloudflare 挑战页），这条路径现在只会 404 然后整行不显示。
  /// 互动数据改用 `raw_json` 里同步时带回来的快照，见 `sync/metrics.dart`。
  /// 留着这个函数只是因为它结构清楚，哪天 X 恢复 v1.1 可以原地接回来。
  Future<Map<String, TweetMetrics>> fetchMetrics(List<String> ids) async {
    final out = <String, TweetMetrics>{};
    if (ids.isEmpty) return out;

    for (var i = 0; i < ids.length; i += 100) {
      final chunk = ids.sublist(
        i,
        i + 100 > ids.length ? ids.length : i + 100,
      );
      final uri = Uri.https('x.com', '/i/api/1.1/statuses/lookup.json', {
        'id': chunk.join(','),
        'include_entities': 'false',
        'trim_user': 'true',
        'map': 'true',
      });
      final Object? body;
      try {
        body = await _get(uri);
      } catch (_) {
        continue;
      }
      if (body is! Map) continue;

      // map=true 时返回 {id: tweet}，否则是数组；两种都兼容。
      final entries = <Map>[];
      if (body['id_str'] is Map || body['id'] is Map) {
        final m = (body['id_str'] ?? body['id']) as Map;
        entries.addAll(m.values.whereType<Map>());
      } else if (body['errors'] != null && body['errors'] is List) {
        continue;
      } else {
        entries.addAll(body.values.whereType<Map>());
      }

      for (final tw in entries) {
        final id = tw['id_str'] as String?;
        if (id == null) continue;
        final views = tw['ext_views'];
        out[id] = TweetMetrics(
          replies: _asInt(tw['reply_count']),
          retweets: _asInt(tw['retweet_count']),
          likes: _asInt(tw['favorite_count']),
          quotes: _asInt(tw['quote_count']),
          views: views is Map ? _asInt(views['count']) : null,
        );
      }
    }
    return out;
  }

  static int? _asInt(Object? v) => v is num ? v.toInt() : null;

  /// 当前登录账号的 screen_name（v1.1 `verify_credentials`）。
  Future<String?> currentScreenName() async {
    try {
      final body = await _get(
        Uri.https('x.com', '/i/api/1.1/account/verify_credentials.json'),
      );
      if (body is Map) return body['screen_name'] as String?;
    } catch (_) {}
    return null;
  }

  /// 我正在关注的人。
  ///
  /// 走 v1.1 `friends/list`：GraphQL 那条 `Following` 同样死在签名上。
  /// 拿不到就返回空列表，调用方回退到本地记录，不阻塞页面。
  Future<List<({String id, String screenName, String name})>> fetchFollowing({
    int limit = 1000,
  }) async {
    final me = await currentScreenName();
    if (me == null) return const [];

    final out = <({String id, String screenName, String name})>[];
    String? cursor;
    var guard = 0;
    while (out.length < limit && guard++ < 30) {
      final params = <String, String>{
        'screen_name': me,
        'count': '200',
        'skip_status': 'true',
        'include_user_entities': 'false',
        'cursor': ?cursor,
      };
      final Object? body;
      try {
        body = await _get(
          Uri.https('x.com', '/i/api/1.1/friends/list.json', params),
        );
      } catch (_) {
        break;
      }
      if (body is! Map) break;
      final users = body['users'];
      if (users is! List) break;
      for (final u in users) {
        if (u is! Map) continue;
        final sn = u['screen_name'] as String?;
        if (sn == null || sn.isEmpty) continue;
        out.add((
          id: u['id_str'] as String? ?? '',
          screenName: sn,
          name: u['name'] as String? ?? sn,
        ));
      }
      final next = body['next_cursor_str'] as String?;
      if (next == null || next.isEmpty || next == '0') break;
      cursor = next;
    }
    return out;
  }

  /// 缓存的 queryId 会随 X 前端发版失效（表现是 400/404）。  ///
  /// 这种失败是**可自愈**的：丢掉旧值、重新发现一次再试，用户完全无感。
  /// 以前只有「本次运行内」的缓存，重启后又得去抓 JS。
  Future<T> _withQueryIdRecovery<T>(
      String operation, Future<T> Function() run) async {
    try {
      return await run();
    } on XRequestException catch (e) {
      if (e.kind != XErrorKind.apiChanged || !_queryIds.containsKey(operation)) {
        rethrow;
      }
      _queryIds.remove(operation);
      onQueryIdInvalid?.call(operation);
      return run();
    }
  }

  Future<Object?> _get(Uri uri) async {
    final resp = await _send(() => httpClient.get(uri, headers: _baseHeaders));
    return _decode(resp);
  }

  Future<Object?> _post(Uri uri, String payload) async {
    final resp =
        await _send(() => httpClient.post(uri, headers: _baseHeaders, body: payload));
    return _decode(resp);
  }

  /// 表单 POST（v1.1 REST 端点用）。
  Future<Object?> _postForm(Uri uri, Map<String, String> fields) async {
    final encoded = fields.entries
        .map((e) =>
            '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    final resp = await _send(() => httpClient.post(
          uri,
          headers: {
            ..._baseHeaders,
            'content-type': 'application/x-www-form-urlencoded',
          },
          body: encoded,
        ));
    return _decode(resp);
  }

  /// 请求超时。以前完全没有超时：一条半死的连接能把回填永久挂住，
  /// 表现是「卡住不动」而不是报错，比失败更难排查。
  static const Duration _requestTimeout = Duration(seconds: 30);

  Future<http.Response> _send(Future<http.Response> Function() run) async {
    try {
      return await run().timeout(_requestTimeout);
    } on TimeoutException {
      throw XRequestException(XErrorKind.network, '请求超时，请检查代理');
    } catch (e) {
      throw XRequestException(XErrorKind.network, '网络请求失败：$e');
    }
  }

  Object? _decode(http.Response resp) {
    final code = resp.statusCode;
    if (code == 401 || code == 403) {
      throw XRequestException(
        XErrorKind.sessionExpired,
        '登录态失效或被风控（HTTP $code），请重新登录',
        status: code,
      );
    }
    if (code == 429) {
      final reset = int.tryParse(resp.headers['x-rate-limit-reset'] ?? '');
      throw XRequestException(
        XErrorKind.rateLimited,
        '请求过于频繁，被限流',
        status: code,
        resetAt: reset == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(reset * 1000, isUtc: true),
      );
    }
    if (code == 404 || code == 400) {
      final body = _tryJson(resp.body);
      final errors = body == null ? const <String>[] : graphqlErrors(body);
      throw XRequestException(
        XErrorKind.apiChanged,
        errors.isEmpty
            ? '接口返回 HTTP $code（queryId 可能已失效）'
            : errors.join('; '),
        status: code,
      );
    }
    if (code >= 500) {
      throw XRequestException(XErrorKind.unknown, 'X 服务端错误 HTTP $code',
          status: code);
    }
    final json = _tryJson(resp.body);
    if (json == null) {
      throw XRequestException(
        XErrorKind.apiChanged,
        '响应不是 JSON（HTTP $code），可能被登录墙拦截',
        status: code,
      );
    }
    return json;
  }

  Object? _tryJson(String body) {
    try {
      return jsonDecode(body);
    } catch (_) {
      return null;
    }
  }

  /// 取操作的 queryId：内存/本地缓存 → 从 x.com 前端 JS 抓 → 内置兜底候选。
  ///
  /// 顺序上仍然「先发现」：发现成功就拿最新的，X 改了前端也能自愈。
  /// 但首页现在经常被 Cloudflare 挡掉（403），发现会失败 —— 这时用
  /// [kFallbackQueryIdCandidates] / [kFallbackQueryIds] 里的实测值，保证全新安装
  /// 也能出数据；候选表被判定失效后会自动退到下一个，而不是让用户等发版。
  Future<String> _queryId(String operation) async {
    final cached = _queryIds[operation];
    if (cached != null && cached.isNotEmpty) return cached;

    String? discovered;
    if (!_undiscoverable.contains(operation)) {
      try {
        discovered = await _discoverQueryId(operation);
      } catch (_) {
        discovered = null;
      }
      // 发现失败就记下来：本次运行别再白花请求撞 Cloudflare。
      if (discovered == null || discovered.isEmpty) {
        _undiscoverable.add(operation);
      }
    }
    if (discovered != null && discovered.isNotEmpty) {
      _queryIds[operation] = discovered;
      onQueryId?.call(operation, discovered);
      return discovered;
    }

    // 候选列表：失效过几次就往后取几个。
    final candidates = kFallbackQueryIdCandidates[operation];
    if (candidates != null && candidates.isNotEmpty) {
      final idx = (_candidateCursor[operation] ?? 0) % candidates.length;
      _candidateCursor[operation] = idx + 1;
      final pick = candidates[idx];
      _queryIds[operation] = pick;
      return pick;
    }

    final fallback = kFallbackQueryIds[operation];
    if (fallback != null) {
      _queryIds[operation] = fallback;
      return fallback;
    }

    throw XRequestException(
      XErrorKind.apiChanged,
      '无法发现 $operation 的 queryId，X 前端可能已改版，请更新应用',
    );
  }

  /// 抓 x.com 首页 → 找出所有 client-web JS → 正则搜 queryId。
  Future<String?> _discoverQueryId(String operation) async {
    final home = await _send(() => httpClient.get(
          Uri.parse('https://x.com/'),
          headers: const {'user-agent': kWebUserAgent},
        ));
    if (home.statusCode != 200) return null;

    final scripts = <String>{};
    final jsUrlRe =
        RegExp('https://abs\\.twimg\\.com/responsive-web/client-web[^"\'\\s]+\\.js');
    for (final m in jsUrlRe.allMatches(home.body)) {
      scripts.add(m.group(0)!);
    }
    // 首页 HTML 里通常能看到 main.<hash>.js；再多拿几个兜底。
    if (scripts.isEmpty) return null;

    final patterns = <RegExp>[
      RegExp('queryId:"([A-Za-z0-9_-]{10,})"[^}]{0,400}?operationName:"$operation"'),
      RegExp('operationName:"$operation"[^}]{0,400}?queryId:"([A-Za-z0-9_-]{10,})"'),
    ];

    for (final url in scripts.take(12)) {
      try {
        final js = await _send(() => httpClient.get(Uri.parse(url),
            headers: const {'user-agent': kWebUserAgent}));
        if (js.statusCode != 200) continue;
        for (final p in patterns) {
          final m = p.firstMatch(js.body);
          if (m != null) return m.group(1);
        }
      } catch (_) {
        continue;
      }
    }
    return null;
  }
}

/// 按路径取嵌套 map / list 里的值（任一层缺失都返回 null）。
Object? _digPath(Object? root, List<String> path) {
  Object? cur = root;
  for (final key in path) {
    if (cur is Map) {
      cur = cur[key];
    } else if (cur is List) {
      final i = int.tryParse(key);
      cur = (i != null && i >= 0 && i < cur.length) ? cur[i] : null;
    } else {
      return null;
    }
  }
  return cur;
}

/// Likes 操作需要的 features 开关。
/// X 会不定期加开关；缺失一般只是少几个字段，多给一个未知开关则可能直接 400。
/// 因此这里保持保守：核心开关 + 常用可选。
const Map<String, Object?> kLikesFeatures = {
  'rweb_video_screen_enabled': false,
  'payments_enabled': false,
  'profile_label_improvements_pcf_label_in_post_enabled': true,
  'rweb_tipjar_consumption_enabled': true,
  'verified_phone_label_enabled': false,
  'creator_subscriptions_tweet_preview_api_enabled': true,
  'responsive_web_graphql_timeline_navigation_enabled': true,
  'responsive_web_graphql_skip_user_profile_image_extensions_enabled': false,
  'premium_content_api_read_enabled': false,
  'communities_web_enable_tweet_community_results_fetch': true,
  'c9s_tweet_anatomy_moderator_badge_enabled': true,
  'articles_preview_enabled': true,
  'responsive_web_edit_tweet_api_enabled': true,
  'graphql_is_translatable_rweb_tweet_is_translatable_enabled': true,
  'view_counts_everywhere_api_enabled': true,
  'longform_notetweets_consumption_enabled': true,
  'responsive_web_twitter_article_tweet_consumption_enabled': true,
  'tweet_awards_web_tipping_enabled': false,
  'creator_subscriptions_quote_tweet_preview_enabled': false,
  'freedom_of_speech_not_reach_fetch_enabled': true,
  'standardized_nudges_misinfo': true,
  'tweet_with_visibility_results_prefer_gql_limited_actions_policy_enabled': true,
  'longform_notetweets_rich_text_read_enabled': true,
  'longform_notetweets_inline_media_enabled': true,
  'responsive_web_enhance_cards_enabled': false,
};

/// 搜索用的 features：直接沿用 Likes 的基线，再补几项。
///
/// 为什么不另起一份：两边要的是同一批「推文字段」开关（长推文、媒体、可见性
/// 包装），各自维护的结果是迟早有一边忘了同步，表现为「搜索出来的正文被截断」。
/// 多给未知开关有 400 风险，所以这里只加实测不会被拒的少数几项。
const Map<String, Object?> kSearchFeatures = {
  ...kLikesFeatures,
  // 搜索结果卡片要完整的 card 结构，否则新闻/文章类结果会缺卡片。
  'responsive_web_profile_redirect_enabled': true,
  // `$cashtag` 需要它才会在 entities 里给出 cashtag。
  'rweb_cashtags_enabled': true,
};



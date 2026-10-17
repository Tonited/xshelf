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

/// 公开的 web Bearer（X 网页端硬编码在 JS 里，非个人凭证）。
const String kWebBearer =
    'AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA';

const String kWebUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36';

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
    this.presetQueryIds = const {},
  });

  final XSession session;
  final http.Client httpClient;

  /// 预置的 queryId（测试用；线上靠 [_discoverQueryId] 发现）。
  final Map<String, String> presetQueryIds;

  final Map<String, String> _queryIds = {};

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

  /// 校验登录态并补全账号信息（v1.1 verify_credentials，网页端仍在用）。
  Future<XSession> verify() async {
    final uri = Uri.parse(
        'https://x.com/i/api/1.1/account/verify_credentials.json?skip_status=true&include_entities=false');
    final body = await _get(uri);
    if (body is! Map) {
      throw XRequestException(XErrorKind.apiChanged, '账号信息响应格式异常');
    }
    final id = body['id_str'] as String? ?? session.userId;
    return session.copyWith(
      screenName: body['screen_name'] as String?,
      displayName: body['name'] as String?,
      avatarUrl: (body['profile_image_url_https'] as String?)
          ?.replaceAll('_normal', '_bigger'),
    ).copyWithId(id);
  }

  /// 拉一页喜欢。
  Future<LikesPage> fetchLikes({String? cursor, int count = 100}) async {
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
    return parseLikesPage(body);
  }

  /// 取消喜欢。
  Future<void> unlike(String tweetId) async {
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

  Future<Object?> _get(Uri uri) async {
    final resp = await _send(() => httpClient.get(uri, headers: _baseHeaders));
    return _decode(resp);
  }

  Future<Object?> _post(Uri uri, String payload) async {
    final resp =
        await _send(() => httpClient.post(uri, headers: _baseHeaders, body: payload));
    return _decode(resp);
  }

  Future<http.Response> _send(Future<http.Response> Function() run) async {
    try {
      return await run();
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

  /// 取操作的 queryId：预置 → 内存缓存 → 从 x.com 前端 JS 抓。
  Future<String> _queryId(String operation) async {
    final preset = presetQueryIds[operation];
    if (preset != null && preset.isNotEmpty) return preset;

    final cached = _queryIds[operation];
    if (cached != null) return cached;

    final discovered = await _discoverQueryId(operation);
    if (discovered == null) {
      throw XRequestException(
        XErrorKind.apiChanged,
        '无法发现 $operation 的 queryId，X 前端可能已改版，请更新应用',
      );
    }
    _queryIds[operation] = discovered;
    return discovered;
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

/// Likes 操作需要的 features 开关。
///
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



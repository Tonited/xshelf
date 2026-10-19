/// 翻译：把正文/搜索词翻成指定语言。
///
/// ## 为什么是「多家兜底」而不是接一个官方 API
/// X / 百度 / 有道 的正规接口都要注册 key 或签名，而这个 App 是纯本地的个人工具，
/// 不想让用户先去申请一堆凭证。所以这里串几家**公开、免费、不需要 key** 的入口，
/// 谁先成功用谁：
/// 1. **MyMemory** —— 实测最稳，国内也能直连；
/// 2. **Google 翻译的 gtx 入口** —— 质量最好，国内要梯子；
/// 3. **百度翻译的 transapi 老入口** —— 国内直连最顺，但它有反爬，
///    请求头不像浏览器时会回 `errno: 1022`（所以放在最后兜底）。
///
/// 三家都失败才报错 —— 用户看到的是「翻译失败」，而不是一个空框。
///
/// ## 缓存
/// 结果按「语言 + 原文」缓存在内存里：列表里滚动、来回切「原文/译文」都不会
/// 重新发请求。翻译是有配额的东西，能不请求就不请求。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// 一个可选的目标语言。
class TranslateLanguage {
  const TranslateLanguage(
    this.code,
    this.zhName,
    this.enName, {
    required this.baidu,
    required this.myMemory,
  });

  /// 应用内统一用这个短码（`zh` / `en` / `ja` …）。
  final String code;
  final String zhName;
  final String enName;

  /// 百度那边的写法（`jp` / `kor` …，它不用 ISO 码）。
  final String baidu;

  /// MyMemory 要 region 后缀（`zh-CN` / `ja-JP` …）。
  final String myMemory;

  static const List<TranslateLanguage> all = [
    TranslateLanguage('zh', '中文', 'Chinese', baidu: 'zh', myMemory: 'zh-CN'),
    TranslateLanguage('en', '英文', 'English', baidu: 'en', myMemory: 'en'),
    TranslateLanguage('ja', '日文', 'Japanese', baidu: 'jp', myMemory: 'ja-JP'),
    TranslateLanguage('ko', '韩文', 'Korean', baidu: 'kor', myMemory: 'ko-KR'),
    TranslateLanguage('fr', '法文', 'French', baidu: 'fra', myMemory: 'fr'),
    TranslateLanguage('de', '德文', 'German', baidu: 'de', myMemory: 'de'),
    TranslateLanguage('ru', '俄文', 'Russian', baidu: 'ru', myMemory: 'ru'),
    TranslateLanguage('es', '西班牙文', 'Spanish', baidu: 'spa', myMemory: 'es'),
  ];

  static TranslateLanguage of(String? code) =>
      all.firstWhere((l) => l.code == code, orElse: () => all.first);

  String get label => zhName;
}

class TranslateException implements Exception {
  TranslateException(this.message);
  final String message;
  @override
  String toString() => message;
}

class TranslationService {
  TranslationService(this._clientOf, {this.load, this.save});

  /// 取 App 自己的 HTTP 客户端（走用户配的代理/直连），登录后才建得出来。
  final http.Client? Function() _clientOf;

  /// 译文持久化（SQLite kv）：同一条帖子只翻一次，重启也不会再请求。
  /// 免费接口有配额限制，少发一次就少一分被限的风险。
  final String? Function(String key)? load;
  final void Function(String key, String value)? save;

  /// 「语言 + 原文」→ 译文（内存层）。
  final Map<String, String> _cache = {};

  /// 所有请求排队串行 + 固定间隔。
  ///
  /// 列表开了自动翻译之后，一屏会有好几条同时想翻译。并发打同一个免费接口
  /// 很容易被临时拉黑（返回 429/空响应），所以这里一次只发一个，
  /// 中间留 250ms 间隙 —— 对用户来说只是「译文一条条出来」，观感反而更自然。
  Future<void> _queue = Future<void>.value();
  static const _gap = Duration(milliseconds: 250);

  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36';

  /// 单家最长等多久。三家都卡住最多也就 10 秒左右，不会让界面永久转圈。
  static const _attemptTimeout = Duration(seconds: 7);

  /// 长文截断：这些免费接口对长度有限制，而且正文翻太长也没意义。
  static const int _maxChars = 1800;

  /// 翻译；结果会缓存（内存 + 落库）。失败抛 [TranslateException]。
  Future<String> translate(String text, {required String to}) async {
    final input = text.trim();
    if (input.isEmpty) return '';
    final clipped = input.length > _maxChars
        ? input.substring(0, _maxChars)
        : input;
    final lang = TranslateLanguage.of(to);
    final key = _cacheKey(lang, clipped);

    final hit = _cache[key];
    if (hit != null) return hit;
    final stored = load?.call(key);
    if (stored != null && stored.isNotEmpty) {
      _cache[key] = stored;
      return stored;
    }

    final client = _clientOf();
    if (client == null) {
      throw TranslateException('网络未就绪');
    }

    final result = _queue.then((_) => _runProviders(client, clipped, lang));
    // 队列本身不能因为一次失败就断掉。
    _queue = result.then(
      (_) => Future<void>.delayed(_gap),
      onError: (_) => Future<void>.delayed(_gap),
    );
    final out = await result;
    _cache[key] = out;
    save?.call(key, out);
    return out;
  }

  /// 逐家试；三家都失败才抛错。
  Future<String> _runProviders(
    http.Client client,
    String text,
    TranslateLanguage lang,
  ) async {
    String? firstError;
    for (final attempt in <Future<String?> Function()>[
      // 顺序＝质量优先：Google 的语感最接近 X 自带译文（国内需要梯子），
      // 百度对中英互译更地道但要过它的反爬，MyMemory 最稳但译得最生硬，
      // 放最后保底。
      () => _google(client, text, lang),
      () => _baidu(client, text, lang),
      () => _myMemory(client, text, lang),
    ]) {
      try {
        final out = await attempt();
        if (out != null && out.trim().isNotEmpty) return out;
      } catch (e) {
        firstError ??= '$e';
      }
    }
    throw TranslateException(firstError ?? '翻译失败');
  }

  /// 已经翻译过就取缓存（不发请求）。
  String? cached(String text, {required String to}) {
    final lang = TranslateLanguage.of(to);
    final clipped = text.trim();
    final key = _cacheKey(lang, clipped);
    return _cache[key] ?? load?.call(key);
  }

  void clearCache() {
    _cache.clear();
  }

  /// 缓存键：语言 + 原文的 64 位 FNV-1a。
  ///
  /// 不用原文当键：kv 里塞整段正文既占地方又不好查。哈希碰撞在这里可以忽略
  /// （同一条帖子的原文本来就完全一样）。
  String _cacheKey(TranslateLanguage lang, String text) =>
      '${lang.code}_${_fnv1a(text)}';

  static String _fnv1a(String s) {
    var hash = 0xcbf29ce484222325;
    for (final unit in s.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    return hash.toRadixString(16);
  }

  // ------------------------------------------------------------- providers

  /// 粗判原文语言：MyMemory 必须指定源语言，`auto` 它不认。
  String _guessSource(String text) {
    for (final rune in text.runes) {
      if (rune >= 0x3040 && rune <= 0x30FF) return 'ja-JP'; // 假名
      if (rune >= 0xAC00 && rune <= 0xD7AF) return 'ko-KR'; // 谚文
      if (rune >= 0x4E00 && rune <= 0x9FFF) return 'zh-CN'; // 汉字
    }
    return 'en';
  }

  Future<String?> _myMemory(
    http.Client client,
    String text,
    TranslateLanguage lang,
  ) async {
    var from = _guessSource(text);
    // 源语言和目标语言一样时硬翻没有意义，换个源语言让引擎自己识别差别。
    if (from == lang.myMemory) from = lang.myMemory == 'en' ? 'zh-CN' : 'en';
    final uri = Uri.https('api.mymemory.translated.net', '/get', {
      'q': text,
      'langpair': '$from|${lang.myMemory}',
    });
    final resp = await client
        .get(uri, headers: const {'user-agent': _userAgent})
        .timeout(_attemptTimeout);
    if (resp.statusCode != 200) return null;
    final body = jsonDecode(resp.body);
    if (body is! Map) return null;
    final data = body['responseData'];
    final out = data is Map ? data['translatedText'] as String? : null;
    if (out == null) return null;
    // 配额用完时它会把警告塞进译文里，这种「成功」不能要。
    if (out.toUpperCase().contains('MYMEMORY WARNING')) return null;
    return _unescape(out);
  }

  Future<String?> _google(
    http.Client client,
    String text,
    TranslateLanguage lang,
  ) async {
    final uri = Uri.https('translate.googleapis.com', '/translate_a/single', {
      'client': 'gtx',
      'sl': 'auto',
      'tl': lang.myMemory,
      'dt': 't',
      'q': text,
    });
    final resp = await client
        .get(
          uri,
          headers: const {
            'user-agent': _userAgent,
            'accept': 'application/json',
          },
        )
        .timeout(_attemptTimeout);
    if (resp.statusCode != 200) return null;
    final body = jsonDecode(resp.body);
    if (body is! List || body.isEmpty) return null;
    final sentences = body.first;
    if (sentences is! List) return null;
    final buf = StringBuffer();
    for (final s in sentences) {
      if (s is List && s.isNotEmpty && s.first is String) {
        buf.write(s.first);
      }
    }
    final out = buf.toString();
    return out.isEmpty ? null : out;
  }

  Future<String?> _baidu(
    http.Client client,
    String text,
    TranslateLanguage lang,
  ) async {
    final resp = await client
        .post(
          Uri.https('fanyi.baidu.com', '/transapi'),
          headers: const {
            'user-agent': _userAgent,
            'content-type': 'application/x-www-form-urlencoded',
            'referer': 'https://fanyi.baidu.com/',
          },
          body: {'from': 'auto', 'to': lang.baidu, 'query': text},
        )
        .timeout(_attemptTimeout);
    if (resp.statusCode != 200) return null;
    final body = jsonDecode(utf8.decode(resp.bodyBytes));
    if (body is! Map) return null;
    if (body['errno'] != null && body['errno'] != 0) return null;
    final data = body['data'];
    if (data is! List || data.isEmpty) return null;
    final first = data.first;
    if (first is! Map) return null;
    return first['dst'] as String?;
  }

  /// 百度/Google 有时会带 HTML 实体，翻出来显示成 `&quot;` 很怪。
  String _unescape(String s) => s
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>');
}

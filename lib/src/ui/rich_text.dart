/// 正文富文本：把 `#话题`、`@提及`、外链渲染成可点的片段。
///
/// 数据来源优先用 X 自己给的 entities（`legacy.entities` 或长推文的
/// `note_tweet…entity_set`）：它带 UTF-16 的 `indices`，也带外链的
/// `expanded_url` / `display_url` —— 只有它知道 `https://t.co/xxx` 背后是什么，
/// 自己用正则去猜既猜不到真实地址，也会猜错（中日韩文字的 `#` 前缀尤其容易错）。
///
/// entities 缺失时（老数据、导入的库）退回正则：够用，只是外链只能显示域名。
///
/// 为什么单独一个文件：列表卡片和全屏播放页的正文是同一套规则，
/// 复制两份的结果是「列表能点、播放页不能点」这种没人会主动测到的差异。
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/l10n.dart';
import '../model/like_item.dart';

enum BodyEntityKind { url, hashtag, mention }

/// 正文里一个可点片段。
class BodyEntity {
  const BodyEntity({
    required this.start,
    required this.end,
    required this.kind,
    required this.display,
    required this.url,
    this.hidden = false,
  });

  /// 在原文里的 UTF-16 区间。
  final int start;
  final int end;
  final BodyEntityKind kind;

  /// 屏幕上显示的文本（外链显示域名，短链显示「链接」）。
  final String display;

  /// 点击后打开的目标地址。
  final String url;

  /// true = 这一段原文直接不渲染。
  /// 目前只用于「缀在正文最后的 t.co 短链」——它对读者没有信息量，
  /// 而且会让人以为正文里还有个奇怪的网址。
  final bool hidden;
}

/// 从一条喜欢里提取可点片段（按原文位置排序、互不重叠）。
List<BodyEntity> extractBodyEntities(LikeItem item) {
  final text = item.text;
  if (text.isEmpty) return const [];
  final fromEntities = _fromRawEntities(item, text);
  final base = (fromEntities != null && fromEntities.isNotEmpty)
      ? fromEntities
      : _fromRegex(text);
  return _markTrailingShortLink(base, text);
}

/// X 会把**媒体的链接**再以 `https://t.co/xxx` 缀在正文最后（显示成
/// `pic.x.com/xxx`）。原样显示是纯噪音，而且看起来像正文里还有个奇怪的网址，
/// 所以标记成 hidden 让渲染层跳过它。
///
/// 注意只吃「媒体链接」，不能顺手把所有结尾的短链都吃掉 —— 正文最后本来就是
/// 一条真实外链时（「教程在这 https://t.co/xxx」），那个链接是内容的一部分。
List<BodyEntity> _markTrailingShortLink(List<BodyEntity> list, String text) {
  if (list.isEmpty) return list;
  final trimmedLen = text.trimRight().length;
  final last = list.last;
  if (!_isMediaLink(last) || last.end < trimmedLen - 1) return list;

  return [
    ...list.sublist(0, list.length - 1),
    BodyEntity(
      start: last.start,
      end: last.end,
      kind: last.kind,
      display: '',
      url: last.url,
      hidden: true,
    ),
  ];
}

/// `display_url` 是 `pic.x.com/…` / `pic.twitter.com/…` 的就是附件链接。
bool _isMediaLink(BodyEntity e) {
  if (e.kind != BodyEntityKind.url) return false;
  final d = e.display.toLowerCase();
  return d.startsWith('pic.x.com') || d.startsWith('pic.twitter.com');
}

// ---------------------------------------------------------------- entities

List<BodyEntity>? _fromRawEntities(LikeItem item, String text) {
  final raw = item.raw;
  if (raw == null) return null;

  final noteResult = _dig(raw, ['note_tweet', 'note_tweet_results', 'result']);
  final noteText = noteResult is Map ? noteResult['text'] as String? : null;

  // indices 是相对「取正文的那份 JSON」计算的：
  // - 正文来自 note_tweet → 必须配 note_tweet 的 entity_set；
  // - 正文来自 legacy.full_text → 配 legacy.entities。
  // 混用会整体错位（legacy.entities 的 indices 是按被截断的 140 字算的），
  // 这时宁可交给正则兜底，也不要高亮/链接错到别的字上。
  final bool fromNote = noteText != null && noteText.isNotEmpty;
  final Map<dynamic, dynamic> set;
  if (fromNote) {
    final entitySet = noteResult is Map ? noteResult['entity_set'] : null;
    if (entitySet is! Map) return null;
    set = entitySet;
  } else {
    final legacy = raw['legacy'];
    final entities = legacy is Map ? legacy['entities'] : null;
    if (entities is! Map) return null;
    set = entities;
  }

  final out = <BodyEntity>[];
  final lower = text.toLowerCase();

  // ---- 外链（含媒体链接：它也是正文末尾的一条 t.co）
  final links = <Map<dynamic, dynamic>>[..._listOf(set['urls'])];
  if (!fromNote) {
    // 媒体实体的 indices 是按 legacy.full_text 算的，长推文的正文里没有它。
    links.addAll(_listOf(_dig(raw, ['legacy', 'extended_entities', 'media'])));
    links.addAll(_listOf(_dig(raw, ['legacy', 'entities', 'media'])));
  }
  for (final u in links) {
    final indices = _indices(u);
    if (indices == null) continue;
    final shortUrl = u['url'] as String?;
    final expanded = u['expanded_url'] as String?;
    // 只拿「真正的地址」当核对依据。不能把原位置那一截也算进去 ——
    // 那等于自己验证自己，偏移的 indices 会被原样接受。
    final tokens = <String>[
      if (shortUrl != null && shortUrl.isNotEmpty) shortUrl,
      if (expanded != null && expanded.isNotEmpty) expanded,
    ];
    final resolved = _resolve(lower, indices.$1, indices.$2, tokens);
    if (resolved == null) continue; // 对不上就交给原文自己显示，别吃掉字符
    out.add(
      BodyEntity(
        start: resolved.start,
        end: resolved.end,
        kind: BodyEntityKind.url,
        display: _urlLabel(
          displayUrl: (u['display_url'] as String?)?.trim(),
          expanded: expanded,
          original: shortUrl ?? _slice(text, resolved),
        ),
        url: expanded ?? shortUrl ?? '',
      ),
    );
  }

  // ---- 话题
  for (final h in _listOf(set['hashtags'])) {
    final indices = _indices(h);
    final tag = h['text'] as String?;
    if (indices == null || tag == null || tag.isEmpty) continue;
    final resolved = _resolve(lower, indices.$1, indices.$2, [
      '#$tag',
      '＃$tag',
    ]);
    if (resolved == null) continue;
    out.add(
      BodyEntity(
        start: resolved.start,
        end: resolved.end,
        kind: BodyEntityKind.hashtag,
        // 显示用原文那一截：全角 ＃、大小写都和正文完全一致，不会「少几个字」。
        display: _slice(text, resolved),
        // 话题直接跳 X 官方话题页；没有独立页面时它会落到搜索结果。
        url: 'https://x.com/hashtag/${Uri.encodeComponent(tag)}',
      ),
    );
  }

  // ---- 提及
  for (final m in _listOf(set['user_mentions'])) {
    final indices = _indices(m);
    final screen = m['screen_name'] as String?;
    if (indices == null || screen == null || screen.isEmpty) continue;
    final resolved = _resolve(lower, indices.$1, indices.$2, ['@$screen']);
    if (resolved == null) continue;
    out.add(
      BodyEntity(
        start: resolved.start,
        end: resolved.end,
        kind: BodyEntityKind.mention,
        display: _slice(text, resolved),
        url: 'https://x.com/${Uri.encodeComponent(screen)}',
      ),
    );
  }

  out.sort((a, b) => a.start.compareTo(b.start));
  return _sanitize(out, text.length);
}

/// 把 X 给的 indices 对齐到真实正文。
///
/// 这一层是「识别不准、还漏字」的根因修复。X 的 indices 是按它自己那份正文算的
/// UTF-16 偏移，有几种情况会整体错位：
/// - 长推文：`note_tweet` 的正文配了 `legacy.entities` 的偏移（或反过来）；
/// - 正文里出现过被转义的字符（`&amp;` 之类），一个字符变成五个；
/// - 库里存的是早期版本截断过的正文。
///
/// 错几个字符的后果很微妙：高亮断在半个词上、点链接跳到别处、或者末尾几个字符
/// 被当成「实体之外的残留」吞掉。所以这里**不信 indices**，拿实体自己的文本去
/// 正文里核对：
/// 1. 先看原位置那一截是不是它 —— 是就原地用；
/// 2. 不是就按内容重新定位（取离原位置最近的那一处）；
/// 3. 还找不到就放弃这个实体 —— 原文照原样显示。宁可不美化，也不能吃掉字符。
_Resolved? _resolve(String lowerText, int start, int end, List<String> tokens) {
  final cleaned = [
    for (final t in tokens)
      if (t.isNotEmpty) t,
  ];
  if (cleaned.isEmpty) return null;

  // 1) 原地对得上
  if (start >= 0 && end <= lowerText.length && end > start) {
    final slice = lowerText.substring(start, end);
    for (final t in cleaned) {
      if (slice == t.toLowerCase()) return _Resolved(start, end);
    }
  }

  // 2) 按内容找，优先离原 indices 最近的一处
  var best = -1;
  var bestLen = 0;
  for (final t in cleaned) {
    final needle = t.toLowerCase();
    var from = 0;
    while (true) {
      final i = lowerText.indexOf(needle, from);
      if (i < 0) break;
      if (best < 0 || (i - start).abs() < (best - start).abs()) {
        best = i;
        bestLen = needle.length;
      }
      from = i + 1;
    }
  }
  if (best < 0) return null;
  return _Resolved(best, best + bestLen);
}

class _Resolved {
  const _Resolved(this.start, this.end);
  final int start;
  final int end;
}

String _slice(String text, _Resolved r) {
  if (r.start < 0 || r.end > text.length || r.end <= r.start) return '';
  return text.substring(r.start, r.end);
}

/// 丢掉越界和互相重叠的片段（X 的 indices 偶尔会给出交叉区间）。
List<BodyEntity> _sanitize(List<BodyEntity> list, int textLength) {
  final out = <BodyEntity>[];
  var cursor = 0;
  for (final e in list) {
    if (e.start < cursor || e.end <= e.start || e.end > textLength) continue;
    out.add(e);
    cursor = e.end;
  }
  return out;
}

(int, int)? _indices(Map<dynamic, dynamic> m) {
  final raw = m['indices'];
  if (raw is! List || raw.length < 2) return null;
  final s = (raw[0] as num?)?.toInt();
  final e = (raw[1] as num?)?.toInt();
  if (s == null || e == null) return null;
  return (s, e);
}

List<Map<dynamic, dynamic>> _listOf(Object? value) {
  if (value is! List) return const [];
  return [
    for (final v in value)
      if (v is Map) v,
  ];
}

/// 外链显示成什么：优先 `display_url`（`youtube.com/watch?v=…`），
/// 短链没有展开信息时显示「链接」而不是一串 t.co 乱码。
String _urlLabel({
  required String? displayUrl,
  required String? expanded,
  required String original,
}) {
  if (displayUrl != null && displayUrl.isNotEmpty) return displayUrl;
  final target = expanded ?? original;
  final host = Uri.tryParse(target)?.host ?? '';
  if (host.isEmpty || host == 't.co') return t('post.link');
  return host;
}

// ------------------------------------------------------------------- 正则

/// entities 缺失时的兜底。顺序敏感：先 URL（里面可能含 `#`、`@`），再话题/提及。
///
/// 这个兜底以前会「漏几个字符」，两个原因都在这儿修了：
/// - URL 用 `[^\s]+` 会把紧跟在后面的中文标点（`。`、`）`）吃进去，
///   于是链接末尾多出几个怪字符、点开还是个坏地址 —— 现在把尾部标点剥掉；
/// - 话题只认 `#`，正文里用全角 `＃` 的写法整个漏掉 —— 现在两种前缀都认，
///   并且把组合附加符号（\p{M}）也算进话题，避免重音字符被截断。
List<BodyEntity> _fromRegex(String text) {
  if (text.isEmpty) return const [];
  final re = RegExp(
    r'''(https?://[^\s]+)'''
    r'''|([#＃][\p{L}\p{N}\p{M}_]+)'''
    r'''|(@[A-Za-z0-9_]+)''',
    unicode: true,
  );
  final out = <BodyEntity>[];
  for (final m in re.allMatches(text)) {
    final token = m.group(0);
    if (token == null || token.isEmpty) continue;

    if (token.startsWith('http://') || token.startsWith('https://')) {
      final url = _trimUrlTail(token);
      if (url.length <= 'https://'.length) continue;
      out.add(
        BodyEntity(
          start: m.start,
          end: m.start + url.length,
          kind: BodyEntityKind.url,
          display: _urlLabel(displayUrl: null, expanded: null, original: url),
          url: url,
        ),
      );
      continue;
    }
    if (token.startsWith('#') || token.startsWith('＃')) {
      final tag = token.substring(1);
      if (tag.isEmpty) continue;
      out.add(
        BodyEntity(
          start: m.start,
          end: m.end,
          kind: BodyEntityKind.hashtag,
          // 显示原文（全角/半角、大小写都和正文一致）
          display: token,
          url: 'https://x.com/hashtag/${Uri.encodeComponent(tag)}',
        ),
      );
      continue;
    }
    final screen = token.substring(1);
    if (screen.isEmpty) continue;
    out.add(
      BodyEntity(
        start: m.start,
        end: m.end,
        kind: BodyEntityKind.mention,
        display: token,
        url: 'https://x.com/${Uri.encodeComponent(screen)}',
      ),
    );
  }
  return out;
}

/// 网址尾部粘上的标点（中英文都要剥，X 的正文里经常是「看这个 https://x.com/a。」）。
final RegExp _urlTail = RegExp(
  r'''[.,;:!?'"”’)\]}>。，、；：！？…）】》」』〕】]+$''',
  unicode: true,
);

String _trimUrlTail(String url) => url.replaceFirst(_urlTail, '');

Object? _dig(Object? root, List<String> path) {
  Object? cur = root;
  for (final key in path) {
    if (cur is Map) {
      cur = cur[key];
    } else {
      return null;
    }
  }
  return cur;
}

/// 送去在线翻译的正文：`@提及` / `#话题` / 链接**都剔掉**。
///
/// 这些片段翻过去基本是原样或乱码，还会把句子切碎；请求越短也越不容易被
/// 免费接口限流。只在「X 没有自带译文、需要自己翻」时才用。
String translatableBody(LikeItem item, {int maxChars = 600}) {
  final text = item.text;
  if (text.isEmpty) return '';
  final entities = extractBodyEntities(item);
  final buf = StringBuffer();
  var cursor = 0;
  for (final e in entities) {
    if (e.start > cursor && e.start <= text.length) {
      buf.write(text.substring(cursor, e.start));
    }
    buf.write(' ');
    cursor = e.end > cursor ? e.end : cursor;
  }
  if (cursor < text.length) buf.write(text.substring(cursor));

  var out = buf.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
  if (out.length > maxChars) out = out.substring(0, maxChars);
  return out;
}

/// 这段文字是不是「目标语言」。
///
/// 用来自动翻译时判断「要不要翻」：用户的要求是**只有非中文才翻译**。
/// X 通常会给 `source_language`，这里是不给时的兜底粗判。
bool looksLikeLanguage(String text, String langCode) {
  final sample = text.replaceAll(RegExp(r'\s+'), '');
  if (sample.isEmpty) return true;
  var cjk = 0;
  var latin = 0;
  var kana = 0;
  for (final r in sample.runes) {
    if (r >= 0x4E00 && r <= 0x9FFF) {
      cjk++;
    } else if (r >= 0x3040 && r <= 0x30FF) {
      kana++;
    } else if ((r >= 0x41 && r <= 0x5A) || (r >= 0x61 && r <= 0x7A)) {
      latin++;
    }
  }
  final total = cjk + kana + latin;
  if (total < 4) return false; // 太短判断不了，当作外语（不翻更可惜）
  switch (langCode) {
    case 'zh':
      // 没有假名、汉字占大头 → 已经是中文
      return kana == 0 && cjk / total > 0.6;
    case 'en':
      return latin / total > 0.8;
    case 'ja':
      return kana / total > 0.15;
    default:
      return latin / total > 0.8;
  }
}

// ------------------------------------------------------------------- 组件

/// 一条喜欢的正文（可点 + 可高亮 + 可限行）。
class PostBody extends StatefulWidget {
  const PostBody({
    super.key,
    required this.item,
    this.highlights = const [],
    this.style,
    this.maxLines,
    this.linkStyle,
  });

  final LikeItem item;

  /// 搜索命中区间（来自 X 的 `textHighlights`），本地搜索传空。
  final List<({int start, int end})> highlights;

  final TextStyle? style;
  final int? maxLines;

  /// 链接片段的样式；默认用主题色。
  final TextStyle? linkStyle;

  @override
  State<PostBody> createState() => _PostBodyState();
}

class _PostBodyState extends State<PostBody> {
  /// RichText 的点击识别器必须手动释放，否则每次重建都漏一个。
  final List<TapGestureRecognizer> _recognizers = [];

  /// 解析好的实体缓存。
  ///
  /// `extractBodyEntities` 要把每条实体拿去正文里核对/重定位（见 [_resolve]），
  /// 一条长推文就是几十次 indexOf。而卡片在滚动、进度刷新时会反复 build ——
  /// 结果对同一条推文是稳定的，缓存下来只算一次。
  List<BodyEntity>? _entities;
  String? _entitiesFor;

  List<BodyEntity> _entitiesOf(LikeItem item) {
    final key = '${item.tweetId}\u0000${item.text.length}';
    if (_entities != null && _entitiesFor == key) return _entities!;
    final list = extractBodyEntities(item);
    _entities = list;
    _entitiesFor = key;
    return list;
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  Widget build(BuildContext context) {
    // build 会被滚动/进度刷新反复触发，先收掉上一批。
    // 旧的 RichText 已经被替换，不再引用这些 recognizer。
    _disposeRecognizers();

    final theme = Theme.of(context);
    final base = widget.style ?? theme.textTheme.bodyMedium;
    // 末尾空白不进渲染：隐藏短链之后常常会剩下一截换行/空格。
    final text = widget.item.text.trimRight();
    final linkStyle =
        widget.linkStyle ??
        base?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w500,
        );

    final spans = _buildSpans(
      context: context,
      text: text,
      base: base,
      linkStyle: linkStyle,
      theme: theme,
    );

    // 全部被隐藏（正文本来就只是一条媒体短链）时不要留一个空行。
    if (spans.isEmpty || spans.every((s) => (s.toPlainText()).trim().isEmpty)) {
      return const SizedBox.shrink();
    }

    return Text.rich(
      TextSpan(style: base, children: spans),
      maxLines: widget.maxLines,
      overflow: widget.maxLines == null
          ? TextOverflow.clip
          : TextOverflow.ellipsis,
    );
  }

  List<InlineSpan> _buildSpans({
    required BuildContext context,
    required String text,
    required TextStyle? base,
    required TextStyle? linkStyle,
    required ThemeData theme,
  }) {
    // 高亮和链接可能重叠：先按链接切段，再把高亮按区间叠加。
    final entities = _entitiesOf(widget.item);
    final marks = _mergeHighlights(widget.highlights, text.length);

    final spans = <InlineSpan>[];
    var cursor = 0;

    void addPlain(int start, int end) {
      if (end <= start) return;
      _addWithMarks(spans, text, start, end, base, marks, theme);
    }

    for (final e in entities) {
      // 实体的区间是按**原始**正文算的；text 已经 trimRight 过，
      // 越界的那一截（通常就是末尾短链）直接不碰。
      if (e.start >= text.length) continue;
      addPlain(cursor, e.start);
      if (!e.hidden) {
        // 原文这一截换成一个短标签，点开跳到真实地址。
        final recognizer = TapGestureRecognizer()..onTap = () => _open(e.url);
        _recognizers.add(recognizer);
        spans.add(
          TextSpan(text: e.display, style: linkStyle, recognizer: recognizer),
        );
      }
      cursor = e.end;
    }
    addPlain(cursor, text.length);
    return spans;
  }

  void _addWithMarks(
    List<InlineSpan> out,
    String text,
    int start,
    int end,
    TextStyle? base,
    List<({int start, int end})> marks,
    ThemeData theme,
  ) {
    var pos = start;
    for (final m in marks) {
      if (m.end <= pos || m.start >= end) continue;
      final s = m.start.clamp(pos, end);
      if (s > pos) out.add(TextSpan(text: text.substring(pos, s)));
      final e = m.end.clamp(s, end);
      out.add(
        TextSpan(
          text: text.substring(s, e),
          style: TextStyle(
            backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.22),
            fontWeight: FontWeight.w600,
          ),
        ),
      );
      pos = e;
    }
    if (pos < end) out.add(TextSpan(text: text.substring(pos, end)));
  }

  List<({int start, int end})> _mergeHighlights(
    List<({int start, int end})> raw,
    int length,
  ) {
    if (raw.isEmpty) return const [];
    final cleaned = <({int start, int end})>[];
    for (final h in raw) {
      final s = h.start.clamp(0, length);
      final e = h.end.clamp(0, length);
      if (e > s) cleaned.add((start: s, end: e));
    }
    cleaned.sort((a, b) => a.start.compareTo(b.start));
    return cleaned;
  }

  Future<void> _open(String url) async {
    if (url.isEmpty) return;
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}

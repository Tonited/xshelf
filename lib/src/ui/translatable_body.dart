/// 列表里的正文：开了「自动翻译外文帖子」之后，把可见的外文正文显示成中文。
///
/// ## 两级来源
/// 1. **X 自带的译文**（首选）：喜欢/搜索响应里本来就带着
///    `grok_translated_post_with_availability.data.translation`
///    （见 [LikeItem.translation]），零额外请求、零风险；
/// 2. **在线翻译兜底**：X 没给译文的老数据（早先同步的、或 X 判断不需要翻的）
///    才用 net/translate.dart，并且只对**列表里已经构建出来的卡片**发请求，
///    请求串行 + 250ms 间隔 + 结论落库缓存，尽量少打接口。
///
/// ## 规则
/// - 只翻**非中文**帖子（优先看 X 给的 `source_language`，没有就按字符比例粗判）；
/// - `@提及` / `#话题` / 链接不送去翻译（[translatableBody] 会剔掉）；
/// - 行尾一个极小的「原文 / 翻译」开关，随时能切回去。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../core/l10n.dart';
import '../model/like_item.dart';
import 'rich_text.dart';

class TranslatableBody extends StatefulWidget {
  const TranslatableBody({
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
  final TextStyle? linkStyle;

  @override
  State<TranslatableBody> createState() => _TranslatableBodyState();
}

class _TranslatableBodyState extends State<TranslatableBody> {
  /// 用户点了「原文」：这一条改回显示原文。
  bool _showOriginal = false;

  /// 兜底翻译的结果 / 状态。
  String? _fallback;
  bool _busy = false;
  bool _failed = false;

  /// 已经为哪段文字发起过兜底翻译（避免重复请求）。
  String? _requestedFor;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeTranslate());
  }

  @override
  void didUpdateWidget(covariant TranslatableBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.tweetId != widget.item.tweetId) {
      _showOriginal = false;
      _fallback = null;
      _busy = false;
      _failed = false;
      _requestedFor = null;
    }
    // 无论换没换条目都补一次：设置里刚打开自动翻译、或者换了目标语言时，
    // 卡片只是原地重建（tweetId 没变），不主动试一次就永远不会翻。
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeTranslate());
  }

  /// 原文是不是中文（用户的要求：**只有非中文才翻译**）。
  bool _isChinese() {
    final tr = widget.item.translation;
    if (tr?.sourceLang != null) return tr!.isChinese;
    return looksLikeLanguage(widget.item.text, 'zh');
  }

  /// X 给了译文就直接用；没给才去在线翻（只对这张已经构建出来的卡片）。
  Future<void> _maybeTranslate() async {
    if (!mounted) return;
    final app = AppScope.maybeRead(context);
    if (app == null || !app.settings.autoTranslate) return;
    if (_isChinese()) return;

    // 首选：X 自带的译文，不需要任何请求。
    if (widget.item.translation != null) return;

    final source = translatableBody(widget.item);
    if (source.trim().isEmpty) return;
    // 太短（只有一个词/表情）翻了也没意义。
    if (source.runes.length < 4) return;

    final to = app.settings.translateTo;
    final key = '$to\u0000$source';
    if (_requestedFor == key) return;
    _requestedFor = key;

    final cached = app.translate.cached(source, to: to);
    if (cached != null && cached.isNotEmpty) {
      if (mounted) setState(() => _fallback = cached);
      return;
    }

    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      final out = await app.translate.translate(source, to: to);
      if (!mounted) return;
      setState(() {
        _fallback = out;
        _busy = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _failed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final app = AppScope.maybeRead(context);
    final auto = app?.settings.autoTranslate ?? false;

    final xTranslation = widget.item.translation;
    final chinese = auto && _isChinese();

    // 有译文（X 的或兜底的）且不是中文，才切到译文。
    final translated =
        xTranslation?.text ??
        (_fallback?.isNotEmpty == true ? _fallback : null);
    final usable = auto && !chinese && translated != null;
    final showing = usable && !_showOriginal;

    final badge = xTranslation != null
        ? (xTranslation.destLang == null
              ? t('translate.translated')
              : tf('translate.badge', {
                  'lang': xTranslation.destLang!.toUpperCase(),
                }))
        : t('translate.translated');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showing)
          Text(
            translated,
            maxLines: widget.maxLines,
            overflow: widget.maxLines == null
                ? TextOverflow.clip
                : TextOverflow.ellipsis,
            style: widget.style,
          )
        else
          PostBody(
            item: widget.item,
            highlights: widget.highlights,
            maxLines: widget.maxLines,
            style: widget.style,
            linkStyle: widget.linkStyle,
          ),
        // 一行极小的状态：译文标记 + 原文/翻译开关；正在兜底翻译时显示转圈。
        if (auto && (usable || _busy || _failed))
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_busy && translated == null) ...[
                  const SizedBox(
                    width: 10,
                    height: 10,
                    child: CircularProgressIndicator(strokeWidth: 1.4),
                  ),
                  const SizedBox(width: 5),
                  Text(
                    t('translate.working'),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ] else if (_failed && translated == null)
                  // 失败时给一个能点的重试：免费接口偶发抽风，用户不该只能干等。
                  InkWell(
                    onTap: () {
                      setState(() {
                        _failed = false;
                        _requestedFor = null;
                      });
                      unawaited(_maybeTranslate());
                    },
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          t('translate.failed'),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.outline,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          t('action.retry'),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  )
                else ...[
                  Text(
                    showing ? badge : t('translate.original'),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                  const SizedBox(width: 6),
                  InkWell(
                    onTap: () => setState(() => _showOriginal = !_showOriginal),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1),
                      child: Text(
                        showing
                            ? t('translate.original')
                            : t('translate.action'),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

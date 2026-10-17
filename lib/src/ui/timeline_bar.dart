/// 网格右侧的竖向时间轴。
///
/// - 模式 A（喜欢顺序）：刻度按「已抓取的 seq 范围」均分，标签是每段的估算月份。
/// - 模式 B（按发布日期）：刻度是精确的发布月份。
/// - 模式 C（随机）：不显示。
///
/// 交互：点一下跳到该位置；按住拖动时浮出「约 YYYY年M月 · N 条」气泡。
library;

import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../core/l10n.dart';
import '../db/app_database.dart';

class TimelineBar extends StatefulWidget {
  const TimelineBar({super.key, required this.app});
  final AppController app;

  @override
  State<TimelineBar> createState() => _TimelineBarState();
}

class _TimelineBarState extends State<TimelineBar> {
  String? _hint;
  Offset? _hintPos;

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    if (app.mode == SortMode.random || app.totalCount == 0) {
      return const SizedBox.shrink();
    }

    final bounds = app.db.seqBounds();
    final minSeq = bounds.minSeq;
    final maxSeq = bounds.maxSeq;
    if (minSeq == null || maxSeq == null || maxSeq <= minSeq) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight;
        return MouseRegion(
          onHover: (e) => _probe(context, e.localPosition, height),
          onExit: (_) => setState(() => _hint = null),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => _probe(context, d.localPosition, height, jump: true),
            onVerticalDragUpdate: (d) =>
                _probe(context, d.localPosition, height, jump: false),
            onVerticalDragEnd: (d) {
              _probe(context, d.localPosition, height, jump: true);
            },
            child: Container(
              width: 44,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(22),
              ),
              child: Stack(
                children: [
                  // 刻度
                  for (final t in _ticks(context, height))
                    Positioned(
                      top: t.y,
                      left: 6,
                      right: 6,
                      child: Row(
                        children: [
                          Container(
                            width: t.major ? 12 : 6,
                            height: 1.5,
                            color: theme.colorScheme.outlineVariant,
                          ),
                          if (t.major) ...[
                            const SizedBox(width: 3),
                            Expanded(
                              child: Text(
                                t.label,
                                style: theme.textTheme.labelSmall
                                    ?.copyWith(fontSize: 9),
                                overflow: TextOverflow.clip,
                                maxLines: 1,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  if (_hint != null && _hintPos != null)
                    Positioned(
                      top: (_hintPos!.dy - 28).clamp(0.0, height - 32),
                      right: 50,
                      child: Material(
                        elevation: 3,
                        borderRadius: BorderRadius.circular(8),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          child: Text(_hint!,
                              style: theme.textTheme.labelSmall),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 生成刻度：模式 B 用真实月份，模式 A 用均分段 + 估算标签。
  List<({double y, bool major, String label})> _ticks(
      BuildContext context, double height) {
    final app = widget.app;
    final out = <({double y, bool major, String label})>[];

    if (app.mode == SortMode.publishDate) {
      final months = app.months();
      if (months.length <= 1) return out;
      final oldest = months.last.month;
      final newest = months.first.month;
      for (final m in months) {
        final y = _yForMonth(m.month, oldest, newest, height);
        out.add((y: y, major: true, label: m.month.substring(2)));
      }
      return out;
    }

    // 模式 A：约 12 个刻度
    final buckets = app.estimatedTimeline();
    if (buckets.isEmpty) return out;
    final step = (buckets.length / 12).ceil().clamp(1, buckets.length);
    for (var i = 0; i < buckets.length; i += step) {
      final b = buckets[i];
      final y = (i / (buckets.length - 1).clamp(1, 1 << 30)) * (height - 12) + 6;
      final d = b.approxDate;
      out.add((
        y: y,
        major: true,
        label: d == null ? '' : '约${d.year % 100}/${d.month}',
      ));
    }
    return out;
  }

  double _yForMonth(String month, String oldest, String newest, double height) {
    final o = _monthIndex(oldest);
    final n = _monthIndex(newest);
    final m = _monthIndex(month);
    if (n == o) return height / 2;
    // 新的在上面
    return ((n - m) / (n - o)) * (height - 12) + 6;
  }

  int _monthIndex(String ym) {
    final parts = ym.split('-');
    return int.parse(parts[0]) * 12 + int.parse(parts[1]);
  }

  void _probe(BuildContext context, Offset local, double height,
      {bool jump = false}) {
    final app = widget.app;
    final bounds = app.db.seqBounds();
    final minSeq = bounds.minSeq;
    final maxSeq = bounds.maxSeq;
    if (minSeq == null || maxSeq == null) return;

    final t = (local.dy / height).clamp(0.0, 1.0);

    if (app.mode == SortMode.publishDate) {
      final months = app.months();
      if (months.isEmpty) return;
      final idx = (t * (months.length - 1)).round().clamp(0, months.length - 1);
      final m = months[idx];
      setState(() {
        _hint = '${m.month} · ${m.count} 条';
        _hintPos = local;
      });
      if (jump) app.jumpToMonth(m.month);
      return;
    }

    // 模式 A：比例 → seq（seq 越小越新）
    final buckets = app.estimatedTimeline();
    if (buckets.isEmpty) return;
    final idx = (t * (buckets.length - 1)).round().clamp(0, buckets.length - 1);
    final b = buckets[idx];
    final d = b.approxDate;
    setState(() {
      _hint = d == null
          ? '${b.count} 条'
          : '约 ${d.year}年${d.month}月 · ${b.count} 条';
      _hintPos = local;
    });
    if (jump) app.jumpToSeq(b.fromSeq);
  }
}

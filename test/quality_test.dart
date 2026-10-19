import 'package:flutter_test/flutter_test.dart';
import 'package:xlikemanage/src/media/quality.dart';
import 'package:xlikemanage/src/model/like_item.dart';

MediaItem _video(List<(String url, int bitRate)> variants) => MediaItem(
      kind: MediaKind.video,
      url: 'https://pbs.twimg.com/poster.jpg',
      variants: [
        for (final v in variants)
          MediaVariant(url: v.$1, bitRate: v.$2, contentType: 'video/mp4'),
      ],
    );

void main() {
  group('画质阶梯', () {
    test('按分辨率从低到高排，同分辨率只留码率最高的', () {
      final opts = VideoQualityOptions.of(_video([
        ('https://video.twimg.com/x/vid/avc1/1280x720/hi.mp4', 2176000),
        ('https://video.twimg.com/x/vid/avc1/480x270/lo.mp4', 256000),
        ('https://video.twimg.com/x/vid/avc1/640x360/mid.mp4', 832000),
        // 同 360p 的另一个编码，码率更高 → 应该替换掉 mid
        ('https://video.twimg.com/x/vid/avc1/640x360/mid2.mp4', 950000),
      ]));

      expect(opts.sources.map((s) => s.height), [270, 360, 720]);
      expect(opts.sources[1].url, contains('mid2.mp4'));
      expect(opts.fastest!.height, 270);
      expect(opts.best!.height, 720);
      expect(opts.isSwitchable, isTrue);
    });

    test('单档视频不该出现画质菜单', () {
      final opts = VideoQualityOptions.of(
          _video([('https://video.twimg.com/x/vid/avc1/1280x720/only.mp4', 1)]));
      expect(opts.isSwitchable, isFalse);
      expect(opts.menuSources, hasLength(1));
    });

    test('档位 key 稳定、可跨会话寻回', () {
      final opts = VideoQualityOptions.of(_video([
        ('https://video.twimg.com/x/vid/avc1/480x270/lo.mp4', 256000),
        ('https://video.twimg.com/x/vid/avc1/1280x720/hi.mp4', 2176000),
      ]));
      final lo = opts.sources.first;
      final hi = opts.sources.last;
      expect(lo.key, '270_256000');
      expect(hi.key, '720_2176000');
      expect(opts.sourceByKey(hi.key)?.url, hi.url);
      expect(opts.sourceByKey('nope'), isNull);
      // 码率越大越清晰
      expect(hi.rank, greaterThan(lo.rank));
      expect(hi.isHd, isTrue);
      expect(lo.isHd, isFalse);
    });

    test('nextAbove 逐级往上，最高档返回 null', () {
      final opts = VideoQualityOptions.of(_video([
        ('https://video.twimg.com/x/vid/avc1/480x270/a.mp4', 256000),
        ('https://video.twimg.com/x/vid/avc1/640x360/b.mp4', 832000),
        ('https://video.twimg.com/x/vid/avc1/1280x720/c.mp4', 2176000),
      ]));
      final lo = opts.sources[0];
      final mid = opts.sources[1];
      final hi = opts.sources[2];
      expect(opts.nextAbove(lo)?.url, mid.url);
      expect(opts.nextAbove(mid)?.url, hi.url);
      expect(opts.nextAbove(hi), isNull);
      expect(opts.nextAbove(null)?.url, hi.url);
    });

    test('菜单按从高到低列出每一档', () {
      final opts = VideoQualityOptions.of(_video([
        ('https://video.twimg.com/x/vid/avc1/480x270/a.mp4', 256000),
        ('https://video.twimg.com/x/vid/avc1/640x360/b.mp4', 832000),
        ('https://video.twimg.com/x/vid/avc1/1280x720/c.mp4', 2176000),
      ]));
      expect(opts.menuSources.map((s) => s.label), ['720p', '360p', '270p']);
    });

    test('档位菜单：最多 5 档，档名按档数取低/中/高', () {
      final three = VideoQualityOptions.of(_video([
        ('https://video.twimg.com/x/vid/avc1/480x270/a.mp4', 256000),
        ('https://video.twimg.com/x/vid/avc1/640x360/b.mp4', 832000),
        ('https://video.twimg.com/x/vid/avc1/1280x720/c.mp4', 2176000),
      ]));
      expect(three.slots().map((s) => s.tier),
          [QualityTier.low, QualityTier.medium, QualityTier.high]);
      expect(three.slots().map((s) => s.resolution), ['270P', '360P', '720P']);

      final four = VideoQualityOptions.of(_video([
        ('https://video.twimg.com/x/vid/avc1/480x270/a.mp4', 256000),
        ('https://video.twimg.com/x/vid/avc1/640x360/b.mp4', 632000),
        ('https://video.twimg.com/x/vid/avc1/640x480/c.mp4', 950000),
        ('https://video.twimg.com/x/vid/avc1/1280x720/d.mp4', 2176000),
      ]));
      expect(four.slots().map((s) => s.tier), [
        QualityTier.low,
        QualityTier.mediumLow,
        QualityTier.mediumHigh,
        QualityTier.high,
      ]);

      // 变体比 5 个多：均匀抽稀，菜单不会长到没边
      final six = VideoQualityOptions.of(_video([
        for (var i = 0; i < 6; i++)
          (
            'https://video.twimg.com/x/vid/avc1/${240 + i * 120}x${135 + i * 67}/v$i.mp4',
            100000 * (i + 1),
          ),
      ]));
      final slots = six.slots();
      expect(slots, hasLength(5));
      expect(slots.first.tier, QualityTier.low);
      expect(slots.last.tier, QualityTier.high);
      expect(slots.first.source, six.sources.first);
      expect(slots.last.source, six.sources.last);
    });

    test('抽象档位在任何档数的视频上都映射得到', () {
      final three = VideoQualityOptions.of(_video([
        ('https://video.twimg.com/x/vid/avc1/480x270/a.mp4', 256000),
        ('https://video.twimg.com/x/vid/avc1/640x360/b.mp4', 832000),
        ('https://video.twimg.com/x/vid/avc1/1280x720/c.mp4', 2176000),
      ]));
      expect(three.sourceForTier(QualityTier.high)!.height, 720);
      expect(three.sourceForTier(QualityTier.low)!.height, 270);
      expect(three.sourceForTier(QualityTier.auto)!.height, 720);
      // 「中」在 3 档视频上是中间那档
      expect(three.sourceForTier(QualityTier.medium)!.height, 360);

      final two = VideoQualityOptions.of(_video([
        ('https://video.twimg.com/x/vid/avc1/480x270/a.mp4', 256000),
        ('https://video.twimg.com/x/vid/avc1/1280x720/c.mp4', 2176000),
      ]));
      expect(two.sourceForTier(QualityTier.high)!.height, 720);
      expect(two.sourceForTier(QualityTier.low)!.height, 270);
      // 只有两档时「中」落到最接近的那一档（不越界）
      expect(two.sourceForTier(QualityTier.medium), isNotNull);
    });
  });
}

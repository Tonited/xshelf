import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xlikemanage/src/db/app_database.dart';
import 'package:xlikemanage/src/media/quality.dart';
import 'package:xlikemanage/src/model/like_item.dart';
import 'package:xlikemanage/src/ui/post_card.dart';

LikeItem _videoItem() => LikeItem(
  tweetId: '42',
  text: 'a video post',
  createdAt: DateTime.utc(2021, 3, 4, 5, 6),
  author: const Author(
    id: 'u1',
    screenName: 'alice',
    name: 'Alice',
    avatarUrl: 'https://example.invalid/a.jpg',
  ),
  media: const [
    MediaItem(
      kind: MediaKind.video,
      url: 'https://example.invalid/poster.jpg',
      variants: [
        MediaVariant(
          url: 'https://example.invalid/v.mp4',
          contentType: 'video/mp4',
        ),
      ],
    ),
  ],
);

MediaItem _ladderMedia() => const MediaItem(
  kind: MediaKind.video,
  url: 'https://example.invalid/poster.jpg',
  // 真实的 X 视频 URL 长这样：.../avc1/<宽>x<高>/<文件>.mp4
  // 高度在第二个数字里，_heightOf 就是按这个取的。
  variants: [
    MediaVariant(
      url: 'https://video.twimg.com/v/avc1/270x480/a.mp4',
      contentType: 'video/mp4',
      bitRate: 256000,
    ),
    MediaVariant(
      url: 'https://video.twimg.com/v/avc1/480x852/b.mp4',
      contentType: 'video/mp4',
      bitRate: 832000,
    ),
    MediaVariant(
      url: 'https://video.twimg.com/v/avc1/720x1280/c.mp4',
      contentType: 'video/mp4',
      bitRate: 2176000,
    ),
    MediaVariant(
      url: 'https://video.twimg.com/v/playlist.m3u8',
      contentType: 'application/x-mpegURL',
    ),
  ],
);

void main() {
  group('filters', () {
    test('json roundtrip keeps every dimension', () {
      final f = LikesFilter(
        media: {MediaFilter.video, MediaFilter.text},
        authorScreenName: 'alice',
        from: DateTime.utc(2020, 1, 1),
        to: DateTime.utc(2021, 1, 1),
        search: '猫',
      );
      final back = LikesFilter.fromJson(f.toJson());
      expect(back.media, f.media);
      expect(back.authorScreenName, 'alice');
      expect(back.from, f.from);
      expect(back.to, f.to);
      expect(back.search, '猫');
      expect(back.isEmpty, isFalse);
    });

    test('empty filter recognises itself', () {
      expect(const LikesFilter().isEmpty, isTrue);
      expect(const LikesFilter(search: '  ').isEmpty, isTrue);
    });
  });

  group('like item', () {
    test('derives media flags and playable url', () {
      final item = _videoItem();
      expect(item.hasVideo, isTrue);
      expect(item.hasImage, isFalse);
      expect(item.media.first.isPlayable, isTrue);
      expect(item.thumbnailUrl, 'https://example.invalid/poster.jpg');
    });

    test('copyWith only replaces given fields', () {
      final item = _videoItem();
      final next = item.copyWith(state: LikeState.deleted, feedRank: -7);
      expect(next.state, LikeState.deleted);
      expect(next.feedRank, -7);
      expect(next.tweetId, item.tweetId);
      expect(next.text, item.text);
    });
  });

  group('video quality ladder', () {
    test('single-variant video is not switchable', () {
      final opts = VideoQualityOptions.of(_videoItem().media.first);
      expect(opts.sources, hasLength(1));
      expect(opts.isSwitchable, isFalse);
      expect(
        opts.pick(VideoQuality.high)!.url,
        'https://example.invalid/v.mp4',
      );
    });

    test('mp4s are ordered low → high and height is parsed from the url', () {
      final opts = VideoQualityOptions.of(_ladderMedia());
      // HLS 被忽略：有 mp4 阶梯时就只用 mp4。
      expect(opts.sources, hasLength(3));
      expect(opts.isSwitchable, isTrue);
      // 档位标的是**短边**：`270x480` 是竖屏视频，大家嘴里的「270P / 480P」，
      // 拿长边会显示成 480P / 852P，看着比实际清楚。
      expect(opts.sources.map((s) => s.height).toList(), [270, 480, 720]);
      expect(opts.fastest!.bitRate, 256000);
      expect(opts.best!.bitRate, 2176000);
      expect(opts.best!.label, '720p');
    });

    test('quality preference maps onto the right rung', () {
      final opts = VideoQualityOptions.of(_ladderMedia());
      expect(opts.pick(VideoQuality.low)!.bitRate, 256000);
      expect(opts.pick(VideoQuality.high)!.bitRate, 2176000);
      expect(opts.pick(VideoQuality.medium)!.bitRate, 832000);
      // auto 的目标档就是最高档，起播档是最低档。
      expect(opts.pick(VideoQuality.auto)!.url, opts.best!.url);
      expect(opts.fastest!.url, isNot(opts.best!.url));
    });

    test(
      'upgradeFrom returns the best rung only when there is one to go to',
      () {
        final opts = VideoQualityOptions.of(_ladderMedia());
        expect(opts.upgradeFrom(opts.fastest!)!.url, opts.best!.url);
        expect(opts.upgradeFrom(opts.best!), isNull);
        final single = VideoQualityOptions.of(_videoItem().media.first);
        expect(single.upgradeFrom(single.sources.first), isNull);
      },
    );

    test('hls is used when there is no mp4 at all', () {
      const media = MediaItem(
        kind: MediaKind.video,
        url: 'https://example.invalid/poster.jpg',
        variants: [
          MediaVariant(
            url: 'https://video.twimg.com/v/playlist.m3u8',
            contentType: 'application/x-mpegURL',
          ),
        ],
      );
      final opts = VideoQualityOptions.of(media);
      expect(opts.sources, hasLength(1));
      expect(opts.sources.first.isHls, isTrue);
      expect(opts.isSwitchable, isFalse);
    });
  });

  group('post card widget', () {
    testWidgets('renders a text-only post with author and body', (
      tester,
    ) async {
      final item = LikeItem(
        tweetId: '9',
        text: '纯文字推文',
        author: const Author(id: 'u', screenName: 'bob', name: 'Bob'),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PostCard(item: item, onTap: () {}),
          ),
        ),
      );
      expect(find.text('纯文字推文'), findsOneWidget);
      expect(find.text('Bob'), findsOneWidget);
      expect(find.text('@bob'), findsOneWidget);
    });

    testWidgets('shows the play badge for a video post', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: PostCard(item: _videoItem(), onTap: () {}),
            ),
          ),
        ),
      );
      await tester.pump();
      // 网络图片在测试环境里会失败并走 errorBuilder，但角标仍然渲染。
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    });
  });
}

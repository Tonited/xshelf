import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xlikemanage/src/db/app_database.dart';
import 'package:xlikemanage/src/model/like_item.dart';
import 'package:xlikemanage/src/ui/like_tile.dart';

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
                url: 'https://example.invalid/v.mp4', contentType: 'video/mp4'),
          ],
        )
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

  group('like tile widget', () {
    testWidgets('renders a fallback card for text-only posts', (tester) async {
      final item = LikeItem(
        tweetId: '9',
        text: '纯文字推文',
        author: const Author(id: 'u', screenName: 'bob', name: 'Bob'),
      );
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 240,
            height: 240,
            child: LikeTile(item: item, selected: false, onTap: () {}),
          ),
        ),
      ));
      expect(find.text('纯文字推文'), findsOneWidget);
    });

    testWidgets('shows the video badge when media is present', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 240,
            height: 240,
            child: LikeTile(item: _videoItem(), selected: false, onTap: () {}),
          ),
        ),
      ));
      await tester.pump();
      // 网络图片在测试环境里会失败并走 errorBuilder，但徽标仍然渲染。
      expect(find.byIcon(Icons.play_circle_fill), findsOneWidget);
    });
  });
}

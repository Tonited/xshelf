/// 书签响应的解析测试。
///
/// 书签和 Likes 的**推文节点结构完全一致**，唯一的差别是响应根：
/// `data.bookmark_timeline_v2.timeline.instructions`（2023-04 之前叫
/// `bookmark_timeline`）。这里用手写的最小响应把这条差异钉住，同时验证
/// 「拿 Likes 的根来解析书签」会明确报错，而不是静默返回 0 条。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:xlikemanage/src/sync/likes_parser.dart';

Map<String, Object?> _tweetEntry(String id, {String text = 'bookmarked'}) => {
  'entryId': 'tweet-$id',
  'content': {
    'entryType': 'TimelineTimelineItem',
    'itemContent': {
      'tweet_results': {
        'result': {
          '__typename': 'Tweet',
          'rest_id': id,
          'legacy': {
            'full_text': text,
            'created_at': 'Wed Oct 10 20:19:24 +0000 2018',
            'lang': 'en',
          },
          'core': {
            'user_results': {
              'result': {
                'rest_id': 'u$id',
                'core': {'screen_name': 'alice', 'name': 'Alice'},
                'avatar': {'image_url': 'https://pbs.twimg.com/a_normal.jpg'},
              },
            },
          },
        },
      },
    },
  },
};

Map<String, Object?> _cursorEntry(String type, String value) => {
  'entryId': 'cursor-${type.toLowerCase()}-1',
  'content': {
    'entryType': 'TimelineTimelineCursor',
    'cursorType': type,
    'value': value,
  },
};

/// 书签的响应根（`_v2`）。
Map<String, Object?> bookmarkPayload({String root = 'bookmark_timeline_v2'}) =>
    {
      'data': {
        root: {
          'timeline': {
            'instructions': [
              {
                'type': 'TimelineAddEntries',
                'entries': [
                  _tweetEntry('1'),
                  _tweetEntry('2', text: 'second'),
                  _cursorEntry('Top', 'CURSOR_TOP'),
                  _cursorEntry('Bottom', 'CURSOR_BOTTOM'),
                ],
              },
            ],
          },
        },
      },
    };

void main() {
  test('解析 bookmark_timeline_v2', () {
    final page = parseBookmarksPage(bookmarkPayload());
    expect(page.items.length, 2);
    expect(page.items.first.tweetId, '1');
    expect(page.items.first.text, 'bookmarked');
    expect(page.items.first.author?.screenName, 'alice');
    expect(page.items.first.author?.avatarUrl, contains('_bigger'));
    expect(page.topCursor, 'CURSOR_TOP');
    expect(page.bottomCursor, 'CURSOR_BOTTOM');
    expect(page.hasMore, isTrue);
  });

  test('旧名字 bookmark_timeline 也能解析', () {
    final page = parseBookmarksPage(bookmarkPayload(root: 'bookmark_timeline'));
    expect(page.items.length, 2);
    expect(page.bottomCursor, 'CURSOR_BOTTOM');
  });

  test('拿 Likes 的根喂给书签解析会明确报错', () {
    // 结构是 Likes 的（data.user.result），不是书签的。
    final likesShape = {
      'data': {
        'user': {
          'result': {
            'timeline': {
              'timeline': {
                'instructions': [
                  {'type': 'TimelineAddEntries', 'entries': []},
                ],
              },
            },
          },
        },
      },
    };
    expect(
      () => parseBookmarksPage(likesShape),
      throwsA(isA<LikesParseException>()),
    );
  });

  test('没有 data 时也抛解析异常，而不是当成空页', () {
    expect(
      () => parseBookmarksPage({
        'errors': [
          {'message': 'nope'},
        ],
      }),
      throwsA(isA<LikesParseException>()),
    );
  });
}

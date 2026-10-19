/// 用**真实抓到的 Likes 响应**（2026-10，已脱敏正文）验证解析层。
///
/// 这个测试的价值在于结构真实性：X 在 2026-10 把指令路径改成了
/// `timeline.timeline.instructions`（多一层 timeline），并把作者信息从
/// `legacy.screen_name` 挪到了 `core.screen_name`。手写的假数据永远发现不了
/// 这种漂移 —— 只有真响应能。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xlikemanage/src/sync/likes_parser.dart';

void main() {
  test('parses a real (slimmed) Likes payload into items', () {
    final file = File('test/fixtures/likes_real_slim.json');
    expect(file.existsSync(), isTrue, reason: 'fixture missing: ${file.path}');
    final json = jsonDecode(file.readAsStringSync());

    final page = parseLikesPage(json);

    // 两条推文 + 两个游标（游标不进 items）
    expect(page.items.length, 2);
    expect(page.entryCount, 4);

    final first = page.items.first;
    expect(first.tweetId, '9000000000000000002');
    expect(first.text, 'fixture tweet text');
    expect(first.author, isNotNull);
    expect(first.author!.screenName, 'demo_author');
    expect(first.author!.name, isNotEmpty);
    expect(first.author!.avatarUrl, contains('pbs.twimg.com'));
    expect(first.createdAt, isNotNull);
    // 这条推文带一个视频（amplify_video_thumb）
    expect(first.media, isNotEmpty);
    expect(first.hasVideo, isTrue);
    expect(first.media.first.url, contains('pbs.twimg.com'));
    expect(first.media.first.isPlayable, isTrue);

    // 底部游标决定「还能不能继续翻页」
    expect(page.bottomCursor, isNotNull);
    expect(page.bottomCursor, isNotEmpty);
    expect(page.hasMore, isTrue);
  });

  test('still accepts the older timeline_v2 shape', () {
    final legacyShape = {
      'data': {
        'user': {
          'result': {
            'timeline_v2': {
              'timeline': {
                'instructions': [
                  {
                    'type': 'TimelineAddEntries',
                    'entries': [
                      {
                        'entryId': 'tweet-42',
                        'content': {
                          'entryType': 'TimelineTimelineItem',
                          'itemContent': {
                            'tweet_results': {
                              'result': {
                                'rest_id': '42',
                                '__typename': 'Tweet',
                                'legacy': {
                                  'full_text': 'old shape',
                                  'created_at': null,
                                },
                              },
                            },
                          },
                        },
                      },
                    ],
                  },
                ],
              },
            },
          },
        },
      },
    };
    final page = parseLikesPage(legacyShape);
    expect(page.items.length, 1);
    expect(page.items.first.tweetId, '42');
    expect(page.items.first.text, 'old shape');
  });
}

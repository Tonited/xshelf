import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:xlikemanage/src/sync/x_client.dart';

/// queryId 是 X 前端里会变的东西：缓存错了必须能自愈，否则用户升级不了应用就永远 400。
void main() {
  const freshId = 'FresHQueryId01';

  Map<String, Object?> page() => {
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
                          'entryId': 'tweet-1',
                          'content': {
                            'entryType': 'TimelineTimelineItem',
                            'itemContent': {
                              'itemType': 'TimelineTweet',
                              'tweet_results': {
                                'result': {
                                  'rest_id': '1',
                                  '__typename': 'Tweet',
                                  'legacy': {
                                    'full_text': 'hi',
                                    'created_at':
                                        'Mon Jan 04 00:00:00 +0000 2021',
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

  /// 一个会 404 旧 queryId、并从「前端 JS」里暴露新 queryId 的假 X。
  MockClient fakeX({
    required void Function(String path) hits,
  }) =>
      MockClient((request) async {
        final url = request.url;
        hits(url.toString());

        if (url.path.contains('/i/api/graphql/')) {
          if (url.path.contains(freshId)) {
            return http.Response(jsonEncode(page()), 200,
                headers: {'content-type': 'application/json'});
          }
          // 旧 queryId：X 的典型回应
          return http.Response(jsonEncode({'errors': []}), 404);
        }

        if (url.host == 'x.com' && url.path == '/') {
          return http.Response(
            '<html><script src="https://abs.twimg.com/responsive-web/client-web/main.abc.js"></script></html>',
            200,
          );
        }

        if (url.host == 'abs.twimg.com') {
          return http.Response(
            'queryId:"$freshId",operationName:"Likes",operationType:"query"',
            200,
          );
        }
        return http.Response('not found', 404);
      });

  test('stale cached queryId is dropped, rediscovered and retried', () async {
    final paths = <String>[];
    final discovered = <String, String>{};
    final invalidated = <String>[];

    final client = XClient(
      session: const XSession(authToken: 'a', ct0: 'c', userId: '1'),
      httpClient: fakeX(hits: paths.add),
      presetQueryIds: const {'Likes': 'StaleQueryId00'},
      onQueryId: (op, id) => discovered[op] = id,
      onQueryIdInvalid: invalidated.add,
    );

    final likes = await client.fetchLikes();

    expect(likes.items.map((i) => i.tweetId), ['1']);
    expect(invalidated, contains('Likes'));
    expect(discovered['Likes'], freshId);
    // 第一次用旧 id、失败后重新发现再成功
    expect(paths.where((p) => p.contains('/Likes')).length, 2);
  });

  test('without a cached id it discovers first and does not loop', () async {
    final paths = <String>[];
    final client = XClient(
      session: const XSession(authToken: 'a', ct0: 'c', userId: '1'),
      httpClient: fakeX(hits: paths.add),
    );

    await client.fetchLikes();
    expect(paths.where((p) => p.contains('abs.twimg.com')).length, 1);
    expect(paths.where((p) => p.contains('/Likes')).length, 1);
  });
}

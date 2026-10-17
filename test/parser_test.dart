import 'package:flutter_test/flutter_test.dart';
import 'package:xlikemanage/src/model/like_item.dart';
import 'package:xlikemanage/src/sync/likes_parser.dart';
import 'package:xlikemanage/src/sync/twitter_date.dart';

/// 用一份接近真实的响应片段固定解析行为（字段名一改就该在这里红）。
Map<String, Object?> _fixture() => {
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
                        'entryId': 'tweet-111',
                        'content': {
                          'entryType': 'TimelineTimelineItem',
                          'itemContent': {
                            'itemType': 'TimelineTweet',
                            'tweet_results': {
                              'result': {
                                'rest_id': '111',
                                '__typename': 'Tweet',
                                'core': {
                                  'user_results': {
                                    'result': {
                                      'rest_id': 'u1',
                                      'core': {
                                        'screen_name': 'alice',
                                        'name': 'Alice',
                                      },
                                      'avatar': {
                                        'image_url':
                                            'https://pbs.twimg.com/a_normal.jpg'
                                      },
                                    }
                                  }
                                },
                                'legacy': {
                                  'full_text': 'hello world',
                                  'created_at': 'Wed Oct 10 20:19:24 +0000 2018',
                                  'lang': 'en',
                                  'extended_entities': {
                                    'media': [
                                      {
                                        'type': 'video',
                                        'media_url_https':
                                            'https://pbs.twimg.com/poster.jpg',
                                        'original_info': {
                                          'width': 1280,
                                          'height': 720
                                        },
                                        'video_info': {
                                          'duration_millis': 6400,
                                          'variants': [
                                            {
                                              'bit_rate': 832000,
                                              'content_type': 'video/mp4',
                                              'url': 'https://video.twimg.com/low.mp4'
                                            },
                                            {
                                              'bit_rate': 2176000,
                                              'content_type': 'video/mp4',
                                              'url': 'https://video.twimg.com/high.mp4'
                                            },
                                            {
                                              'content_type':
                                                  'application/x-mpegURL',
                                              'url': 'https://video.twimg.com/x.m3u8'
                                            },
                                          ],
                                        },
                                      }
                                    ]
                                  },
                                },
                              }
                            }
                          }
                        }
                      },
                      {
                        'entryId': 'cursor-bottom-9',
                        'content': {
                          'entryType': 'TimelineTimelineCursor',
                          'cursorType': 'Bottom',
                          'value': 'CURSOR_2',
                        }
                      },
                      {
                        'entryId': 'tweet-222',
                        'content': {
                          'entryType': 'TimelineTimelineItem',
                          'itemContent': {
                            'itemType': 'TimelineTweet',
                            'tweet_results': {
                              'result': {'__typename': 'TweetTombstone'}
                            }
                          }
                        }
                      },
                    ]
                  }
                ]
              }
            }
          }
        }
      }
    };

void main() {
  group('twitter date', () {
    test('parses the legacy format', () {
      final d = parseTwitterDate('Wed Oct 10 20:19:24 +0000 2018');
      expect(d, isNotNull);
      expect(d!.toUtc(), DateTime.utc(2018, 10, 10, 20, 19, 24));
    });

    test('handles bad input', () {
      expect(parseTwitterDate(null), isNull);
      expect(parseTwitterDate('nope'), isNull);
    });
  });

  group('likes parser', () {
    test('extracts tweet, author, media and cursor', () {
      final page = parseLikesPage(_fixture());
      expect(page.items, hasLength(1));
      final item = page.items.first;
      expect(item.tweetId, '111');
      expect(item.text, 'hello world');
      expect(item.author?.screenName, 'alice');
      expect(item.author?.avatarUrl, contains('_bigger'));
      expect(item.media, hasLength(1));
      expect(item.media.first.kind, MediaKind.video);
      expect(item.media.first.bestPlaybackUrl, 'https://video.twimg.com/high.mp4');
      expect(page.bottomCursor, 'CURSOR_2');
      expect(page.deletedTweetIds, ['222']);
      expect(page.hasMore, isTrue);
    });

    test('rejects malformed payloads with a typed error', () {
      expect(
        () => parseLikesPage({'data': {}}),
        throwsA(isA<LikesParseException>()),
      );
    });
  });
}

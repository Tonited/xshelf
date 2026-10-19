import 'package:flutter_test/flutter_test.dart';
import 'package:xlikemanage/src/model/like_item.dart';
import 'package:xlikemanage/src/ui/rich_text.dart';

/// 正文里 #话题 / @提及 / 外链的位置必须和正文完全对得上。
///
/// 这里的重点是「X 给的 indices 不可信」这一条：错几个字符时，高亮会断在半个词
/// 上、点链接会跳到别处，甚至末尾几个字符被当成实体之外的残留吞掉。
LikeItem _item(String text, Map<String, Object?> entities, {Object? raw}) =>
    LikeItem(
      tweetId: '1',
      text: text,
      raw: raw == null
          ? {
              'legacy': {'full_text': text, 'entities': entities},
            }
          : raw as Map<String, Object?>,
    );

void main() {
  group('正文实体', () {
    const text = '看这个 #话题 和 @alice 还有 https://t.co/abc';

    test('indices 正确时原样还原每一段（显示文本 == 原文那一截）', () {
      final item = _item(text, {
        'hashtags': [
          {
            'text': '话题',
            'indices': [4, 7],
          },
        ],
        'user_mentions': [
          {
            'screen_name': 'alice',
            'indices': [10, 16],
          },
        ],
        'urls': [
          {
            'url': 'https://t.co/abc',
            'expanded_url': 'https://example.com/x',
            'display_url': 'example.com/x',
            'indices': [20, 36],
          },
        ],
      });

      final entities = extractBodyEntities(item);
      expect(entities, hasLength(3));
      expect(entities[0].kind, BodyEntityKind.hashtag);
      expect(entities[0].display, '#话题');
      expect(entities[1].kind, BodyEntityKind.mention);
      expect(entities[1].display, '@alice');
      expect(entities[2].kind, BodyEntityKind.url);
      expect(entities[2].display, 'example.com/x');
      expect(entities[2].url, 'https://example.com/x');
      expect(entities[2].hidden, isFalse);
    });

    test('indices 整体偏移几个字符时按内容重新定位，不漏字', () {
      // 同一段正文，但 indices 各自短了几个字符（X 换正文来源时很常见）
      final item = _item(text, {
        'hashtags': [
          {
            'text': '话题',
            'indices': [4, 5],
          },
        ],
        'user_mentions': [
          {
            'screen_name': 'alice',
            'indices': [11, 16],
          },
        ],
        'urls': [
          {
            'url': 'https://t.co/abc',
            'expanded_url': 'https://example.com/x',
            'display_url': 'example.com/x',
            'indices': [23, 36],
          },
        ],
      });

      final entities = extractBodyEntities(item);
      expect(entities, hasLength(3));
      // 话题/提及必须覆盖完整的那一段（显示文本就是原文那截）
      for (final e in entities) {
        expect(
          text.substring(e.start, e.end),
          e.kind == BodyEntityKind.url ? 'https://t.co/abc' : e.display,
        );
      }
      expect(entities[0].display, '#话题');
      expect(entities[1].display, '@alice');
      expect(entities[2].url, 'https://example.com/x');
    });

    test('正文末尾的附件短链藏起来，真实外链保留', () {
      const mediaText = '好看的图 https://t.co/pic1';
      final media = _item(
        mediaText,
        const {},
        raw: {
          'legacy': {
            'full_text': mediaText,
            'entities': const {},
            'extended_entities': {
              'media': [
                {
                  'type': 'photo',
                  'url': 'https://t.co/pic1',
                  'expanded_url': 'https://x.com/u/status/1/photo/1',
                  'display_url': 'pic.x.com/pic1',
                  'indices': [5, 21],
                },
              ],
            },
          },
        },
      );
      final hidden = extractBodyEntities(media);
      expect(hidden, hasLength(1));
      expect(hidden.first.hidden, isTrue);

      const linkText = '教程在这 https://t.co/real1';
      final link = _item(linkText, {
        'urls': [
          {
            'url': 'https://t.co/real1',
            'expanded_url': 'https://example.com/course',
            'display_url': 'example.com/course',
            'indices': [5, 21],
          },
        ],
      });
      final kept = extractBodyEntities(link);
      expect(kept, hasLength(1));
      expect(kept.first.hidden, isFalse);
      expect(kept.first.url, 'https://example.com/course');
    });

    test('没有 entities 时退回正则：全角井号、中文标点都不再吃字符', () {
      const raw = '教程在 https://example.com/a。 然后 ＃中文话题 和 @bob';
      final item = LikeItem(tweetId: '2', text: raw);

      final entities = extractBodyEntities(item);
      expect(entities, hasLength(3));
      expect(entities[0].kind, BodyEntityKind.url);
      // 句号是正文的一部分，不能让链接把它吃掉
      expect(entities[0].url, 'https://example.com/a');
      expect(entities[1].kind, BodyEntityKind.hashtag);
      expect(entities[1].display, '＃中文话题');
      expect(entities[2].kind, BodyEntityKind.mention);
      expect(entities[2].display, '@bob');
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:xlikemanage/src/model/like_item.dart';
import 'package:xlikemanage/src/ui/rich_text.dart';

/// X 自带译文的解析 + 「只有非中文才翻」的判定。
void main() {
  group('X 自带译文', () {
    test('从 grok_translated_post_with_availability 里读出译文与源语言', () {
      const item = LikeItem(
        tweetId: '1',
        text: 'TBT, já casada\nNo mercado, muito louco',
        raw: {
          'grok_translated_post_with_availability': {
            'is_available': true,
            'data': {
              'destination_language': 'zh',
              'source_language': 'pt',
              'translation': '【回忆】已经结婚了\n市场上太疯狂了',
            },
          },
        },
      );
      final tr = item.translation;
      expect(tr, isNotNull);
      expect(tr!.sourceLang, 'pt');
      expect(tr.destLang, 'zh');
      expect(tr.isChinese, isFalse);
      expect(tr.text, contains('结婚了'));
    });

    test('没有这个节点 / 标记不可用 → 没有译文', () {
      expect(const LikeItem(tweetId: '1', text: 'hi').translation, isNull);
      expect(
        const LikeItem(tweetId: '2', text: 'hi', raw: {
          'grok_translated_post_with_availability': {'is_available': false},
        }).translation,
        isNull,
      );
    });

    test('中文原文的译文虽然存在，也要被判定为「不该显示」', () {
      const item = LikeItem(
        tweetId: '3',
        text: '今天天气不错',
        raw: {
          'grok_translated_post_with_availability': {
            'data': {'source_language': 'zh', 'translation': 'x'},
          },
        },
      );
      expect(item.translation!.isChinese, isTrue);
    });
  });

  group('语种粗判', () {
    test('中文 / 英文 / 日文都不会误判', () {
      expect(looksLikeLanguage('今天天气不错，出去走走', 'zh'), isTrue);
      expect(looksLikeLanguage('the quick brown fox jumps', 'zh'), isFalse);
      expect(looksLikeLanguage('これはテストです', 'zh'), isFalse);
      expect(looksLikeLanguage('これはテストです', 'ja'), isTrue);
      expect(looksLikeLanguage('the quick brown fox', 'en'), isTrue);
    });
  });

  group('送去翻译的正文', () {
    test('@提及 / #话题 / 链接都被剔掉', () {
      const text = '看这个 #话题 和 @alice 还有 https://t.co/abc';
      const item = LikeItem(
        tweetId: '1',
        text: text,
        raw: {
          'legacy': {
            'full_text': text,
            'entities': {
              'hashtags': [
                {
                  'text': '话题',
                  'indices': [4, 7],
                }
              ],
              'user_mentions': [
                {
                  'screen_name': 'alice',
                  'indices': [10, 16],
                }
              ],
              'urls': [
                {
                  'url': 'https://t.co/abc',
                  'expanded_url': 'https://example.com/x',
                  'display_url': 'example.com/x',
                  'indices': [20, 36],
                }
              ],
            },
          },
        },
      );
      final out = translatableBody(item);
      expect(out, isNot(contains('@alice')));
      expect(out, isNot(contains('#')));
      expect(out, isNot(contains('t.co')));
      expect(out, contains('看这个'));
    });
  });
}

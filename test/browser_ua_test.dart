import 'package:flutter_test/flutter_test.dart';
import 'package:xlikemanage/src/core/browser_ua.dart';

void main() {
  group('cleanWebViewUserAgent', () {
    test('抹掉 Android WebView 的标记', () {
      const raw =
          'Mozilla/5.0 (Linux; Android 14; Pixel 8 '
          'Build/UP1A.231005.007; wv) AppleWebKit/537.36 (KHTML, like Gecko) '
          'Version/4.0 Chrome/141.0.0.0 Mobile Safari/537.36';

      final ua = cleanWebViewUserAgent(raw);

      expect(ua, contains('Pixel 8 Build/UP1A.231005.007)'));
      expect(ua, isNot(contains('wv')));
      expect(ua, isNot(contains('Version/')));
      expect(ua, contains('Chrome/141.0.0.0 Mobile Safari/537.36'));
      expect(ua, isNot(contains('  ')));
      expect(ua, isNot(contains('( ')));
      expect(ua, isNot(contains(' )')));
    });

    test('真浏览器 UA 原样返回', () {
      const chrome =
          'Mozilla/5.0 (Linux; Android 14; Pixel 8) '
          'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 '
          'Mobile Safari/537.36';
      expect(cleanWebViewUserAgent(chrome), chrome);
    });

    test('Windows WebView2 的 UA 本来就没有标记，原样返回', () {
      expect(
        cleanWebViewUserAgent(kDesktopChromeUserAgent),
        kDesktopChromeUserAgent,
      );
    });

    test('空串不炸', () {
      expect(cleanWebViewUserAgent(''), '');
    });
  });
}

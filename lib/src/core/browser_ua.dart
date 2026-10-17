/// 浏览器标识（User-Agent）处理。
///
/// 为什么需要：Google 拒绝在任何「嵌入式浏览器」里完成登录（提示「此浏览器或
/// 应用可能不安全」），判定的首要依据就是 UA 里的 WebView 标记 —— `; wv` 与
/// `Version/4.0`。Android WebView 的默认 UA 长这样：
///
///     Mozilla/5.0 (Linux; Android 14; Pixel 8 Build/UP1A) AppleWebKit/537.36
///     (KHTML, like Gecko) Version/4.0 Chrome/141.0.0.0 Mobile Safari/537.36
///
/// 同一台设备上的 Chrome 既没有 `Version/4.0`，也没有 `; wv`。把它们抹掉之后，
/// UA 里的平台、机型、Chrome 版本仍然与系统真实值一致（Client Hints 也对得上）
/// —— 不伪造另一台设备，只删掉标记本身，比整段换成桌面 UA 更不容易露馅。
library;

/// 抹掉 WebView 指纹，得到浏览器形状的 UA。
///
/// 只处理带 `; wv` 标记的 UA（Android WebView / 部分定制内核）；Windows 的
/// WebView2 与 iOS 的 WKWebView 本来就没有这个标记，原样返回。
String cleanWebViewUserAgent(String ua) {
  if (!ua.contains('; wv')) return ua;
  final cleaned = ua
      // `; wv)` / `; wv;` → 去掉标记本身
      .replaceAll(RegExp(r';\s*wv(?=[;)])'), '')
      // `Version/4.0` 只有 Android WebView 会带
      .replaceAll(RegExp(r'\s*Version/\d+(?:\.\d+)*\s*'), ' ')
      .replaceAll(RegExp(r'\s{2,}'), ' ')
      .replaceAll(RegExp(r'\(\s+'), '(')
      .replaceAll(RegExp(r'\s+\)'), ')')
      .trim();
  return cleaned;
}

/// 桌面 Chrome 的 UA。
///
/// 有些时候反而需要「看起来像桌面浏览器」（X 的桌面登录页更直白），
/// 登录页右上角的切换按钮用它兜底。
const String kDesktopChromeUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36';

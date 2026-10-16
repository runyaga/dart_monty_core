// Which engine a browser test runs on, from its user agent. Pure Dart.

/// The engine families the web tests distinguish.
enum BrowserFamily {
  /// Chrome, Edge and other Blink browsers.
  chromium,

  /// Firefox (SpiderMonkey).
  firefox,

  /// Safari (JavaScriptCore).
  safari,

  /// Anything else.
  other,
}

/// The [BrowserFamily] a `navigator.userAgent` string belongs to.
///
/// Chrome's string also says "Safari", so Safari is what carries a Safari
/// token and none of the others.
BrowserFamily browserFamily(String userAgent) {
  if (userAgent.contains('Firefox/')) return BrowserFamily.firefox;
  if (userAgent.contains('Chrome/') ||
      userAgent.contains('Chromium/') ||
      userAgent.contains('Edg/')) {
    return BrowserFamily.chromium;
  }
  if (userAgent.contains('Safari/')) return BrowserFamily.safari;

  return BrowserFamily.other;
}

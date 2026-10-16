import 'package:test/test.dart';

import '_browser_family.dart';

void main() {
  test('a user agent names its engine family', () {
    const chrome =
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/155.0.0 Safari/537.36';
    const edge = '$chrome Edg/155.0.0';
    const firefox =
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:150.0) '
        'Gecko/20100101 Firefox/150.0';
    const safari =
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 '
        '(KHTML, like Gecko) Version/26.6 Safari/605.1.15';

    expect(browserFamily(chrome), BrowserFamily.chromium);
    expect(browserFamily(edge), BrowserFamily.chromium);
    expect(browserFamily(firefox), BrowserFamily.firefox);
    expect(browserFamily(safari), BrowserFamily.safari);
    expect(browserFamily('curl/8.0'), BrowserFamily.other);
  });
}

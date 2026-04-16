#!/usr/bin/env python3
"""
Patch Flutter's web/index.html for the dart_monty_core GitHub Pages deploy:

  1. Remove any stale coi-serviceworker — prior deployments may have registered
     one with a scope broad enough to cover /flutter/, breaking the page on load.
  2. Inject dart_monty_bridge.js before flutter_bootstrap.js so that
     window.DartMontyBridge exists before any Dart code runs.

Usage:
    python3 tool/inject_flutter_html.py packages/dart_monty_flutter/web/index.html
"""
import re
import sys

CLEANUP_SCRIPT = """\
<script>
/* Remove any stale coi-serviceworker from prior deployments.
   Earlier builds placed coi-serviceworker.js at a scope covering /flutter/,
   causing it to intercept Flutter's own fetch requests and break the page. */
(function () {
  if (!('serviceWorker' in navigator)) return;
  navigator.serviceWorker.getRegistration().then(function (reg) {
    if (!reg) return;
    var url = (reg.active || reg.installing || reg.waiting || {}).scriptURL || '';
    if (url.includes('coi-serviceworker')) {
      console.log('[dart_monty] Removing stale coi-serviceworker, reloading...');
      reg.unregister().then(function () { location.reload(); });
    }
  });
})();
</script>
"""

BRIDGE_TAG = '<script src="dart_monty_bridge.js"></script>\n  '


def patch(path: str) -> None:
    with open(path) as f:
        html = f.read()

    patched = re.sub(
        r'(<script src="flutter_bootstrap\.js")',
        CLEANUP_SCRIPT + BRIDGE_TAG + r'\1',
        html,
    )

    if patched == html:
        print(
            f'[inject_flutter_html] WARNING: no match in {path} — '
            'flutter_bootstrap.js not found?',
            file=sys.stderr,
        )
        sys.exit(1)

    with open(path, 'w') as f:
        f.write(patched)

    print(f'[inject_flutter_html] Patched {path}')


if __name__ == '__main__':
    target = sys.argv[1] if len(sys.argv) > 1 else 'web/index.html'
    patch(target)

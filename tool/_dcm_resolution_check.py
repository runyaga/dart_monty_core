import json, os, sys
from urllib.parse import urlparse, unquote

pc = '.dart_tool/package_config.json'
if not os.path.exists(pc):
    print('DANGLING:missing')
    sys.exit(0)
try:
    d = json.load(open(pc))
except Exception:
    print('DANGLING:unparseable')
    sys.exit(0)

bad = []
for p in d.get('packages', []):
    uri = p.get('rootUri', '')
    # Only ABSOLUTE file: URIs are machine-specific. A relative rootUri
    # (the self-package's "../") resolves inside this tree and is always fine.
    if not uri.startswith('file:///'):
        continue
    path = unquote(urlparse(uri).path)
    if not os.path.isdir(path):
        bad.append((p.get('name', '?'), path))

if bad:
    print('DANGLING:%d' % len(bad))
    for name, path in bad[:3]:
        print('  %s -> %s' % (name, path))

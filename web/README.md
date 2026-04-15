# Monty Web REPL Demo

This directory contains a simple REPL demo for Monty, capable of being compiled
with both **dart2js** and **dart2wasm**.

## Compilation

### dart2js
```bash
dart compile js web/repl_demo.dart -o web/repl_demo.dart.js
```

### dart2wasm
```bash
dart compile wasm web/repl_demo.dart -o web/repl_demo.wasm
```

## Serving

The demo requires COOP/COEP headers for `SharedArrayBuffer` support in the WASM
Worker. Use the following Python command to serve the `web/` directory:

```bash
python3 -c '
import http.server, functools, os
class H(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Access-Control-Allow-Origin", "*")
        super().end_headers()
    def guess_type(self, path):
        if str(path).endswith(".mjs"): return "application/javascript"
        if str(path).endswith(".wasm"): return "application/wasm"
        return super().guess_type(path)
http.server.HTTPServer(("127.0.0.1", 8080), H).serve_forever()
'
```

Then visit:
- **dart2js:** [http://localhost:8080/index_js.html](http://localhost:8080/index_js.html)
- **dart2wasm:** [http://localhost:8080/index_wasm.html](http://localhost:8080/index_wasm.html)

## Assets

Before running, ensure you have built the JS bridge and copied the assets:
```bash
# 1. Build bridge
cd js && npm install && npm run build && cd ..

# 2. Copy assets to web/
cp assets/* web/
```

### Internal

- Refactor telemetry rendering and callback state without changing the public API. Check adapter failure diagnostics across compilers and exercise host telemetry, lazy attributes, asynchronous methods, error encodings, and worker stream failures.

- Keep streamed-print assertions in the shared telemetry test body, and separate native turn recording and crash classification to meet code metrics without changing runtime behaviour.

// WASM binding for the REPL futures shared test body.
@Tags(['integration', 'wasm'])
library;

import 'package:test/test.dart';

import '_repl_futures_test_body.dart';

void main() => runReplFuturesTests();

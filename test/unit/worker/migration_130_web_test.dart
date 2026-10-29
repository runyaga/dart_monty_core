// The 1.3.0 migration cases against the COMMITTED
// lib/assets/dart_monty_core_worker.{js,wasm} in Chrome, on dart2js and
// dart2wasm: the cases that must change with the worker, run on the browser
// exactly as the VM runner runs them.
//
//   bash tool/test_worker_web.sh
@TestOn('browser')
@Tags(['worker'])
library;

import 'package:dart_monty_core/src/worker/monty.dart';
import 'package:test/test.dart';

import '_migration_130_cases.dart';

/// The backend this file runs on: `dart2js` or `dart2wasm`.
const _backend = identical(1, 1.0) ? 'dart2js' : 'dart2wasm';

void main() => migration130SessionTests(_backend, startMonty);

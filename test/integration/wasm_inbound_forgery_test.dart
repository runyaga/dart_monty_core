// WASM binding for the inbound-forgery probe (core#136 / core#139).
//
// The web half is not a formality. The two backends reach the interpreter
// through different drive loops and different bindings adapters, and the raw
// encode sites this probe covers lived in the loop they SHARE — so a fix
// verified on one says nothing about the other until this runs green too.
@Tags(['integration', 'wasm'])
library;

import 'package:test/test.dart';

import '_inbound_forgery_test_body.dart';

void main() => runInboundForgeryTests();

// FFI binding for the inbound-forgery probe (core#136 / core#139).
@Tags(['integration', 'ffi'])
library;

import 'package:test/test.dart';

import '_inbound_forgery_test_body.dart';

void main() => runInboundForgeryTests();

// Matchers the codec spec tests share. One definition each, so a test body
// states what it checks and does not repeat the same invocation.
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

final Matcher isBigInt = isA<MontyBigInt>();
final Matcher isInt = isA<MontyInt>();
final Matcher isString = isA<MontyString>();
final Matcher isBytes = isA<MontyBytes>();
final Matcher hasOne = hasLength(1);
final Matcher hasTwo = hasLength(2);

/// A scriptable session for testing host code without a worker (C4 API3).
///
/// Internal until the cutover, when `dart_monty_core_testing.dart` exports
/// [FakeMontySession] as its only name; until then it takes host functions
/// in the session's internal map (C4 pre-cutover.md).
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:dart_monty_core/src/fake_answers.dart';
import 'package:dart_monty_core/src/platform/monty_value.dart';
import 'package:dart_monty_core/src/worker/monty_snapshot.dart';
import 'package:dart_monty_core/src/worker/pool_session.dart';
import 'package:dart_monty_core/src/worker/proto_session.dart';

/// A session that plays a script where a worker would run Python. Not yet
/// implemented: every member throws [UnimplementedError].
final class FakeMontySession implements PoolSession {
  /// A session with nothing scripted.
  FakeMontySession();

  /// Scripts a call to the host function [name].
  int willCall(
    String name, {
    List<MontyValue> args = const [],
    Map<String, MontyValue> kwargs = const {},
    bool eager = false,
  }) => throw UnimplementedError();

  /// Scripts the OS call [name].
  int willCallOs(
    String name, {
    List<MontyValue> args = const [],
    Map<String, MontyValue> kwargs = const {},
    bool eager = false,
  }) => throw UnimplementedError();

  /// Scripts a lookup of [name].
  void willLookUp(String name) => throw UnimplementedError();

  /// Scripts an await on [callIds].
  void willAwait(List<int> callIds, {bool gathered = false}) =>
      throw UnimplementedError();

  /// Scripts a print.
  void willPrint(String text, {String stream = 'stdout'}) =>
      throw UnimplementedError();

  /// Scripts the feed's value.
  void willReturn(MontyValue value) => throw UnimplementedError();

  /// Scripts an uncaught exception.
  void willRaise(
    String excType, {
    String? message,
    Map<String, MontyValue> attributes = const {},
    int? line,
    int? column,
  }) => throw UnimplementedError();

  /// Scripts Python catching the exception before.
  void willCatch() => throw UnimplementedError();

  /// Scripts a turn held in flight until [gate] completes.
  void willHold(Future<void> gate) => throw UnimplementedError();

  /// Scripts the worker dying.
  void willCrash({bool timedOut = false}) => throw UnimplementedError();

  /// The code of each feed.
  List<String> get feeds => throw UnimplementedError();

  /// The host's answers.
  List<FakeAnswer> get answers => throw UnimplementedError();

  /// Whether close has run.
  bool get isClosed => throw UnimplementedError();

  @override
  Future<MontyValue> feedRun(
    String code, {
    Map<String, MontyValue>? inputs,
    Map<String, ProtoExternalFunction>? externals,
    ProtoPrintCallback? printCallback,
    OsHandler? os,
    bool skipTypeCheck = false,
  }) => throw UnimplementedError();

  @override
  Future<MontySnapshot> feedStart(
    String code, {
    Map<String, MontyValue>? inputs,
    Map<String, ProtoExternalFunction>? externals,
    ProtoPrintCallback? printCallback,
    OsHandler? os,
    bool skipTypeCheck = false,
  }) => throw UnimplementedError();

  @override
  Future<void> loadSession(Uint8List state) => throw UnimplementedError();

  @override
  Future<MontySnapshot> loadSnapshot(
    Uint8List state, {
    Map<String, ProtoExternalFunction>? externals,
    ProtoPrintCallback? printCallback,
    OsHandler? os,
  }) => throw UnimplementedError();

  @override
  Future<Uint8List> dump() => throw UnimplementedError();

  @override
  int? get workerPid => throw UnimplementedError();

  @override
  Future<void> close() => throw UnimplementedError();
}

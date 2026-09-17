// A failed call must leave the platform IDLE, not wedged active.
//
// ffi_state_guards_test.dart covers the refusals -- disposed refuses, and
// not-active refuses. Nothing covered the RECOVERY: the `markIdle()` in the
// catch arms of start() and resumeNameLookup(), base_monty_platform.dart:182
// and :396, plus the MontyException builder at :452-455. All uncovered on the
// gate's own coverage/honest.info.
//
// The consequence of losing one of those `markIdle()` calls is not a bad error
// message. It is a platform that reports "not idle" for the rest of its life
// after one failure, and the caller has no way to reset it short of dispose().
@Tags(['integration', 'ffi'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/ffi/monty_ffi.dart';
import 'package:test/test.dart';

void main() {
  test('a start() that throws does not wedge the platform', () async {
    final m = MontyFfi();
    addTearDown(m.dispose);

    // markActive() has already run by the time this fails, so the catch arm
    // is the only thing that returns the platform to idle.
    await expectLater(
      m.start('def ((('),
      throwsA(isA<MontyError>()),
    );

    // The proof is that an ORDINARY call works afterwards. Without the
    // markIdle() in the catch, assertIdle() refuses this and the platform is
    // unusable until disposed.
    final after = await m.run('6 * 7');
    expect(after.ok, isTrue);
    expect(after.value, const MontyInt(42));
  });

  test('a failing resumeNameLookup does not wedge the platform', () async {
    final m = MontyFfi();
    addTearDown(m.dispose);

    final pending = await m.start('fetch(1)', externalFunctions: ['fetch']);
    expect(pending, isA<MontyPending>());

    // The engine refuses because the handle is in Pending, not NameLookup --
    // measured: "handle not in NameLookup state".
    //
    // WHAT THIS DOES AND DOES NOT PIN, stated because I checked. It pins that
    // the platform is usable afterwards. It does NOT pin the `markIdle()` in
    // resumeNameLookup's catch arm (base_monty_platform.dart:396): removing
    // that line leaves this test green. `translateProgress`'s `case 'error':`
    // already calls markIdle() at :365 before `_throwError`, so on every path
    // an engine-reported error can take, :396 is redundant. Reaching it needs
    // a throw that BYPASSES translateProgress -- a binding-level failure --
    // which this backend does not produce here.
    //
    // Left in as a behavioural test rather than deleted: "a failed name-lookup
    // resume does not wedge the platform" is worth holding regardless of which
    // line implements it.
    await expectLater(
      m.resumeNameLookup('fetch', 1),
      throwsA(isA<MontyError>()),
    );

    expect((await m.run('1 + 1')).value, const MontyInt(2));
  });

  test('a raised exception carries its type, message and frames', () async {
    // _toMontyException builds this only when the result carries an error.
    // A platform that reported the message but dropped the traceback would
    // still satisfy `ok == false`, and the caller would lose the one thing
    // that makes a Python failure debuggable.
    final m = MontyFfi();
    addTearDown(m.dispose);

    await expectLater(
      m.run('def inner():\n    raise KeyError("missing key")\ninner()\n'),
      throwsA(
        isA<MontyScriptError>().having(
          (e) => e.exception,
          'exception',
          isA<MontyException>()
              .having((x) => x.excType, 'excType', 'KeyError')
              .having((x) => x.message, 'message', contains('missing key'))
              .having((x) => x.traceback, 'traceback', isNotEmpty),
        ),
      ),
    );
  });
}

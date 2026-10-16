// The suspension and sleep budgets of one checkout
// (`SessionBudget` in lib/src/worker/monty_session.dart): counting and charging per checkout,
// limits a reply can only tighten, and upstream's rules for loading a dump
// (monty-pool 1.1.0 checkout.rs: `forget` keeps both limits as ceilings and
// restarts the counts, `update_from` takes the minimum, and a re-announced
// suspension counts and charges itself again; `begin_load`/`end_load` and
// `abort_if_over_budget` decide which budget a load leaves). No worker runs.
// Pure Dart: vm, dart2js and dart2wasm.
import 'dart:math' as math;

import 'package:dart_monty_core/src/worker/monty_session.dart';
import 'package:dart_monty_core/src/worker/os_policy.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/proto_session.dart';
import 'package:dart_monty_core/src/worker/resource_limits.dart';
import 'package:fixnum/fixnum.dart';
import 'package:test/test.dart';

pb.ChildEvent _call({int? reports}) => pb.ChildEvent(
  functionCall: pb.FunctionCall(functionName: 'f', callId: 1),
  maxSuspensions: reports == null ? null : Int64(reports),
);

pb.ChildEvent _sleep(double seconds) => pb.ChildEvent(
  osCall: pb.OsCall(callId: 2, systemSleep: pb.OsCall_Sleep(seconds: seconds)),
);

/// An `Ok`, reporting the limits given (micros for the sleep limit).
pb.ChildEvent _ok({int? suspensions, int? sleepMicros}) => pb.ChildEvent(
  ok: pb.Ok(),
  maxSuspensions: suspensions == null ? null : Int64(suspensions),
  maxTotalSleepMicros: sleepMicros == null ? null : Int64(sleepMicros),
);

pb.ChildEvent _error({int? suspensions, int? feedMicros}) => pb.ChildEvent(
  error: pb.Error(
    exception: pb.RaisedException(excType: 'ValueError', message: 'bad dump'),
  ),
  maxSuspensions: suspensions == null ? null : Int64(suspensions),
  feedExecutionMicros: feedMicros == null ? null : Int64(feedMicros),
);

SessionBudget _budget({int? maxSuspensions, Duration? maxTotalSleep}) =>
    SessionBudget(
      SessionConfig(
        limits: ResourceLimits(
          maxSuspensions: maxSuspensions,
          maxTotalSleep: maxTotalSleep,
        ),
      ),
    );

/// [n] milliseconds in nanoseconds.
BigInt _ms(int n) => BigInt.from(n) * BigInt.from(1000000);

/// Each of [events] admitted to [budget] in turn: null where it passes,
/// else the abort as `Type: message`.
List<String?> _admit(SessionBudget budget, List<pb.ChildEvent> events) => [
  for (final event in events)
    if (budget.admit(event) case final abort?)
      '${abort.excType}: ${abort.message}'
    else
      null,
];

/// What [budget] holds: its two limits, then its two counts.
(int, BigInt?, int, BigInt) _state(SessionBudget budget) => (
  budget.suspensionLimit,
  budget.sleepLimit,
  budget.suspensions,
  budget.slept,
);

/// Whether ints are JavaScript numbers (dart2js).
const bool _jsInts = identical(0, 0.0);

const String _over2 = 'RuntimeError: suspension limit 2 exceeded';

/// A host-function call that reports no limit; admitting it changes nothing
/// in it, so one serves every turn.
final pb.ChildEvent _f = _call();

void main() {
  group('counting', () {
    test('null keeps the default 1000; no sleep limit', () {
      expect(
        _state(SessionBudget(const SessionConfig())),
        (defaultMaxSuspensions, null, 0, BigInt.zero),
      );
    });

    test('the suspension past the limit aborts; the count is kept', () {
      final budget = _budget(maxSuspensions: 2);
      // A later feed's suspension counts on: the budget is the checkout's.
      expect(
        _admit(budget, [_f, _ok(), _f, _f, _f]),
        [null, null, null, _over2, _over2],
      );
      expect(budget.suspensions, 4);
    });

    test('0: the first suspension aborts', () {
      expect(_admit(_budget(maxSuspensions: 0), [_ok(), _call()]), [
        null,
        'RuntimeError: suspension limit 0 exceeded',
      ]);
    });

    test('the suspension limit is checked before the sleep is charged', () {
      final budget = _budget(
        maxSuspensions: 0,
        maxTotalSleep: const Duration(milliseconds: 10),
      );
      expect(_admit(budget, [_sleep(1)]), [
        'RuntimeError: suspension limit 0 exceeded',
      ]);
      expect(budget.slept, BigInt.zero);
    });

    test('a sleep past the sleep limit aborts uncharged', () {
      final budget = _budget(maxTotalSleep: const Duration(milliseconds: 100));
      expect(_admit(budget, [_sleep(0.04), _sleep(0.07)]), [
        null,
        'TimeoutError: sleep limit exceeded: 110ms > 100ms',
      ]);
      expect(budget.slept, _ms(40));
    });

    test('a sleep is charged at most the system-sleep maximum', () {
      final budget = SessionBudget(
        const SessionConfig(
          osPolicy: OsPolicy(sleepSystemMax: Duration(milliseconds: 20)),
        ),
      );
      expect(_admit(budget, [_sleep(30), _sleep(double.nan)]), [null, null]);
      expect(budget.slept, _ms(40));
    });
  });

  group('a reply only tightens', () {
    test('a smaller suspension limit is adopted; a larger one is not', () {
      final budget = _budget(maxSuspensions: 5)..admit(_ok(suspensions: 9));
      final larger = budget.suspensionLimit;
      budget.admit(_ok(suspensions: 3));
      expect((larger, budget.suspensionLimit), (5, 3));
    });

    test('u64::MAX is the largest, not -1', () {
      final budget = _budget(maxSuspensions: 5);
      expect(_admit(budget, [_call(reports: -1)]), [null]);
      expect(budget.suspensionLimit, 5);
    });

    test('a limit of 2^63 or more (dart2js) is tightened unsigned', () {
      // Only dart2js holds such an int, and validate accepts it below 2^64.
      final huge = math.pow(2, 63).toInt();
      final budget = _budget(maxSuspensions: huge);
      expect(_admit(budget, [_call(reports: 1), _f]), [
        null,
        'RuntimeError: suspension limit 1 exceeded',
      ]);
    }, skip: _jsInts ? false : 'an int holds 2^63 only on dart2js');

    test('a sleep limit is adopted where there was none, then tightened', () {
      final budget = _budget();
      final seen = [
        // The third is u64::MAX microseconds, unsigned.
        for (final micros in [200000, 300000, -1, 50000])
          (budget..admit(_ok(sleepMicros: micros))).sleepLimit,
      ];
      final ms200 = _ms(200);
      expect(seen, [ms200, ms200, ms200, _ms(50)]);
    });
  });

  group('loading a dump', () {
    test('the counts restart; the limits stay as ceilings', () {
      final budget =
          _budget(
              maxSuspensions: 3,
              maxTotalSleep: const Duration(milliseconds: 100),
            )
            ..admit(_f)
            ..admit(_f)
            ..admit(_sleep(0.05))
            ..beginLoad();
      final fresh = (3, _ms(100), 0, BigInt.zero);
      final loading = _state(budget);
      // An idle dump reporting looser limits than the checkout's.
      budget
        ..admit(_ok(suspensions: 10, sleepMicros: 500000))
        ..endLoad();
      expect([loading, _state(budget)], [fresh, fresh]);
      // The full budget again, from zero.
      expect(_admit(budget, [_f, _f, _f, _f]), [
        null,
        null,
        null,
        'RuntimeError: suspension limit 3 exceeded',
      ]);
    });

    test("the dump's tighter limits are adopted", () {
      final budget =
          _budget(
              maxSuspensions: 10,
              maxTotalSleep: const Duration(seconds: 1),
            )
            ..beginLoad()
            ..admit(_ok(suspensions: 2, sleepMicros: 20000))
            ..endLoad();
      expect(_state(budget), (2, _ms(20), 0, BigInt.zero));
    });

    test("no sleep limit on the checkout: the dump's is adopted", () {
      final budget = _budget()
        ..beginLoad()
        ..admit(_ok(sleepMicros: 30000))
        ..endLoad();
      expect(budget.sleepLimit, _ms(30));
    });

    test('a re-announced suspension counts', () {
      final budget = _budget(maxSuspensions: 2)
        ..admit(_f)
        ..admit(_f)
        ..beginLoad();
      final reannounced = _admit(budget, [_call(reports: 2)]);
      budget.endLoad();
      expect(reannounced, [null]);
      expect(budget.suspensions, 1);
      expect(_admit(budget, [_f, _f]), [null, _over2]);
    });

    test('a re-announced suspension past a limit of 0 aborts', () {
      final budget = _budget(maxSuspensions: 0)..beginLoad();
      expect(_admit(budget, [_call(reports: 1000)]), [
        'RuntimeError: suspension limit 0 exceeded',
      ]);
    });

    test('a re-announced sleep is charged again', () {
      final budget = _budget(maxTotalSleep: const Duration(milliseconds: 100))
        ..admit(_sleep(0.09))
        ..beginLoad();
      expect(_admit(budget, [_sleep(0.06), _sleep(0.05)]), [
        null,
        'TimeoutError: sleep limit exceeded: 110ms > 100ms',
      ]);
      expect(budget.slept, _ms(60));
    });

    test('a load refused with an error: the old budget comes back', () {
      final budget = _budget(maxSuspensions: 5)
        ..admit(_f)
        ..admit(_f);
      final before = _state(budget);
      budget
        ..beginLoad()
        ..admit(_error())
        ..endLoad();
      expect(_state(budget), before);
    });

    test('the old budget comes back, then the reply tightens it', () {
      final budget = _budget(maxSuspensions: 5)
        ..admit(_f)
        ..beginLoad()
        ..admit(_error(suspensions: 4))
        ..endLoad();
      expect(_state(budget), (4, null, 1, BigInt.zero));
    });

    test('no reply at all: the old budget comes back', () {
      final budget =
          _budget(
              maxSuspensions: 5,
              maxTotalSleep: const Duration(seconds: 1),
            )
            ..admit(_f)
            ..admit(_sleep(0.25));
      final before = _state(budget);
      budget
        ..beginLoad()
        ..endLoad();
      expect(_state(budget), before);
    });

    test('a settled load is not undone by endLoad', () {
      final budget = _budget(maxSuspensions: 5)
        ..admit(_f)
        ..beginLoad()
        ..admit(_ok())
        ..endLoad()
        ..endLoad();
      expect(budget.suspensions, 0);
    });
  });

  group('duration budgets: the dump keeps its own (O9)', () {
    /// An event reporting the feed and turn budgets given, in micros.
    pb.ChildEvent reporting(pb.ChildEvent event, {int? feed, int? turn}) {
      if (feed != null) event.maxFeedDurationMicros = Int64(feed);
      if (turn != null) event.maxTurnDurationMicros = Int64(turn);

      return event;
    }

    SessionBudget timed({Duration? feed, Duration? turn}) => SessionBudget(
      SessionConfig(
        limits: ResourceLimits(maxFeedDuration: feed, maxTurnDuration: turn),
      ),
    );

    (Duration?, Duration?) budgets(SessionBudget budget) =>
        (budget.feedBudget, budget.turnBudget);

    const second = Duration(seconds: 1);
    const ms = Duration(milliseconds: 1);

    test("the session's limits; none without", () {
      expect(budgets(timed(feed: second, turn: ms)), (second, ms));
      expect(budgets(timed()), (null, null));
      expect(budgets(SessionBudget(const SessionConfig())), (null, null));
    });

    test('a reply sets a budget only where there is none', () {
      // update_from: `if self.feed_budget.is_none()`; a budget in force is
      // never changed, larger or smaller.
      const seven = Duration(microseconds: 7);
      final budget = timed(feed: second);
      final states = <(Duration?, Duration?)>[];
      for (final (feed, turn) in [(5, 7), (10000000, 1)]) {
        budget.admit(reporting(_ok(), feed: feed, turn: turn));
        states.add(budgets(budget));
      }
      expect(states, [(second, seven), (second, seven)]);
    });

    test("a load forgets the session's; the Load reply's are adopted", () {
      final budget = timed(feed: second, turn: second)
        ..beginLoad()
        ..admit(reporting(_ok(), feed: 2000000))
        ..endLoad();
      expect(budgets(budget), (const Duration(seconds: 2), null));
    });

    test('a re-announced suspension adopts them too', () {
      final budget = timed(feed: second)
        ..beginLoad()
        ..admit(reporting(_call(), turn: 3000))
        ..endLoad();
      expect(budgets(budget), (null, const Duration(milliseconds: 3)));
    });

    test("a refused load puts the session's back", () {
      final budget = timed(feed: second, turn: ms)
        ..beginLoad()
        ..admit(reporting(_error(), feed: 5, turn: 5));
      expect(budgets(budget), (second, ms));
    });

    test('a rejected load restores its feed clock', () {
      final budget = timed(feed: const Duration(seconds: 10));
      final beforeLoad = _ok()..feedExecutionMicros = Int64(8000000);
      final rejected = _error(feedMicros: 4000000);
      budget
        ..admit(beforeLoad)
        ..beginLoad()
        ..admit(rejected)
        ..endLoad();

      final used = (budget as dynamic).reportedFeedExecution as Duration;
      expect(used, const Duration(seconds: 8));
      expect(
        const Duration(seconds: 10) - used + const Duration(seconds: 1),
        const Duration(seconds: 3),
      );
    });

    test("no reply at all: endLoad puts the session's back", () {
      final budget = timed(feed: second)
        ..beginLoad()
        ..endLoad();
      expect(budgets(budget), (second, null));
    });

    test('a reported u64 past what a Duration holds is a budget, not '
        'negative', () {
      final budget = timed()..admit(reporting(_ok(), feed: -1, turn: -1));
      final (feed, turn) = budgets(budget);
      expect(feed?.isNegative, isFalse);
      expect(turn, feed);
      expect(feed, greaterThan(const Duration(days: 365 * 280)));
    });
  });
}

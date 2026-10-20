// Exercise defensive wire refusals below the public fake-session validation.
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/fake_script.dart';
import 'package:dart_monty_core/src/fake_worker.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:test/test.dart';

void main() {
  test(
    'answers without a suspension and kindless requests are refused',
    () async {
      final worker = FakeWorker(FakeScript());
      addTearDown(worker.close);
      for (final request in [
        pb.ParentRequest(),
        pb.ParentRequest(resumeCall: pb.ResumeCall()),
      ]) {
        await expectLater(
          worker.turn(request),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('answers no scripted suspension'),
            ),
          ),
        );
      }
    },
  );
  test('a mismatched answer cannot advance a pending name lookup', () async {
    final worker = FakeWorker(
      FakeScript()
        ..add(const FakeLookup('x'))
        ..add(const FakeReturn(MontyNone())),
    );
    addTearDown(worker.close);
    expect(
      (await worker.turn(pb.ParentRequest(feed: pb.Feed()))).nameLookup.name,
      'x',
    );
    await expectLater(
      worker.turn(pb.ParentRequest(resumeCall: pb.ResumeCall())),
      throwsStateError,
    );
  });
  test(
    'a host exception answering a name lookup is returned to Python',
    () async {
      final worker = FakeWorker(
        FakeScript()
          ..add(const FakeLookup('x'))
          ..add(const FakeReturn(MontyNone())),
      );
      addTearDown(worker.close);
      await worker.turn(pb.ParentRequest(feed: pb.Feed()));
      final result = await worker.turn(
        pb.ParentRequest(
          resumeNameLookup: pb.ResumeNameLookup(
            error: pb.RaisedException(excType: 'KeyError', message: 'missing'),
          ),
        ),
      );
      final exception = result.error.exception;
      expect(exception.excType, 'KeyError');
      expect(exception.message, 'missing');
    },
  );
  test('an await of an unscripted call explains the missing id', () async {
    final worker = FakeWorker(
      FakeScript()
        ..add(const FakeAwait([7], gathered: false))
        ..add(const FakeReturn(MontyNone())),
    );
    addTearDown(worker.close);
    await expectLater(
      worker.turn(pb.ParentRequest(feed: pb.Feed())),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('has not made'),
        ),
      ),
    );
  });
  test(
    'an OS call answer with no result is declined',
    () async {
      final worker = FakeWorker(
        FakeScript()
          ..add(
            FakeCall(
              'os.getenv',
              0,
              pb.ChildEvent(
                osCall: pb.OsCall(
                  getenv: pb.OsCall_Getenv(key: 'X'),
                  values: pb.Arena(nodes: [pb.MontyNode(none: pb.Unit())]),
                ),
              ),
              eager: false,
            ),
          )
          ..add(const FakeReturn(MontyNone())),
      );
      addTearDown(worker.close);
      await worker.turn(pb.ParentRequest(feed: pb.Feed()));
      final result = await worker.turn(
        pb.ParentRequest(resumeCall: pb.ResumeCall()),
      );
      final exception = result.error.exception;
      expect(exception.excType, 'RuntimeError');
      expect(exception.message, contains('not supported'));
    },
  );
  test(
    'oversized requests preserve the script and skip serialization',
    () async {
      final worker = FakeWorker(
        FakeScript()..add(const FakeReturn(MontyInt(42))),
      );
      addTearDown(worker.close);
      // Shared small strings make a huge encoded frame without allocating it.
      final node = pb.MontyNode(str: 'x' * (1 << 20));
      final request = pb.ParentRequest(
        feed: pb.Feed(values: pb.Arena(nodes: List.filled(257, node))),
      );
      await expectLater(
        worker.turn(request),
        throwsA(isA<FrameTooLargeException>()),
      );
      final result = await worker.turn(pb.ParentRequest(feed: pb.Feed()));
      expect(result.whichKind(), pb.ChildEvent_Kind.complete);
      expect(worker.feeds, hasLength(1));
    },
  );
}

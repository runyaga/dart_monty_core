/// What a host answered, read back from the requests it sent: the recording
/// `FakeMontySession` keeps, and the contract suite takes from a real
/// session's channel to compare with it.
///
/// Internal to the package; nothing here is exported.
library;

import 'package:dart_monty_core/src/worker/arena_reader.dart';
import 'package:dart_monty_core/src/worker/monty_snapshot.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/raised_record.dart';

/// One host answer recorded by a fake session.
///
/// `callId` is null for a lookup. `batch` is null for a call or lookup,
/// restarts at zero for each feed, and is shared by futures settled in the
/// same batch. `answer` is null for `not_found`, `not_handled`, or an
/// undefined name. The type stays internal, but these fields are the public
/// testing contract.
typedef FakeAnswer = ({int? callId, int? batch, ExternalResult? answer});

/// The answers in the requests a session sends, in order.
final class FakeAnswers {
  /// The answers so far.
  final List<FakeAnswer> answers = [];

  int _batch = 0;

  /// Records the answers [request] carries. A feed restarts the batch
  /// numbering, as call ids restart with each feed.
  void add(pb.ParentRequest request) {
    switch (request.whichKind()) {
      case pb.ParentRequest_Kind.feed:
        _batch = 0;
      case pb.ParentRequest_Kind.resumeCall:
        final resume = request.resumeCall;
        answers.add((
          callId: resume.callId,
          batch: null,
          answer: resultOf(resume.result, resume.values),
        ));
      case pb.ParentRequest_Kind.resumeNameLookup:
        answers.add((
          callId: null,
          batch: null,
          answer: lookupOf(request.resumeNameLookup),
        ));
      case pb.ParentRequest_Kind.resumeFutures:
        final batch = _batch++;
        final resume = request.resumeFutures;
        for (final result in resume.results) {
          answers.add((
            callId: result.callId,
            batch: batch,
            answer: resultOf(result.result, resume.values),
          ));
        }
      // ignore: no_default_cases, the other requests carry no answer.
      default:
    }
  }
}

/// The answer [result] carries, its values in [values].
ExternalResult? resultOf(pb.ExtFunctionResult result, pb.Arena values) =>
    switch (result.whichKind()) {
      pb.ExtFunctionResult_Kind.returnValue => ExternalReturnValue(
        ArenaReader(values)[result.returnValue],
      ),
      pb.ExtFunctionResult_Kind.error => exceptionOf(result.error),
      pb.ExtFunctionResult_Kind.future => const ExternalFuture(),
      pb.ExtFunctionResult_Kind.notFound ||
      pb.ExtFunctionResult_Kind.notHandled ||
      pb.ExtFunctionResult_Kind.notSet => null,
    };

/// The answer [lookup] carries: the bound value, the exception, or null for
/// an undefined name.
ExternalResult? lookupOf(pb.ResumeNameLookup lookup) => switch (lookup
    .whichKind()) {
  pb.ResumeNameLookup_Kind.value => ExternalReturnValue(
    ArenaReader(lookup.values)[lookup.value],
  ),
  pb.ResumeNameLookup_Kind.error => exceptionOf(lookup.error),
  pb.ResumeNameLookup_Kind.undefined || pb.ResumeNameLookup_Kind.notSet => null,
};

/// [raised] as the [ExternalException] a host sent.
ExternalException exceptionOf(pb.RaisedException raised) => ExternalException(
  raised.excType,
  raised.hasMessage() ? raised.message : null,
  raised.hasData() ? payloadOf(raised.data)?.attributes ?? const {} : const {},
);

/// Internal channel observation, installed by the shared session driver.
library;

import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/telemetry_recorder.dart';

/// Channels expose the two frame boundaries without changing their protocol.
abstract interface class TelemetryChannel {
  /// The checkout recorder, absent until instrumentation and checkout.
  Recorder? get recorder;
  set recorder(Recorder? value);

  /// Process id when the channel is native.
  int? get telemetryPid;
}

/// Storage for a concrete transport. No allocation without installation.
mixin RecordedChannel implements TelemetryChannel {
  @override
  Recorder? recorder;

  @override
  int? get telemetryPid => null;
}

/// Holds early events while the OS finishes flushing a request. Reading
/// stdout must continue: a child blocked writing it may not yet read stdin.
/// Delivery to the recorder starts only after the frame was fully sent.
final class SentRecording {
  /// One potentially in-flight native write, only with instrumentation.
  SentRecording(this._recorder, this._request);

  final Recorder _recorder;
  final pb.ParentRequest _request;
  List<pb.ChildEvent>? _early = [];
  bool? _sent;
  bool _dead = false;

  /// Confirms transmission, then records any events already read in order.
  void sent({required bool success}) {
    _sent = success;
    final early = _early;
    _early = null;
    if (!success) return;
    _recorder.beginTurn(_request);
    early?.forEach(_recorder.event);
    if (_dead) _recorder.close();
  }

  /// Reads never wait on writes; normal replies record immediately.
  void event(pb.ChildEvent event) {
    if (_sent == true) {
      _recorder.event(event);
    } else {
      _early?.add(event);
    }
  }

  /// A death can race the write's completion. Either ordering closes spans.
  void finish({required bool dead}) {
    _dead = dead;
    if (dead) _recorder.close();
  }
}

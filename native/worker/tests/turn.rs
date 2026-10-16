//! The reference is the pinned upstream dispatcher, not our framing helper.
use dart_monty_worker::turn::dispatch_owned;
use monty_proto::{
    MAX_FRAME_LEN,
    worker::{Child, VecEventSink, dispatch_frame},
};

#[test]
fn framing_matches_upstream_bytes_and_recovery() {
    let cases = [
        vec![],              // probe / clean EOF
        vec![1, 0],          // torn length
        vec![2, 0, 0, 0, 8], // torn payload
        (MAX_FRAME_LEN + 1).to_le_bytes().to_vec(),
        vec![0, 0, 0, 0],      // structurally valid, no request kind
        vec![1, 0, 0, 0, 255], // malformed protobuf
        vec![0, 0, 0, 0, 99],  // ignore trailing bytes, as upstream
    ];
    for frame in cases {
        let mut reference = Child::default();
        let mut subject = Child::default();
        let expected = dispatch_frame(&mut reference, &frame);
        let mut sink = VecEventSink::new();
        let outcome = dispatch_owned(&mut subject, frame.clone(), &mut sink);
        assert_eq!((sink.take(), outcome), expected, "frame {frame:?}");
        // Recovery state matters as well as the first response.
        let next = vec![0, 0, 0, 0];
        let expected = dispatch_frame(&mut reference, &next);
        let outcome = dispatch_owned(&mut subject, next, &mut sink);
        assert_eq!((sink.take(), outcome), expected);
    }
}

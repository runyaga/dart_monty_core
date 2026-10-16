//! Owned, streaming equivalent of monty-proto 1.1.0's private dispatch_into.
//! Only framing/recovery is reproduced; decode budgets and execution stay upstream.
use monty_proto::{
    FrameError, MAX_FRAME_LEN, decode_frame, pb,
    worker::{Child, EventSink, HandleOutcome, protocol_violation},
};

fn decode_request(frame: &[u8]) -> Result<Option<pb::ParentRequest>, FrameError> {
    if frame.is_empty() {
        return Ok(None);
    }
    let prefix = frame.get(..4).ok_or(FrameError::Truncated)?;
    let len = u32::from_le_bytes(prefix.try_into().expect("four-byte prefix"));
    if len > MAX_FRAME_LEN {
        return Err(FrameError::FrameTooLarge {
            len,
            max: MAX_FRAME_LEN,
        });
    }
    let body = frame.get(4..4 + len as usize).ok_or(FrameError::Truncated)?;
    decode_frame(body).map(Some)
}

/// Decode directly from the owned payload, release it, then execute the request.
/// Recovery and terminal outcomes match upstream's dispatch_into.
pub fn dispatch_owned(child: &mut Child, frame: Vec<u8>, sink: &mut impl EventSink) -> HandleOutcome {
    let request = decode_request(&frame);
    drop(frame);
    match request {
        Ok(Some(request)) => match child.handle(request, sink) {
            Ok(outcome) => outcome,
            Err(FrameError::FrameTooLarge { len, max }) => {
                let _ = sink
                    .send(&child.fatal_event(&format!("response frame of {len} bytes exceeds maximum of {max} bytes")));
                HandleOutcome::Shutdown
            }
            Err(_) => HandleOutcome::Shutdown,
        },
        Ok(None) => HandleOutcome::Continue,
        Err(FrameError::Decode(err)) => {
            let _ = sink.send(&protocol_violation(&format!("malformed request: {err}")));
            HandleOutcome::Continue
        }
        Err(err) => {
            let _ = sink.send(&child.fatal_event(&format!("malformed request frame: {err}")));
            HandleOutcome::Shutdown
        }
    }
}

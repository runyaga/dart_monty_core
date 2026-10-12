//! Smoke test of the built executable: Configure, Feed `1 + 1`, Shutdown, over
//! the framed stdio protocol, as a parent process drives it.

use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};

use monty_proto::{FrameReader, PROTOCOL_VERSION, pb, write_frame};
use monty_types::MontyObject;

struct Worker {
    child: Child,
    stdin: ChildStdin,
    stdout: FrameReader<ChildStdout>,
}

impl Worker {
    fn spawn() -> Self {
        let mut child = Command::new(env!("CARGO_BIN_EXE_dart_monty_worker"))
            .env_clear()
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .expect("spawn dart_monty_worker");
        let stdin = child.stdin.take().expect("stdin");
        let stdout = FrameReader::new(child.stdout.take().expect("stdout"));
        Self { child, stdin, stdout }
    }

    fn send(&mut self, kind: pb::parent_request::Kind) {
        let request = pb::ParentRequest {
            kind: Some(kind),
            trace_parent: None,
        };
        write_frame(&mut self.stdin, &request).expect("write request");
    }

    /// Reads one turn: the streamed `Print`s, then the turn-ending event.
    fn recv_turn(&mut self) -> (Vec<pb::Print>, pb::child_event::Kind) {
        let mut prints = Vec::new();
        loop {
            let event = self
                .stdout
                .read::<pb::ChildEvent>()
                .expect("read event")
                .expect("worker closed stdout mid-turn");
            match event.kind.expect("event has no kind") {
                pb::child_event::Kind::Print(print) => prints.push(print),
                other => return (prints, other),
            }
        }
    }
}

impl Drop for Worker {
    fn drop(&mut self) {
        // Never leak a worker when an assertion fails mid-protocol.
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[test]
fn configure_feed_shutdown() {
    let mut worker = Worker::spawn();

    worker.send(pb::parent_request::Kind::Configure(pb::Configure {
        script_name: "main.py".to_owned(),
        protocol_version: PROTOCOL_VERSION,
        ..Default::default()
    }));
    match worker.recv_turn() {
        (prints, pb::child_event::Kind::Ok(_)) => assert_eq!(prints, []),
        other => panic!("Configure: expected Ok, got {other:?}"),
    }

    worker.send(pb::parent_request::Kind::Feed(pb::Feed {
        code: "1 + 1".to_owned(),
        cwd: "/".to_owned(),
        ..Default::default()
    }));
    match worker.recv_turn() {
        (prints, pb::child_event::Kind::Complete(complete)) => {
            assert_eq!(prints, []);
            let value = MontyObject::try_from(complete).expect("decode Complete");
            assert_eq!(value, MontyObject::int(2));
        }
        other => panic!("Feed: expected Complete, got {other:?}"),
    }

    worker.send(pb::parent_request::Kind::Shutdown(pb::Shutdown {}));
    match worker.recv_turn() {
        (_, pb::child_event::Kind::Ok(_)) => {}
        other => panic!("Shutdown: expected Ok, got {other:?}"),
    }
    let status = worker.child.wait().expect("wait for worker");
    assert_eq!(status.code(), Some(0), "worker exit status {status:?}");
}

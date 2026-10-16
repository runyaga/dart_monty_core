### Fixed

- Reject a queued worker completion when the process exits before its request
  finishes flushing, including when process cleanup masks the pipe's write error.

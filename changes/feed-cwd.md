### Internal

- Worker sessions send `Feed` as upstream's pool does: the first feed of a session (and the first after a reset, or after a feed the type check refused) switches the sandbox to `/`, later feeds keep the working directory (`os.chdir` included), the input arena is always sent, and an input at index zero no longer carries an explicit zero. A request's encoded size, and so an oversized request's message, now matches upstream's.

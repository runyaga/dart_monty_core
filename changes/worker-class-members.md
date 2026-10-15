### Internal

- Worker classes (unexported until the cutover) match pydantic-monty 1.1.0's
  members: `ExternalReturnValue` compares by value; `Frame.toString()` is
  upstream's `str(frame)`; `FunctionSnapshot.kwargs` is one mutable map,
  cached on first read; `SourceRange` rejects an offset outside 0..2^32-1
  with `ArgumentError`; a registered host object is a dict key or set member
  by its own `==` and `hashCode`, not by identity. Outcomes are recorded from
  pydantic-monty 1.1.0 by `tool/generate_worker_class_oracle.py`.

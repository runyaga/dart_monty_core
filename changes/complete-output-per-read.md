### Changed

- `MontyComplete.output` builds its value on every read, as upstream does, including the first. The structure of the value is still checked when the turn ends, so a malformed frame ends the session with `MontyCrashedError`. A value that fails to convert, such as a `timedelta` over 999999999 days, now throws from the `output` getter or `toString()` and leaves the session usable.

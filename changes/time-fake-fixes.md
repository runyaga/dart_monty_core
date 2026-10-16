### Fixed

- `MontyTime` equality and `hashCode` for aware times subtract each offset in whole seconds, as upstream does, instead of flooring it to whole minutes: `time(1, 0, 30, tzinfo=+00:00:30) == time(1, 0, 0, tzinfo=UTC)` is now true.
- `FakeMontySession` raises `TypeError` when an OS call scripted with `eager: true` that is not `asyncio.sleep` or `system.async_sleep` is answered with a plain value, as the worker session does; only the sleeps accept it.

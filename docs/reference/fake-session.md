# The fake session

`package:dart_monty_core/dart_monty_core_testing.dart` exports
`FakeMontySession`: a `MontySession` that plays a script where a worker
would run Python. It needs no worker, no sandbox and no Python: a test
queues what the sandbox does, and the session answers each suspension the
way a worker-backed session does, through the same driver.

```dart
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/dart_monty_core_testing.dart';

final session = FakeMontySession()..willReturn(const MontyInt(42));
expect(await session.feedRun('1 + 1'), const MontyInt(42));
expect(session.feeds, ['1 + 1']);
```

## The script

Each feed plays one segment of the script: the events up to and including
the next `willReturn`, `willRaise` or `willCrash`. Call ids count from 0
within a segment, as a worker numbers them within a feed.

| | |
|---|---|
| `willCall(name, {args, kwargs, eager})` | the sandbox calls a host function |
| `willCallOs(name, {args, kwargs, eager})` | the sandbox makes an OS call |
| `willLookUp(name)` | the sandbox reads a name it does not define |
| `willAwait(callIds, {gathered})` | the sandbox awaits host futures |
| `willPrint(text, {stream})` | the sandbox prints to `stdout` or `stderr` |
| `willReturn(value)` | the feed ends with a value |
| `willRaise(excType, {message, attributes, line, column})` | the feed ends with an exception |
| `willCatch()` | Python catches the exception the last answer raised |
| `willHold(gate)` | the turn stays in flight until `gate` completes |
| `willCrash({timedOut})` | the worker dies |
| `feeds` | the code of each feed, in order |
| `answers` | the host's answers, in order |

A host function call is answered from the `externalLookup` given to
`feedRun` or `feedStart`, an OS call from its `os:` handler, and a name
lookup from `externalLookup` too. Under `feedStart` each suspension comes
back as a snapshot to answer by hand.

An answer that raises in the sandbox (a host function's exception, a name
not in `externalLookup`, a declined OS call, a refused value, a failed
future Python awaits) ends the feed with that error, as uncaught Python
would, unless the next scripted event is `willCatch()`. The rest of that
feed's events are dropped.

## The OS calls

`willCallOs` scripts one of the calls the fake knows. The arguments are
the ones the session receives, and the value is the one the call yields.

| call | arguments to script | the value it yields |
|---|---|---|
| `Path.exists` | a path | `bool` |
| `Path.is_file` | a path | `bool` |
| `Path.is_dir` | a path | `bool` |
| `Path.is_symlink` | a path | `bool` |
| `Path.read_text` | a path | `str` |
| `Path.read_bytes` | a path | `bytes` |
| `Path.stat` | a path | a `StatResult` named tuple |
| `Path.iterdir` | a path | a list of paths |
| `Path.resolve` | a path | an absolute path (`str`) |
| `Path.absolute` | a path | an absolute path (`str`) |
| `Path.unlink` | a path | `None` |
| `Path.rmdir` | a path | `None` |
| `Path.write_text` | a path, a `str` | the number of characters written |
| `Path.append_text` | a path, a `str` | the number of characters written |
| `Path.write_bytes` | a path, `bytes` | the number of bytes written |
| `Path.append_bytes` | a path, `bytes` | the number of bytes written |
| `open` | a path, a mode (`str`) | a file handle |
| `Path.mkdir` | a path; `parents` and `exist_ok` (bools) | `None` |
| `Path.rename` | a source path, a target path | `None` |
| `os.getenv` | a key (`str`), an optional default (any value) | the value, or the default |
| `os.environ` | — | a mapping of the environment |
| `date.today` | — | a `date` |
| `datetime.now` | a time zone, or `None` | a `datetime` |
| `os.urandom` | a size (`int`, not negative) | `bytes` |
| `time.time` | the caller's name (`str`) | a `float` (seconds since the epoch) |
| `time.sleep` | seconds (an `int` or a `float`) | `None` |
| `system.sleep` | seconds (an `int` or a `float`) | `None` |
| `asyncio.sleep` | a delay (an `int` or a `float`) | `None` |
| `system.async_sleep` | a delay (an `int` or a `float`) | `None` |

The special cases:

- a path is a `MontyPath` or a `MontyString`, and the `os:` handler sees
  it normalized, as a session does;
- `Path.mkdir` reads `parents` and `exist_ok` as booleans; it reads no
  other keyword argument, and the other calls read none;
- `os.getenv`'s default is any value and is the second positional
  argument; without one the default is `None`;
- `datetime.now` takes a `MontyTimeZone` or a `MontyNone`;
- `os.urandom` takes a size that is not negative;
- the sleeps take their seconds as an `int` or a `float`.

The fake scripts the call; the answer comes from the `os:` handler, which
receives the same arguments (`OSAccess` answers most of these). Without a
handler the call is declined, and the worker raises its default:
`PermissionError` for a filesystem call, `RuntimeError` for the rest.

## Awaiting, coroutines and eager calls

A host function is answered with a value or with a future, and Python tells
the two apart:

- a plain function is answered with its value, which is not awaitable:
  `await` on it raises `TypeError: '<type>' object can't be awaited`, and a
  gather raises `TypeError: An asyncio.Future, a coroutine or an awaitable
  is required`;
- a coroutine (a function marked with `coroutine(...)`) is answered with a
  pending future, which Python awaits: the feed waits for it, and the
  session settles it when the Dart future completes.

`willAwait` scripts that wait: it names the call ids Python awaits, and
the session answers them in one batch. A call scripted with `eager: true`
is awaited by Python at once, with nothing else to run; the fake waits for
that future itself then, so no `willAwait` is needed for it.

An OS call to `asyncio.sleep` or `system.async_sleep` is the one
exception: upstream wraps its value in a settled future, so awaiting it is
in place.

```dart
final session = FakeMontySession()
  ..willCall('fetch', args: [const MontyString('k')])
  ..willReturn(const MontyNone());

await session.feedRun(
  'fetch("k")',
  externalLookup: {
    'fetch': MontyHostFunction('fetch', (args, kwargs) => const MontyInt(7)),
  },
);

final answer = session.answers.single;
expect(answer.callId, 0);
expect(answer.batch, isNull);
expect((answer.answer! as ExternalReturnValue).value, const MontyInt(7));
```

## The answers

`answers` records what the host answered, in the order the host answered
it. Each entry is a record with three fields:

| field | |
|---|---|
| `callId` | the call the answer goes to; null for a name lookup |
| `batch` | the number of the futures batch the answer went out in; null for a call or a lookup; the numbering restarts with each feed |
| `answer` | the answer: an `ExternalReturnValue`, an `ExternalException` or an `ExternalFuture`, and null where the host answered `not_found`, `not_handled` or an undefined name |

A call and a lookup answer once each; a futures batch answers once per
settled future, and those answers share the batch's number.

The record's type is not exported by name, so read the fields
(`answers.first.callId`) or destructure the record; the shape above is the
contract.

## Structured exception payloads

`willRaise` can carry the structured data of the two exception types that
have one. The attributes are strict: an attribute that is missing or of
another type drops the payload, the exception keeps its type and message,
and the error carries a plain `ValueError` as its exception.

A `json.JSONDecodeError` takes:

| attribute | type |
|---|---|
| `msg` | a `str` |
| `doc` | a `str` |
| `pos` | an `int`, not negative |
| `lineno` | an `int`, not negative |
| `colno` | an `int`, not negative |

A `UnicodeDecodeError` or a `UnicodeEncodeError` takes:

| attribute | type |
|---|---|
| `encoding` | a `str` |
| `object` | `bytes` or a `str`: a decode error takes bytes, an encode error a string |
| `start` | an `int`, not negative |
| `end` | an `int`, not negative |
| `reason` | a `str` |

A `doc` over 64 KiB of UTF-8 is left out of the payload and the rest of it
is kept. A string with an unpaired surrogate counts as missing. On the way
back the payload is dropped when a string or the object is over 64 KiB,
when a Unicode range is not a non-empty slice of its object, when a JSON
`lineno` or `colno` is 0, or when a `pos` is past the document. The error
then carries a plain `ValueError`, since the exception has no class to
build without its payload.

## What the fake does not do

- It does not run Python, and it does not type-check a snippet: no
  `MontyTypingError` is raised and `skipTypeCheck` changes nothing. A
  `SyntaxError` is only what `willRaise` scripts, and it arrives as a
  `MontySyntaxError`; every other exception arrives as a
  `MontyRuntimeError`.
- It takes no `ResourceLimits` and keeps no working directory: `cwd` is
  checked as a session checks it, and no Python reads it.
- It cannot send a host object: a `ClassInstance` or a `ClassType` wrapper
  registers in the session's own registry, which the fake has not, so the
  writer refuses it with an `ArgumentError`.
- `installDependencies` answers as the pure-Monty worker does: an empty
  list succeeds, any other is refused.
- `dump`, `loadSession`, `loadSnapshot` and a snapshot's `dump` throw
  `UnsupportedError`; `workerPid` is null.
- It enforces the session driver's budget of 1000 suspensions: a feed that
  exceeds it fails with `RuntimeError: suspension limit 1000 exceeded`.

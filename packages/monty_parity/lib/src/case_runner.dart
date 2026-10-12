// The case runner drives one parity case through dart_monty_core's public
// API (`MontyRepl`) and returns the normalised outcome that
// tool/parity/score.py compares with pydantic-monty's. Web-safe.
//
// Where core cannot express what a case asks for (an OS policy, a per-feed
// cwd, an overlay mount, a limit it has no field for), the runner records the
// gap under `unsupported` instead of guessing, and the scorer counts it.
import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:monty_parity/src/canon.dart';

/// A canonical value core has no way to express.
final class Inexpressible implements Exception {
  /// Creates an [Inexpressible] with [message].
  const Inexpressible(this.message);

  /// What could not be expressed.
  final String message;

  @override
  String toString() => 'Unsupported operation: $message';
}

// ------------------------------------------------------------- values out

/// [MontyValue] -> canonical form.
Object? montyToCanon(MontyValue v) => switch (v) {
  MontyNone() => {'t': 'none'},
  MontyBool(:final value) => {'t': 'bool', 'v': value},
  MontyInt(:final value) => {'t': 'int', 'v': '$value'},
  MontyBigInt(:final value) => {'t': 'int', 'v': '$value'},
  MontyFloat(:final value) => canonFloat(value),
  MontyString(:final value) => {'t': 'str', 'v': value},
  MontyBytes(:final value) => {'t': 'bytes', 'hex': hexOf(value)},
  MontyList(:final items) => {
    't': 'list',
    'items': [for (final i in items) montyToCanon(i)],
  },
  MontyTuple(:final items) => {
    't': 'tuple',
    'items': [for (final i in items) montyToCanon(i)],
  },
  MontySet(:final items) => {
    't': 'set',
    'items': sortedItems([for (final i in items) montyToCanon(i)]),
  },
  MontyFrozenSet(:final items) => {
    't': 'frozenset',
    'items': sortedItems([for (final i in items) montyToCanon(i)]),
  },
  MontyDict(:final pairs) => {
    't': 'dict',
    'items': [
      for (final (k, x) in pairs) [montyToCanon(k), montyToCanon(x)],
    ],
  },
  MontyPath(:final value) => {'t': 'path', 'v': value},
  MontyEllipsis() => {'t': 'ellipsis'},
  MontyNotImplemented() => {'t': 'notimpl'},
  MontyNamedTuple(:final typeName, :final fieldNames, :final values) => {
    't': 'namedtuple',
    'type': typeName,
    'fields': fieldNames,
    'items': [for (final i in values) montyToCanon(i)],
  },
  MontyFileHandle(:final path, :final mode, :final position) => {
    't': 'filehandle',
    'path': path,
    'mode': mode,
    'position': '$position',
  },
  MontyDate(:final year, :final month, :final day) => {
    't': 'date',
    'v': '${_p(year, 4)}-${_p(month)}-${_p(day)}',
  },
  final MontyDateTime d => {
    't': 'datetime',
    'v':
        '${_p(d.year, 4)}-${_p(d.month)}-${_p(d.day)}'
        'T${_hms(d.hour, d.minute, d.second, d.microsecond)}',
    'offset': d.offsetSeconds,
    'tzname': d.timezoneName,
  },
  final MontyTime d => {
    't': 'time',
    'v': _hms(d.hour, d.minute, d.second, d.microsecond),
    'offset': d.offsetSeconds,
    'tzname': d.timezoneName,
    'fold': d.fold,
  },
  MontyTimeDelta(:final days, :final seconds, :final microseconds) => {
    't': 'timedelta',
    'days': days,
    'seconds': seconds,
    'us': microseconds,
  },
  MontyTimeZone(:final offsetSeconds, :final name) => {
    't': 'timezone',
    'offset': offsetSeconds,
    'name': name,
  },
  MontyExceptionValue(:final excType, :final message) => {
    't': 'exception',
    'type': excType,
    'arg': message,
  },
  final MontyClassInstance ci =>
    _hostLabels[ci.instanceId] != null
        ? {'t': 'hostobj', 'obj': _hostLabels[ci.instanceId]}
        : {
            't': 'proxy',
            'class': ci.classType.name,
            'dataclass': ci.classType.isDataclass,
            'attrs': [
              for (final e in ci.attrs.entries) [e.key, montyToCanon(e.value)],
            ],
            '_host_defined': ci.classType.hostDefined,
          },
  // Core types these renderings; upstream's binding returns builtins as
  // MontyStdTypeProxy and type objects as types, repr/cycle/function as str.
  MontyOpaque(:final kind, :final text) => switch (kind) {
    MontyOpaqueKind.builtin => {'t': 'builtin', 'name': text},
    MontyOpaqueKind.type => {'t': 'type', 'name': text},
    _ => {'t': 'opaque', 'kind': kind.wireTag, 'v': text},
  },
  _ => {
    't': 'other',
    'kind': v.runtimeType.toString(),
    'repr': '${v.toJson()}',
  },
};

String _p(int n, [int w = 2]) => n.toString().padLeft(w, '0');
String _hms(int h, int m, int s, int us) =>
    '${_p(h)}:${_p(m)}:${_p(s)}.${_p(us, 6)}';

/// Host-object labels: instanceId -> the case's label for it.
final _hostLabels = <String, String>{};

/// Callback args arrive as plain Dart values (or MontyValues).
Object? dartToCanon(Object? v) {
  _argTypes.add(v.runtimeType.toString());
  return _dartToCanon(v);
}

/// Runtime types seen in callback args (evidence for the bytes/path
/// projection), reported per case under `notes.os_arg_runtime_types`.
final _argTypes = <String>{};

Object? _dartToCanon(Object? v) => switch (v) {
  null => {'t': 'none'},
  final MontyValue m => montyToCanon(m),
  final bool b => {'t': 'bool', 'v': b},
  final int i => {'t': 'int', 'v': '$i'},
  final double d => canonFloat(d),
  final BigInt b => {'t': 'int', 'v': '$b'},
  final String s => {'t': 'str', 'v': s},
  final Uint8List b => {'t': 'bytes', 'hex': hexOf(b)},
  final List<Object?> l => {
    't': 'list',
    'items': [for (final x in l) dartToCanon(x)],
  },
  final Map<Object?, Object?> m => {
    't': 'dict',
    'items': [
      for (final e in m.entries) [dartToCanon(e.key), dartToCanon(e.value)],
    ],
  },
  _ => {'t': 'other', 'kind': v.runtimeType.toString(), 'repr': '$v'},
};

// -------------------------------------------------------------- values in

/// Canonical -> a Dart value core accepts as an input or an OS-call answer.
/// Throws [Inexpressible] when core has no way to express it.
Object? canonToDart(Map<String, Object?> c) {
  List<Object?> items() => [
    for (final x in c['items']! as List) canonToDart((x! as Map).cast()),
  ];
  return switch (c['t']) {
    'none' => const MontyNone(),
    'bool' => c['v'],
    'int' => () {
      final b = BigInt.parse(c['v']! as String);
      if (!b.isValidInt) {
        throw Inexpressible('int ${c['v']} does not fit a Dart int');
      }
      return b.toInt();
    }(),
    'float' => decodeFloat(c),
    'str' => c['v'],
    'list' => items(),
    'dict' => {
      for (final kv in c['items']! as List)
        canonToDart(((kv as List)[0] as Map).cast()): canonToDart(
          (kv[1] as Map).cast(),
        ),
    },
    'bytes' => MontyBytes(Uint8List.fromList(bytesOfHex(c['hex']! as String))),
    'path' => MontyPath(c['v']! as String),
    'filehandle' => MontyFileHandle(
      path: c['path']! as String,
      mode: c['mode']! as String,
      position: int.parse((c['position'] ?? '0') as String),
    ),
    'date' => () {
      final d = DateTime.parse(c['v']! as String);
      return MontyDate(year: d.year, month: d.month, day: d.day);
    }(),
    'datetime' => () {
      final d = isoParts(c['v']! as String);
      return MontyDateTime(
        year: d.y,
        month: d.m,
        day: d.d,
        hour: d.h,
        minute: d.mi,
        second: d.s,
        microsecond: d.us,
        offsetSeconds: d.off,
      );
    }(),
    // A host value nothing can convert; a large string.
    'opaque' => Object(),
    'str_repeat' => (c['v']! as String) * (c['n']! as int),
    final t => throw Inexpressible(
      'core inputs/returns cannot express canonical "$t"',
    ),
  };
}

/// Canonical -> [MontyValue] for callback returns (core's typed host->Python
/// path). Shared `id`s map to the same Dart object; core still serialises a
/// tree.
MontyValue canonToMonty(
  Map<String, Object?> c,
  CoreHost host, [
  Map<int, MontyValue>? memo,
]) {
  memo ??= {};
  final t = c['t'];
  if (t == 'ref') return memo[c['id']]!;
  List<MontyValue> items() => [
    for (final x in c['items']! as List)
      canonToMonty((x! as Map).cast(), host, memo),
  ];
  (int, int, int, int) hms(String v) {
    final p = v.split(RegExp('[:.]'));
    return (
      int.parse(p[0]),
      int.parse(p[1]),
      int.parse(p[2]),
      p.length > 3 ? int.parse(p[3].padRight(6, '0')) : 0,
    );
  }

  final v = switch (t) {
    'none' => const MontyNone(),
    'ellipsis' => const MontyEllipsis(),
    'notimpl' => const MontyNotImplemented(),
    'bool' => MontyBool(c['v']! as bool),
    'int' => () {
      final b = BigInt.parse(c['v']! as String);
      return b.isValidInt ? MontyInt(b.toInt()) : MontyBigInt(b);
    }(),
    'float' => MontyFloat(decodeFloat(c)),
    'str' => MontyString(c['v']! as String),
    'bytes' => MontyBytes(Uint8List.fromList(bytesOfHex(c['hex']! as String))),
    'list' => MontyList(items()),
    'tuple' => MontyTuple(items()),
    'set' => MontySet(items()),
    'frozenset' => MontyFrozenSet(items()),
    'dict' => MontyDict([
      for (final kv in c['items']! as List)
        (
          canonToMonty(((kv as List)[0] as Map).cast(), host, memo),
          canonToMonty((kv[1] as Map).cast(), host, memo),
        ),
    ]),
    'namedtuple' => MontyNamedTuple(
      typeName: c['type']! as String,
      fieldNames: (c['fields']! as List).cast<String>(),
      values: items(),
    ),
    'path' => MontyPath(c['v']! as String),
    'date' => () {
      final p = (c['v']! as String).split('-').map(int.parse).toList();
      return MontyDate(year: p[0], month: p[1], day: p[2]);
    }(),
    'datetime' => () {
      final s = (c['v']! as String).split('T');
      final d = s[0].split('-').map(int.parse).toList();
      final (h, m, sec, us) = hms(s[1]);
      return MontyDateTime(
        year: d[0],
        month: d[1],
        day: d[2],
        hour: h,
        minute: m,
        second: sec,
        microsecond: us,
        offsetSeconds: c['offset'] as int?,
        timezoneName: c['tzname'] as String?,
      );
    }(),
    'time' => () {
      final (h, m, sec, us) = hms(c['v']! as String);
      return MontyTime(
        hour: h,
        minute: m,
        second: sec,
        microsecond: us,
        offsetSeconds: c['offset'] as int?,
        timezoneName: c['tzname'] as String?,
        fold: (c['fold'] as int?) ?? 0,
      );
    }(),
    'timedelta' => MontyTimeDelta(
      days: c['days']! as int,
      seconds: c['seconds']! as int,
      microseconds: c['us']! as int,
    ),
    'timezone' => MontyTimeZone(
      offsetSeconds: c['offset']! as int,
      name: c['name'] as String?,
    ),
    'exception' => MontyExceptionValue(
      excType: c['type']! as String,
      message: c['arg'] as String?,
    ),
    'type' => MontyOpaque(MontyOpaqueKind.type, c['name']! as String),
    'builtin' => MontyOpaque(MontyOpaqueKind.builtin, c['name']! as String),
    'echo' => host.rawOutputs[c['step']! as int]!,
    'wrap' => host.wrapperValue(c['w']! as String),
    'proxy' => throw const Inexpressible(
      'core: no way to rebuild a proxy from canonical',
    ),
    final other => throw Inexpressible(
      'core cannot express canonical "$other"',
    ),
  };
  if (c['id'] case final int id) memo[id] = v;
  return v;
}

// ---------------------------------------------------------- host objects

/// User-level host-object emulation through core's public API: a host
/// instance is a [MontyClassInstance] the host builds (eager attributes
/// only); method calls arrive as plain external calls by method name, so the
/// receiver is unknown. No policies, lazy attributes, class values or
/// conversion hooks.
class CoreHost {
  /// Builds the host world a case's `host` block describes.
  CoreHost(Map<String, Object?> c) {
    final host = ((c['host'] as Map?) ?? const {}).cast<String, Object?>();
    classes = ((host['classes'] as Map?) ?? const {}).cast<String, Object?>();
    objects = ((host['objects'] as Map?) ?? const {}).cast<String, Object?>();
    wspecs = ((host['wrappers'] as Map?) ?? const {}).cast<String, Object?>();
  }

  /// Class specs by name.
  late final Map<String, Object?> classes;

  /// Object specs by label.
  late final Map<String, Object?> objects;

  /// Wrapper specs by name.
  late final Map<String, Object?> wspecs;

  /// Each step's raw value (for `echo` answers).
  final rawOutputs = <MontyValue?>[];

  final _granted = <String>[];

  /// The current step's host-call transcript.
  List<Object?> log = [];

  static int _n = 0;

  String _uuid(String seed) {
    final h = seed.hashCode.toUnsigned(32).toRadixString(16).padLeft(8, '0');
    final n = (++_n).toRadixString(16).padLeft(12, '0');
    return '$h-0000-4000-8000-$n';
  }

  /// The value a `wrap` canonical stands for.
  MontyValue wrapperValue(String name) {
    final ws = (wspecs[name]! as Map).cast<String, Object?>();
    if (ws['kind'] != 'instance') {
      throw const Inexpressible(
        'core: no host class value (MontyClassType is not a MontyValue)',
      );
    }
    final label = ws['obj']! as String;
    final o = (objects[label]! as Map).cast<String, Object?>();
    final cname = o['class']! as String;
    final cls = (classes[cname]! as Map).cast<String, Object?>();
    final values = (o['values']! as Map).cast<String, Object?>();
    final eager = ws['eager'];
    final names = eager == null
        ? <String>[]
        : eager == 'all'
        ? [
            for (final k in values.keys)
              if (!k.startsWith('_')) k,
          ]
        : (eager as List).cast<String>();
    final iid = _uuid(label);
    _hostLabels[iid] = label;
    _granted.add(label);
    final classId = cname.hashCode
        .toUnsigned(32)
        .toRadixString(16)
        .padLeft(12, '0');
    return MontyClassInstance(
      classType: MontyClassType(
        name: cname,
        id: '00000000-0000-4000-8000-$classId',
        hostDefined: true,
        isDataclass: cls['dataclass'] == true,
        attrs: const {},
      ),
      instanceId: iid,
      attrs: {
        for (final n in names)
          n: canonToMonty((values[n]! as Map).cast(), this),
      },
    );
  }

  /// Method names the sandbox may reach: every method of every class.
  Iterable<String> get methodNames sync* {
    for (final c in classes.values) {
      yield* (((c! as Map)['methods'] as Map?) ?? const {}).keys.cast<String>();
    }
  }

  /// A method call by name: the receiver is unknown, so dispatch to the
  /// single granted object whose class defines it (else fail).
  Object? callByName(String name, List<Object?> args) {
    log.add({
      'op': 'call',
      'obj': {'t': 'unknown-receiver'},
      'name': name,
    });
    Map<Object?, Object?> methodsOf(String label) =>
        ((classes[(objects[label]! as Map)['class']]! as Map)['methods']
            as Map?) ??
        const {};
    final cands = [
      for (final l in _granted.toSet())
        if (methodsOf(l).containsKey(name)) l,
    ];
    if (cands.length != 1) {
      throw OsCallException(
        'core host cannot tell which receiver: ${cands.length} candidates',
        pythonExceptionType: 'RuntimeError',
      );
    }
    final o = (objects[cands.single]! as Map).cast<String, Object?>();
    final beh = (methodsOf(cands.single)[name]! as Map).cast<String, Object?>();
    log.add({
      'op': 'method',
      'obj': {'t': 'hostobj', 'obj': cands.single},
      'name': name,
      'args': [for (final a in args) dartToCanon(a)],
      'kwargs': <String, Object?>{},
    });
    if (beh['returns'] case final Map<Object?, Object?> r) {
      return canonToMonty(r.cast(), this);
    }
    if (beh['format'] case final String f) {
      var s = f;
      for (var i = 0; i < args.length; i++) {
        s = s.replaceAll('{$i}', '${args[i]}');
      }
      final values = (o['values']! as Map).cast<String, Object?>();
      for (final e in values.entries) {
        s = s.replaceAll('{${e.key}}', '${(e.value! as Map)['v']}');
      }
      return MontyString(s);
    }
    if (beh['raise'] case final Map<Object?, Object?> r) {
      throw OsCallException(
        (r['message'] as String?) ?? '',
        pythonExceptionType: r['type'] as String?,
      );
    }
    throw OsCallException(
      'core host: behaviour $beh not emulated',
      pythonExceptionType: 'RuntimeError',
    );
  }
}

// ------------------------------------------------------------ filesystem

/// Builds core's memory-mounted handler from a case `fs` spec (mounts and
/// seeded files). Throws whatever core throws at construction.
OsCallHandler buildFsHandler(
  Map<String, Object?> fs,
  OsCallHandler fallthrough,
  Map<String, Object?> unsupported,
) {
  final mounts = <MountDir>[];
  for (final m in (fs['mounts']! as List).cast<Map<String, Object?>>()) {
    final mode = m['mode'] as String? ?? 'read-write';
    if (mode == 'overlay') {
      unsupported['fs.mode'] =
          'core MountMode has no overlay; ran as readWrite';
    }
    mounts.add(
      MountDir(
        virtualPath: m['virtual']! as String,
        mode: mode == 'read-only' ? MountMode.readOnly : MountMode.readWrite,
        writeBytesLimit: m['write_bytes_limit'] as int?,
        memoryUsageLimit:
            (m['memory_usage_limit'] as int?) ?? defaultMemoryUsageLimit,
      ),
    );
  }
  final files = <VfsFile>[];
  for (final e in ((fs['files'] as Map?) ?? const {}).entries) {
    final k = e.key as String;
    if (k.endsWith('/')) {
      unsupported['fs.empty_dir_seed'] =
          'core seeds directories only through files';
      continue;
    }
    final v = (e.value as Map).cast<String, Object?>();
    files.add(
      v.containsKey('hex')
          ? MontyMemoryFile(
              k,
              Uint8List.fromList(bytesOfHex(v['hex']! as String)),
            )
          : MontyMemoryFile(k, v['text']! as String),
    );
  }
  return memoryMountedOsHandler(
    mounts: mounts,
    files: files,
    fallthrough: fallthrough,
  );
}

// ---------------------------------------------------------------- errors

/// [MontyException] -> canonical exception (type, message, frames).
Map<String, Object?> exceptionC(MontyException e) => {
  'type': e.excType,
  'message': e.message,
  'traceback': [
    for (final f in e.traceback)
      {
        'filename': f.filename,
        'line': f.startLine,
        'column': f.startColumn,
        'end_line': f.endLine,
        'end_column': f.endColumn,
        'function': f.frameName,
        'source_line': f.previewLine,
      },
  ],
};

final _excPrefix = RegExp('^([A-Za-z_.]*(Error|Exception|Interrupt|Exit)): ?');

/// A [MontyResourceError] carries no typed field; the Python type is parsed
/// from the message text.
Map<String, Object?> resourceExc(MontyResourceError e) {
  final m = _excPrefix.firstMatch(e.message);
  return {
    'type': m != null ? m.group(1) : 'MontyResourceError',
    'message': m != null ? e.message.substring(m.end) : e.message,
    'traceback': <Object?>[],
  };
}

// ---------------------------------------------------------------- limits

/// Case limits -> [MontyLimits]. Core has memory, recursion, one duration
/// (cumulative per session, mapped from max_duration_secs or
/// max_feed_duration_secs) and, from the suspension budget on, a host-side
/// suspension count. A limit the measured core has no field for is recorded
/// as unsupported.
///
/// The constructor is called through [Function.apply] so the same runner
/// measures a core that predates a field: an unknown named argument is a
/// [NoSuchMethodError] there, and the limit is recorded as unsupported.
MontyLimits? coreLimits(
  Map<String, Object?> c,
  Map<String, Object?> unsupported,
) {
  final limitsIn = (c['limits'] as Map?)?.cast<String, Object?>() ?? const {};
  if (limitsIn.isEmpty) return null;
  num? dur;
  final named = <Symbol, Object?>{};
  for (final MapEntry(:key, :value) in limitsIn.entries) {
    switch (key) {
      case 'max_memory':
        named[#memoryBytes] = value;
      case 'max_recursion_depth':
        named[#stackDepth] = value;
      case 'max_duration_secs' || 'max_feed_duration_secs':
        dur = value as num?;
      case 'max_suspensions':
        named[#maxSuspensions] = value;
      default:
        unsupported['limits.$key'] = 'MontyLimits has no $key';
    }
  }
  if (dur != null) named[#timeoutMs] = (dur * 1000).round();
  try {
    return Function.apply(MontyLimits.new, const [], named) as MontyLimits;
    // A core that predates the field: that absence is what gets recorded.
    // ignore: avoid_catching_errors
  } on NoSuchMethodError {
    named.remove(#maxSuspensions);
    unsupported['limits.max_suspensions'] = 'MontyLimits has no maxSuspensions';
    return Function.apply(MontyLimits.new, const [], named) as MontyLimits;
  }
}

// ---------------------------------------------------------------- runner

/// Runs case [c] on [backend] (`vm`, `dart2js` or `dart2wasm`).
Future<Map<String, Object?>> runCase(
  Map<String, Object?> c,
  String backend,
) async {
  final out = newOutcome(c['id']! as String, 'core', backend);
  out['engine_version'] = 'dart_monty_core (public API: MontyRepl)';
  final unsupported = out['unsupported']! as Map<String, Object?>;
  final notes = out['notes']! as Map<String, Object?>;
  unsupported['identity'] =
      'MontyValue is a tree decoded from JSON: shared sub-objects arrive as '
      'copies';
  if (c['os_policy'] != null) {
    unsupported['os_policy'] =
        'no OsPolicy on the public API; ran with the default';
  }
  if (c['cwd'] != null) {
    unsupported['cwd'] = 'no per-feed cwd on the public API; ran without it';
  }
  if (c['close_mount_before_feed'] != null) {
    unsupported['mount_close'] =
        'core MountDir has no close(); feed ran with the mount still live';
  }
  if (c.containsKey('assert_message_annotations')) {
    unsupported['assert_message_annotations'] = 'no public knob';
  }
  final limits = coreLimits(c, unsupported);
  Map<String, Object?>? inputs;
  final inputsIn = (c['inputs'] as Map?)?.cast<String, Object?>();
  if (inputsIn != null && inputsIn.isNotEmpty) {
    notes['inputs'] =
        'untyped: feedRun(inputs:) renders each value as a Python literal '
        'assignment prepended to the code';
    try {
      inputs = {
        for (final e in inputsIn.entries)
          e.key: canonToDart((e.value! as Map).cast()),
      };
    } on Inexpressible catch (e) {
      unsupported['inputs'] = '${e.message}; case ran without inputs';
    }
  }

  var steps = await _attempt(c, limits, inputs, unsupported);
  if (steps == null) {
    if (c['on_refused_limits'] == 'record') {
      // Recorded as refused, not re-run: an unbounded re-run of a limit
      // case may never terminate.
      out['refused'] = unsupported['limits'];
      steps = <Object?>[];
    } else {
      steps = await _attempt(c, null, inputs, unsupported);
    }
  }
  out['steps'] = steps;
  notes['os_arg_runtime_types'] = _argTypes.toList()..sort();
  _argTypes.clear();
  return out;
}

/// Core's one-shot path, `createPlatformMonty().run(code, limits:)`: only
/// for a single-code case with limits core can express and no callbacks.
/// Returns null when the case does not qualify.
Future<Map<String, Object?>?> runOneShot(
  Map<String, Object?> c,
  String backend,
) async {
  if (c['one_shot'] != true) return null;
  if (c['code'] == null || c['feeds'] != null) return null;
  if ((c['externals'] as Map?)?.isNotEmpty ?? false) return null;
  if ((c['os'] as Map?)?.isNotEmpty ?? false) return null;
  if ((c['inputs'] as Map?)?.isNotEmpty ?? false) return null;
  if (c['limits'] == null) return null;
  final out = newOutcome(c['id']! as String, 'core1', backend);
  out['engine_version'] = 'dart_monty_core (createPlatformMonty().run)';
  final unsupported = out['unsupported']! as Map<String, Object?>;
  unsupported['identity'] = 'JSON tree';
  if (c['os_policy'] != null) {
    unsupported['os_policy'] = 'no OsPolicy on the public API';
  }
  if (c.containsKey('assert_message_annotations')) {
    unsupported['assert_message_annotations'] = 'no public knob';
  }
  final limits = coreLimits(c, unsupported);
  if (limits == null ||
      (limits.memoryBytes == null &&
          limits.stackDepth == null &&
          limits.timeoutMs == null)) {
    return null; // nothing core can express: an unbounded run proves nothing
  }
  final step = newStep();
  out['steps'] = [step];
  final p = createPlatformMonty();
  try {
    final r = await p.run(c['code']! as String, limits: limits);
    if (r.error != null) {
      step['exception'] = exceptionC(r.error!);
    } else {
      step['value'] = montyToCanon(r.value);
    }
    final printed = r.printOutput;
    step['prints'] = printed == null || printed.isEmpty
        ? <Object?>[]
        : [
            {'stream': 'stdout', 'text': printed},
          ];
  } on MontyScriptError catch (e) {
    step['exception'] = e.exception != null
        ? exceptionC(e.exception!)
        : {'type': e.excType, 'message': e.message, 'traceback': <Object?>[]};
    step['thrown'] = 'MontyScriptError';
  } on MontyResourceError catch (e) {
    step['exception'] = resourceExc(e);
    step['thrown'] = 'MontyResourceError: ${e.message}';
  } on Object catch (e) {
    step['thrown'] = '${e.runtimeType}: $e';
    out['runner_error'] = 'one-shot threw ${e.runtimeType}: $e';
  } finally {
    await _disposeQuietly(p.dispose);
  }
  return out;
}

Future<List<Object?>?> _attempt(
  Map<String, Object?> c,
  MontyLimits? limits,
  Map<String, Object?>? inputs,
  Map<String, Object?> unsupported,
) async {
  final script = Script(c);
  final host = CoreHost(c);
  var repl = MontyRepl(limits: limits);
  final steps = <Object?>[];
  final restoreBefore = ((c['restore_before'] as List?) ?? const [])
      .cast<int>();
  final fs = (c['fs'] as Map?)?.cast<String, Object?>();
  List<Object?>? curOs;
  Map<String, Object?> callRecord(
    String name,
    List<Object?> args,
    Map<String, Object?>? kwargs,
  ) => {
    'name': name,
    'args': [for (final a in args) dartToCanon(a)],
    'kwargs': {
      for (final e in (kwargs ?? const {}).entries) e.key: dartToCanon(e.value),
    },
  };
  Future<Object?> fallthrough(
    String op,
    List<Object?> args,
    Map<String, Object?>? kwargs,
  ) async {
    curOs!.add(callRecord(op, args, kwargs));
    return _respond(script.next(op, isOs: true), op, isOs: true);
  }

  OsCallHandler? fsHandler;
  Object? fsError;
  if (fs != null) {
    try {
      fsHandler = buildFsHandler(fs, fallthrough, unsupported);
    } on Object catch (e) {
      fsError = e;
    }
  }
  try {
    final feeds =
        (c['feeds'] as List?)?.cast<String>() ?? [c['code']! as String];
    for (var n = 0; n < feeds.length; n++) {
      if (restoreBefore.contains(n)) {
        final bytes = await repl.snapshot();
        await _disposeQuietly(repl.dispose);
        repl = MontyRepl(limits: limits);
        await repl.restore(bytes);
        unsupported['restore'] =
            'MontyRepl.snapshot() -> new MontyRepl -> restore(bytes)';
      }
      final step = newStep();
      steps.add(step);
      host.log = step['host_calls']! as List<Object?>;
      final prints = <(String, String)>[];
      final ext = step['ext_calls']! as List;
      final os = step['os_calls']! as List;
      curOs = os;
      final externals = <String, MontyCallback>{
        for (final name in host.methodNames)
          name: (args, kwargs) => host.callByName(name, args),
        for (final name in script.externals.keys)
          name: (args, kwargs) {
            ext.add(callRecord(name, args, kwargs));
            final a = script.next(name, isOs: false);
            if (a != null && a.containsKey('echo')) {
              return host.rawOutputs[a['echo']! as int];
            }
            if (a != null && a.containsKey('echo_arg')) {
              return args[a['echo_arg']! as int];
            }
            if (a != null && a.containsKey('return')) {
              final ret = (a['return']! as Map).cast<String, Object?>();
              // A host value core cannot convert goes back as the raw Dart
              // object, so core's own conversion error is the outcome.
              if (ret['t'] == 'opaque' || ret['t'] == 'str_repeat') {
                return canonToDart(ret);
              }
              return canonToMonty(ret, host);
            }
            return _respond(a, name, isOs: false);
          },
      };
      Object? osHandler(
        String op,
        List<Object?> args,
        Map<String, Object?>? kwargs,
      ) {
        os.add(callRecord(op, args, kwargs));
        return _respond(script.next(op, isOs: true), op, isOs: true);
      }

      if (fsError != null) {
        step['exception'] = {
          'type': fsError.runtimeType.toString(),
          'message': '$fsError',
          'traceback': <Object?>[],
        };
        step['thrown'] = 'host';
        host.rawOutputs.add(null);
        continue;
      }
      MontyResult r;
      try {
        r = await repl.feedRun(
          feeds[n],
          externalFunctions: externals,
          osHandler: fsHandler ?? osHandler,
          inputs: n == 0 ? inputs : null,
          printCallback: (s, t) => prints.add((s, t)),
        );
      } on MontyScriptError catch (e) {
        step['exception'] = e.exception != null
            ? exceptionC(e.exception!)
            : {
                'type': e.excType,
                'message': e.message,
                'traceback': <Object?>[],
              };
        step['prints'] = mergePrints(prints);
        step['thrown'] = 'MontyScriptError';
        host.rawOutputs.add(null);
        continue;
      } on MontyResourceError catch (e) {
        step['exception'] = resourceExc(e);
        step['thrown'] = 'MontyResourceError: ${e.message}';
        host.rawOutputs.add(null);
        continue;
      } on MontyError catch (e) {
        // Any other error core raises to the host for this feed (e.g. a
        // host-enforced budget): not a Python exception, so its Dart type
        // stands in for the exception type.
        step['exception'] = {
          'type': e.runtimeType.toString(),
          'message': e.message,
          'traceback': <Object?>[],
        };
        step['prints'] = mergePrints(prints);
        step['thrown'] = e.runtimeType.toString();
        host.rawOutputs.add(null);
        continue;
      }
      step['prints'] = mergePrints(prints);
      if (r.error != null) {
        step['exception'] = exceptionC(r.error!);
        host.rawOutputs.add(null);
      } else {
        step['value'] = montyToCanon(r.value);
        host.rawOutputs.add(r.value);
      }
      step['usage'] = {
        'memory_bytes_used': r.usage.memoryBytesUsed,
        'time_elapsed_ms': r.usage.timeElapsedMs,
        'stack_depth_used': r.usage.stackDepthUsed,
      };
    }
  } on Object catch (e) {
    if (limits != null && steps.length <= 1) {
      unsupported['limits'] = 'MontyRepl(limits:) refused: $e';
      await _disposeQuietly(repl.dispose);
      return null;
    }
    rethrow;
  }
  await _disposeQuietly(repl.dispose);
  return steps;
}

Future<void> _disposeQuietly(Future<void> Function() dispose) async {
  try {
    await dispose();
  } on Object {
    // A failed dispose is not part of the outcome.
  }
}

Object? _respond(Map<String, Object?>? a, String name, {required bool isOs}) {
  if (a == null) {
    if (isOs) throw OsCallNotHandledException(name);
    throw OsCallException(
      "name '$name' is not defined",
      pythonExceptionType: 'NameError',
    );
  }
  if (a.containsKey('return')) {
    return canonToDart((a['return']! as Map).cast());
  }
  final r = (a['raise']! as Map).cast<String, Object?>();
  throw OsCallException(
    (r['message'] as String?) ?? '',
    pythonExceptionType: r['type'] as String?,
  );
}

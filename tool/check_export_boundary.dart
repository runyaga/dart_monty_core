// Export-boundary check: what the public libraries expose, and what they must
// not.
//
// Run from the package root (not with `dart run`, which builds the native
// crate through hook/build.dart first; this check reads source only):
//   dart --packages=.dart_tool/package_config.json \
//     tool/check_export_boundary.dart [--update | --self-test]
// --update rewrites the golden list; --self-test runs the controls at the end
// of this file.
//
// A public library is any `.dart` file under lib/ outside lib/src/. For each
// one, resolved with the analyzer (element model, no bodies), this checks:
//
// 1. EXPORTS. No library under lib/src/worker/ (the worker stack: generated
//    protobuf, arena reader/writer, frames, channels) and nothing from
//    package:protobuf is reached through `export` directives, followed
//    transitively and regardless of `show`/`hide`, and no exported name is
//    declared in one.
// 2. SIGNATURES. No such declaration appears in a public signature: the
//    supertypes, type-parameter bounds and public members (fields, getters,
//    setters, methods, constructors) of every exported declaration, every
//    type a signature mentions, and, transitively, the public signatures of
//    every declaration of this package those types name, exported or not.
//    Private members are skipped; private classes are not, because their
//    public members are inherited by the public classes that extend them.
// 3. GOLDEN. The exported names equal tool/export-golden.txt, per library.
//    A difference prints the added and removed names; review it as a public
//    API change, then rewrite the file with --update.
//
// IMPORTS ARE ALLOWED. Rule 1 and 2 are "exported or in a public signature",
// not "reachable". A public library may import worker code and use it in
// function bodies and private members; the session built on the worker must
// do exactly that. A literal reachability rule would block it, so the walk
// over imports is reported for information and never fails the check.
//
// Exit codes: 0 pass, 1 a rule failed, 2 the check itself could not run.

import 'dart:collection';
import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/file_system/file_system.dart'
    show Folder, ResourceProvider;
import 'package:analyzer/file_system/overlay_file_system.dart'
    show OverlayResourceProvider;
import 'package:analyzer/file_system/physical_file_system.dart'
    show PhysicalResourceProvider;
// Not public API: see _analyzeUnder.
import 'package:analyzer/src/dart/analysis/analysis_context_collection.dart'
    show AnalysisContextCollectionImpl;

const _package = 'package:dart_monty_core/';
const _goldenPath = 'tool/export-golden.txt';

/// How to run this tool. Not `dart run`: that runs hook/build.dart first,
/// which builds the native crate, and this check reads source only.
const _command =
    'dart --packages=.dart_tool/package_config.json '
    'tool/check_export_boundary.dart';

/// URI prefixes no public library may export or name in a signature.
const _forbidden = ['${_package}src/worker/', 'package:protobuf/'];

bool _isForbidden(Uri uri) {
  final text = uri.toString();

  return _forbidden.any(text.startsWith);
}

final _setterSuffix = RegExp(r'=$');

/// The forbidden file [element] is declared in, if any: its library, or a
/// part file of it, since a part under lib/src/worker/ can declare members of
/// a library that lives elsewhere.
Uri? _forbiddenSource(Element element) {
  final sources = [
    ?element.library?.uri,
    for (final fragment in element.fragments)
      ?fragment.libraryFragment?.source.uri,
  ];

  return sources.where(_isForbidden).firstOrNull;
}

bool _isOwn(Uri uri) => uri.toString().startsWith(_package);

/// What one run of the check found: the report.
final class _CheckExportBoundary {
  /// Exported names per public library, keyed by its path under lib/.
  final Map<String, List<String>> names = {};

  /// Rule 1 and 2 failures.
  final List<String> violations = [];

  /// Forbidden libraries reached through imports only (allowed).
  final Set<String> importOnly = {};

  /// The conditional-directive branches analysed besides the default.
  final List<String> conditions = [];
}

Future<void> main(List<String> args) async {
  final root = File.fromUri(Platform.script).parent.parent.path;
  try {
    exitCode = switch (args) {
      ['--self-test'] => await _selfTest(root),
      ['--update'] => await _run(root, update: true),
      [] => await _run(root, update: false),
      _ => _usage(),
    };
  } on Object catch (error, stack) {
    stderr
      ..writeln('ERROR: the export-boundary check could not run: $error')
      ..writeln(stack);
    exitCode = 2;
  }
}

int _usage() {
  stderr.writeln(
    'usage: $_command [--update|--self-test]',
  );

  return 2;
}

Future<int> _run(String root, {required bool update}) async {
  final report = await _analyzeBoundary(
    root,
    PhysicalResourceProvider.INSTANCE,
  );
  final golden = File('$root/$_goldenPath');
  if (update) {
    golden.writeAsStringSync(_renderGolden(report.names));
    stdout.writeln('wrote $_goldenPath');
  }
  final diff = _diffGolden(
    golden.existsSync() ? golden.readAsStringSync() : '',
    report.names,
  );
  _print(report, diff);
  final failed = report.violations.isNotEmpty || diff.isNotEmpty;
  stdout.writeln(failed ? 'EXPORT BOUNDARY RED' : 'EXPORT BOUNDARY GREEN');

  return failed ? 1 : 0;
}

void _print(_CheckExportBoundary report, List<String> diff) {
  final unique = report.names.values.expand((n) => n).toSet();
  for (final MapEntry(:key, :value) in report.names.entries) {
    stdout.writeln('$key: ${value.length} exported names');
  }
  stdout
    ..writeln('${unique.length} unique exported names')
    ..writeln(
      'also analysed with: '
      '${report.conditions.isEmpty ? 'none' : report.conditions.join(', ')}',
    )
    ..writeln(
      'worker/protobuf libraries reached by import only (allowed): '
      '${report.importOnly.length}',
    );
  for (final violation in report.violations) {
    stdout.writeln('FAIL $violation');
  }
  if (diff.isNotEmpty) {
    stdout.writeln('FAIL exported names differ from $_goldenPath:');
    diff.forEach(stdout.writeln);
    stdout.writeln(
      '  Review the diff as a public API change, then: '
      '$_command --update',
    );
  }
}

/// Resolves every public library under [root] through [provider], once with
/// no declared variables and once per combination of the conditions the
/// conditional `import`s and `export`s under lib/ test, so every branch, and
/// every branch reachable only through another, is selected.
Future<_CheckExportBoundary> _analyzeBoundary(
  String root,
  ResourceProvider provider,
) async {
  final report = _CheckExportBoundary();
  await _analyzeUnder(root, provider, const {}, report);
  final defaults = Map.of(report.names);
  for (final declared in _platforms(_conditions(root, provider))) {
    final variant = _CheckExportBoundary();
    await _analyzeUnder(root, provider, declared, variant);
    final label = declared.entries
        .map((entry) => '${entry.key}==${entry.value}')
        .join(' ');
    report.conditions.add(label);
    report.violations.addAll([
      for (final violation in variant.violations) '[$label] $violation',
      for (final line in _diffNames(defaults, variant.names))
        '[$label] exported names differ from the default platform: $line',
    ]);
    report.importOnly.addAll(variant.importOnly);
  }

  return report;
}

/// Above this many combinations the check refuses rather than slow down.
const _maxPlatforms = 64;

/// Every non-empty assignment of the [conditions]: each name absent or set
/// to one of the values tested for it.
List<Map<String, String>> _platforms(Map<String, Set<String>> conditions) {
  var platforms = [<String, String>{}];
  for (final MapEntry(:key, :value) in conditions.entries) {
    platforms = [
      for (final platform in platforms) ...[
        platform,
        for (final option in value.toList()..sort()) {...platform, key: option},
      ],
    ];
    if (platforms.length > _maxPlatforms) {
      throw StateError(
        'more than $_maxPlatforms combinations of directive conditions; '
        'narrow them or raise _maxPlatforms',
      );
    }
  }

  return platforms.where((platform) => platform.isNotEmpty).toList();
}

Future<void> _analyzeUnder(
  String root,
  ResourceProvider provider,
  Map<String, String> declared,
  _CheckExportBoundary report,
) async {
  // The public AnalysisContextCollection has no declared-variables
  // parameter; the implementation class it constructs does.
  final collection = AnalysisContextCollectionImpl(
    includedPaths: ['$root/lib'],
    resourceProvider: provider,
    declaredVariables: declared,
  );
  try {
    for (final relative in _publicLibraries(root, provider)) {
      final session = collection
          .contextFor('$root/lib/$relative')
          .currentSession;
      final result = await session.getLibraryByUri('$_package$relative');
      if (result is! LibraryElementResult) {
        report.violations.add('$relative: did not resolve as a library');
        continue;
      }
      _checkLibrary(relative, result.element, report);
    }
  } finally {
    await collection.dispose();
  }
}

/// Every `if (name == value)` a directive under lib/ tests: name to values.
Map<String, Set<String>> _conditions(String root, ResourceProvider provider) {
  final found = SplayTreeMap<String, Set<String>>();
  for (final path in _dartFiles(root, provider)) {
    final source = provider.getFile('$root/lib/$path').readAsStringSync();
    final unit = parseString(content: source, throwIfDiagnostics: false).unit;
    for (final directive in unit.directives.whereType<NamespaceDirective>()) {
      for (final configuration in directive.configurations) {
        found
            .putIfAbsent(configuration.name.toSource(), () => {})
            .add(configuration.value?.stringValue ?? 'true');
      }
    }
  }

  return found;
}

List<String> _publicLibraries(String root, ResourceProvider provider) =>
    _dartFiles(
      root,
      provider,
    ).where((path) => !path.startsWith('src/')).toList();

/// Every `.dart` file under lib/, relative to it, as [provider] sees them
/// (so a self-test control's in-memory files are included).
List<String> _dartFiles(String root, ResourceProvider provider) {
  final lib = '$root/lib';
  final found = <String>[];
  final folders = [provider.getFolder(lib)];
  while (folders.isNotEmpty) {
    for (final child in folders.removeLast().getChildren()) {
      if (child is Folder) {
        folders.add(child);
      } else if (child.path.endsWith('.dart')) {
        found.add(child.path.substring(lib.length + 1));
      }
    }
  }

  return found..sort();
}

void _checkLibrary(
  String name,
  LibraryElement library,
  _CheckExportBoundary report,
) {
  _checkExportDirectives(name, library, report);
  // A top-level variable exports a getter `x` and a setter `x=`: one name,
  // two elements, and both are walked.
  final exported = library.exportNamespace.definedNames2;
  report.names[name] = {
    for (final key in exported.keys) key.replaceFirst(_setterSuffix, ''),
  }.toList()..sort();
  final walker = _SignatureWalker(name, report.violations);
  for (final MapEntry(:key, :value) in exported.entries) {
    if (_forbiddenSource(value) case final uri?) {
      report.violations.add('$name: exports $key, declared in $uri');
    }
    walker.add(value, key);
  }
  walker.run();
  report.importOnly.addAll(_forbiddenByImport(library));
}

/// Rule 1: export directives, followed transitively, ignoring combinators.
void _checkExportDirectives(
  String name,
  LibraryElement library,
  _CheckExportBoundary report,
) {
  final seen = {library};
  final pending = [(library, name)];
  while (pending.isNotEmpty) {
    final (current, path) = pending.removeLast();
    for (final target in _exportedBy(current)) {
      final via = '$path > export ${target.uri}';
      if (_isForbidden(target.uri)) {
        report.violations.add('$name: $via');
      } else if (_isOwn(target.uri) && seen.add(target)) {
        pending.add((target, via));
      }
    }
  }
}

Iterable<LibraryElement> _exportedBy(LibraryElement library) => [
  for (final fragment in library.fragments)
    for (final directive in fragment.libraryExports) ?directive.exportedLibrary,
];

/// The forbidden libraries reachable through imports and exports.
Set<String> _forbiddenByImport(LibraryElement library) {
  final reached = <String>{};
  final seen = {library};
  final pending = [library];
  while (pending.isNotEmpty) {
    final current = pending.removeLast();
    final next = [
      ..._exportedBy(current),
      for (final fragment in current.fragments) ...fragment.importedLibraries,
    ];
    for (final target in next) {
      if (_isForbidden(target.uri)) {
        reached.add(target.uri.toString());
      } else if (_isOwn(target.uri) && seen.add(target)) {
        pending.add(target);
      }
    }
  }

  return reached;
}

/// Rule 2: walks public signatures, iteratively, from the exported elements.
final class _SignatureWalker {
  _SignatureWalker(this._library, this._violations);

  final String _library;
  final List<String> _violations;
  final Set<Element> _seen = {};
  final List<(Element, String)> _pending = [];

  void add(Element element, String path) {
    if (_seen.add(element)) _pending.add((element, path));
  }

  void run() {
    while (_pending.isNotEmpty) {
      final (element, path) = _pending.removeLast();
      for (final (type, label) in _typesOf(element)) {
        _visitType(type, '$path ($label)');
      }
      for (final member in _membersOf(element)) {
        add(member, '$path.${member.displayName}');
      }
    }
  }

  void _visitType(DartType root, String path) {
    final types = [root];
    while (types.isNotEmpty) {
      final type = types.removeLast();
      final alias = type.alias;
      if (alias != null) {
        _reference(alias.element, path);
        types.addAll(alias.typeArguments);
      }
      types.addAll(_componentsOf(type));
      if (type is InterfaceType) _reference(type.element, path);
    }
  }

  void _reference(Element element, String path) {
    final uri = element.library?.uri;
    if (uri == null) return;
    if (_forbiddenSource(element) case final source?) {
      _violations.add(
        '$_library: $path names ${element.displayName}, declared in $source',
      );
    } else if (_isOwn(uri)) {
      add(element, '$path > ${element.displayName}');
    }
  }
}

/// The types a type is built from: arguments, parameters, fields, bounds.
List<DartType> _componentsOf(DartType type) => switch (type) {
  InterfaceType(:final typeArguments) => typeArguments,
  FunctionType(
    :final returnType,
    :final formalParameters,
    :final typeParameters,
  ) =>
    [
      returnType,
      for (final parameter in formalParameters) parameter.type,
      for (final parameter in typeParameters) ?parameter.bound,
    ],
  RecordType(:final positionalFields, :final namedFields) => [
    for (final field in positionalFields) field.type,
    for (final field in namedFields) field.type,
  ],
  _ => const [],
};

/// The types [element]'s own signature names, each with a label.
List<(DartType, String)> _typesOf(Element element) => [
  if (element is TypeParameterizedElement)
    for (final parameter in element.typeParameters)
      if (parameter.bound case final bound?)
        (bound, 'bound of ${parameter.displayName}'),
  ...switch (element) {
    InterfaceElement() => _supertypesOf(element),
    ExtensionElement(:final extendedType) => [(extendedType, 'on')],
    ExecutableElement(:final type) => [(type, 'signature')],
    VariableElement(:final type) => [(type, 'type')],
    TypeAliasElement(:final aliasedType) => [(aliasedType, 'aliased type')],
    _ => const <(DartType, String)>[],
  },
];

List<(DartType, String)> _supertypesOf(InterfaceElement element) => [
  if (element.supertype case final supertype?) (supertype, 'extends'),
  for (final type in element.mixins) (type, 'with'),
  for (final type in element.interfaces) (type, 'implements'),
  if (element is MixinElement)
    for (final type in element.superclassConstraints) (type, 'on'),
  if (element is ExtensionTypeElement)
    (element.representation.type, 'representation'),
];

/// The public members of [element], when it declares any.
List<Element> _membersOf(Element element) => switch (element) {
  InstanceElement() => [
    ...element.fields,
    ...element.getters,
    ...element.setters,
    ...element.methods,
    if (element is InterfaceElement) ...element.constructors,
  ].where((member) => member.isPublic).toList(),
  _ => const [],
};

/// The golden file's text for [names].
String _renderGolden(Map<String, List<String>> names) {
  final out = StringBuffer()
    ..writeln('# Every name each public library exports, one section per')
    ..writeln('# library. tool/check_export_boundary.dart fails on any')
    ..writeln('# difference. A diff here is a public API change: review it')
    ..writeln('# as one, then regenerate this file with')
    ..writeln('#   $_command --update');
  for (final MapEntry(:key, :value) in names.entries) {
    out
      ..writeln()
      ..writeln('[$key]');
    value.forEach(out.writeln);
  }

  return out.toString();
}

/// The added (`+`) and removed (`-`) names, per library.
List<String> _diffGolden(String golden, Map<String, List<String>> names) =>
    _diffNames(_parseGolden(golden), names);

List<String> _diffNames(
  Map<String, Iterable<String>> expected,
  Map<String, List<String>> names,
) {
  final libraries = {...expected.keys, ...names.keys}.toList()..sort();
  final diff = <String>[];
  for (final library in libraries) {
    final want = (expected[library] ?? const <String>[]).toSet();
    final have = (names[library] ?? const <String>[]).toSet();
    final lines = [
      for (final name in have.difference(want)) '  + $name',
      for (final name in want.difference(have)) '  - $name',
    ]..sort((a, b) => a.substring(4).compareTo(b.substring(4)));
    if (lines.isNotEmpty) diff.addAll(['  [$library]', ...lines]);
  }

  return diff;
}

Map<String, Set<String>> _parseGolden(String text) {
  final sections = <String, Set<String>>{};
  var current = <String>{};
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    if (line.startsWith('[') && line.endsWith(']')) {
      current = sections[line.substring(1, line.length - 1)] = <String>{};
    } else {
      current.add(line);
    }
  }

  return sections;
}

// ---------------------------------------------------------------------------
// Negative and positive controls. Each one edits the package IN MEMORY (an
// analyzer overlay; nothing on disk changes) and asserts the check's verdict.
// An edit whose anchor is missing throws, so a control can never pass by
// silently not applying.
// ---------------------------------------------------------------------------

String Function(String) _insertBefore(String anchor, String text) =>
    (original) => _replaceOnce(original, anchor, '$text$anchor');

String Function(String) _insertAfter(String anchor, String text) =>
    (original) => _replaceOnce(original, anchor, '$anchor$text');

String _replaceOnce(String original, String anchor, String replacement) {
  final first = original.indexOf(anchor);
  if (first < 0 || original.indexOf(anchor, first + 1) >= 0) {
    throw StateError('control anchor not found exactly once: "$anchor"');
  }

  return original.replaceFirst(anchor, replacement);
}

/// Which rules a control must trip: none, only the golden list, only the
/// boundary rules (the golden list unchanged), or both.
enum _Verdict { pass, golden, boundary, both }

final class _Control {
  const _Control(
    this.name,
    this.verdict,
    this.mentions,
    this.edits, {
    this.needsImport = false,
  });

  final String name;
  final _Verdict verdict;

  /// Text the failure output must contain.
  final String mentions;

  /// Whether a worker library must be reached through an import.
  final bool needsImport;

  /// Package-relative path to edit (a missing file starts empty).
  final Map<String, String Function(String original)> edits;
}

const _proto =
    "import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart'"
    ' as boundary_probe;\n';
const _nestedProbe =
    "import 'package:dart_monty_core/src/boundary_probe_a.dart'"
    ' as boundary_probe;\n';
const _valueAnchor = 'sealed class MontyValue {\n';
const _partAnchor = "part 'monty_value_scalars.dart';";

final _controls = [
  const _Control('unchanged package passes', _Verdict.pass, '', {}),
  _Control(
    'worker type exported',
    _Verdict.both,
    'exports FrameDecoder',
    {
      'lib/dart_monty_core.dart': (s) =>
          "${s}export 'src/worker/frame.dart' show FrameDecoder;\n",
    },
  ),
  _Control(
    'worker library exported with no names shown',
    _Verdict.boundary,
    '> export package:dart_monty_core/src/worker/frame.dart',
    {
      'lib/dart_monty_core.dart': (s) =>
          "${s}export 'src/worker/frame.dart' show NoSuchName;\n",
    },
  ),
  _Control(
    'worker library exported on a conditional branch only',
    _Verdict.boundary,
    '==true] dart_monty_core.dart: dart_monty_core.dart > export '
        'package:dart_monty_core/src/worker/frame.dart',
    {
      'lib/dart_monty_core.dart': (s) =>
          "${s}export 'src/monty_factory_stub.dart'\n"
          "    if (dart.library.boundary_probe) 'src/worker/frame.dart';\n",
    },
  ),
  _Control(
    'proto type selected only when two conditions hold together',
    _Verdict.boundary,
    'boundary_a==true dart.library.boundary_b==true] dart_monty_core.dart: '
        'MontyValue.boundaryProbe (signature) names Arena',
    {
      'lib/src/boundary_probe_a.dart': (_) =>
          "export 'boundary_probe_stub.dart'\n"
          "    if (dart.library.boundary_a) 'boundary_probe_b.dart';\n",
      'lib/src/boundary_probe_b.dart': (_) =>
          "export 'boundary_probe_stub.dart'\n"
          "    if (dart.library.boundary_b) 'worker/proto/monty/v1/monty.pb.dart'"
          ' show Arena;\n',
      'lib/src/boundary_probe_stub.dart': (_) => 'class Arena {}\n',
      'lib/src/platform/monty_value.dart': (s) => _insertAfter(
        _valueAnchor,
        '  boundary_probe.Arena? get boundaryProbe => null;\n',
      )(_insertBefore(_partAnchor, _nestedProbe)(s)),
    },
  ),
  _Control(
    'worker part file declaring an exported name',
    _Verdict.both,
    'exports BoundaryProbePart, declared in '
        'package:dart_monty_core/src/worker/boundary_probe_part.dart',
    {
      'lib/src/worker/boundary_probe_part.dart': (_) =>
          "part of '../platform/monty_value.dart';\n"
          'final class BoundaryProbePart {}\n',
      'lib/src/platform/monty_value.dart': _insertAfter(
        _partAnchor,
        "\npart '../worker/boundary_probe_part.dart';",
      ),
    },
  ),
  _Control(
    'proto type in a public member signature',
    _Verdict.boundary,
    'names Arena',
    {
      'lib/src/platform/monty_value.dart': (s) => _insertAfter(
        _valueAnchor,
        '  boundary_probe.Arena? get boundaryProbe => null;\n',
      )(_insertBefore(_partAnchor, _proto)(s)),
    },
  ),
  _Control(
    'proto type behind an unexported package type',
    _Verdict.boundary,
    'BoundaryProbe.arena (type) names Arena',
    {
      'lib/src/boundary_probe.dart': (_) =>
          '${_proto}class BoundaryProbe { boundary_probe.Arena? arena; }\n',
      'lib/src/platform/monty_value.dart': (s) => _insertAfter(
        _valueAnchor,
        '  BoundaryProbe? get boundaryProbe => null;\n',
      )(_insertBefore(_partAnchor, "import '../boundary_probe.dart';\n")(s)),
    },
  ),
  _Control(
    'unlisted export',
    _Verdict.golden,
    '+ VfsAccountant',
    {
      'lib/dart_monty_core.dart': (s) =>
          "${s}export 'src/mount/vfs_accountant.dart';\n",
    },
  ),
  _Control(
    'worker imported for implementation only (allowed)',
    _Verdict.pass,
    '',
    {
      'lib/src/monty.dart': (s) =>
          "import 'package:dart_monty_core/src/worker/frame.dart';\n$s"
          'int _boundaryProbe() => Frame.maxLength;\n'
          'Object _boundaryProbeUse() => _boundaryProbe;\n',
    },
    needsImport: true,
  ),
];

Future<int> _selfTest(String root) async {
  final golden = File('$root/$_goldenPath').readAsStringSync();
  var failures = 0;
  for (final control in _controls) {
    final problem = await _runControl(root, golden, control);
    stdout.writeln('${problem == null ? 'PASS' : 'FAIL'}  ${control.name}');
    if (problem != null) {
      stdout.writeln('      $problem');
      failures++;
    }
  }
  stdout.writeln(
    failures == 0
        ? 'EXPORT BOUNDARY SELF-TEST GREEN (${_controls.length} controls)'
        : 'EXPORT BOUNDARY SELF-TEST RED ($failures failed)',
  );

  return failures == 0 ? 0 : 1;
}

/// Runs one control; returns why it failed, or null.
Future<String?> _runControl(
  String root,
  String golden,
  _Control control,
) async {
  final provider = OverlayResourceProvider(PhysicalResourceProvider.INSTANCE);
  for (final MapEntry(:key, :value) in control.edits.entries) {
    final file = File('$root/$key');
    final original = file.existsSync() ? file.readAsStringSync() : '';
    provider.setOverlay(
      file.path,
      content: value(original),
      modificationStamp: 0,
    );
  }
  final report = await _analyzeBoundary(root, provider);
  final diff = _diffGolden(golden, report.names);
  final output = [...report.violations, ...diff].join('\n');
  final verdict = switch ((report.violations.isEmpty, diff.isEmpty)) {
    (true, true) => _Verdict.pass,
    (true, false) => _Verdict.golden,
    (false, true) => _Verdict.boundary,
    (false, false) => _Verdict.both,
  };
  if (verdict != control.verdict) {
    return 'expected ${control.verdict.name}, got ${verdict.name}:\n$output';
  }
  if (control.needsImport && report.importOnly.isEmpty) {
    return 'no worker library was reached by import: the control is vacuous';
  }

  return output.contains(control.mentions)
      ? null
      : 'output does not mention "${control.mentions}":\n$output';
}

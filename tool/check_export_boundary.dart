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
// 3. GOLDEN. The exported names equal tool/export-golden.txt, per library,
//    and so do the public members of every declaration rule 2 reaches. A
//    difference prints the added and removed lines; review it as a public API
//    change, then rewrite the file with --update.
//
// THE MEMBER GOLDEN. Each declaration of this package that rule 2 reaches
// (exported, named by a public signature, or a supertype of one, private
// classes included) is printed once, in a `[members: <path>]` section for the
// library that declares it; the per-library `[<path>]` sections stay
// names-only, so a library that re-exports another does not repeat its
// members. A declaration prints its kind, modifiers, type parameters with
// bounds and supertypes; each public member prints its kind, modifiers,
// parameters (position, `required`, `covariant`, name, type and default
// value source) and type. Types are named with their library wherever the
// bare name could mean another declaration, and when two printed
// declarations share a name, an `[exports: <path>]` section records which
// one each public library exports. The printer is this tool's own and reads
// only the
// element model: the analyzer's display-string formatter is never called (the
// check fails if this file names it), so an analyzer upgrade changes the
// golden only where the element model changes.
//
// IMPORTS ARE ALLOWED. Rule 1 and 2 are "exported or in a public signature",
// not "reachable". A public library may import worker code and use it in
// function bodies and private members; the session built on the worker must
// do exactly that. A literal reachability rule would block it, so the walk
// over imports is reported for information and never fails the check.
//
// Exit codes: 0 pass, 1 a rule failed, 2 the check itself could not run.

import 'dart:collection';
import 'dart:convert' show jsonEncode;
import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
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

  /// Printed declarations and members, per declaring library, keyed
  /// `members: <path under lib/>`.
  final Map<String, List<String>> members = {};

  /// Every own declaration rule 2 reached.
  final Set<Element> declarations = {};

  /// What each public library's exported names refer to.
  final Map<String, Map<String, Element>> exports = {};

  /// The names and member sections together, as the golden lists them.
  Map<String, List<String>> get sections => {...names, ...members};

  /// As [sections], with the `members:` sections' lines in one section: a
  /// conditional export selects a different file per platform, so platforms
  /// are compared on what they declare, not on which file declares it. The
  /// `exports:` sections keep their library.
  Map<String, List<String>> get platformSections => {
    ...names,
    for (final MapEntry(:key, :value) in members.entries)
      if (!key.startsWith('members: ')) key: value,
    'members': [
      for (final MapEntry(:key, :value) in members.entries)
        if (key.startsWith('members: ')) ...value,
    ],
  };

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
  _checkToolSource(_toolSource(root), report);
  final golden = File('$root/$_goldenPath');
  if (update) {
    golden.writeAsStringSync(_renderGolden(report.sections));
    stdout.writeln('wrote $_goldenPath');
  }
  final diff = _diffGolden(
    golden.existsSync() ? golden.readAsStringSync() : '',
    report.sections,
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
  final printed = [
    for (final MapEntry(:key, :value) in report.members.entries)
      if (key.startsWith('members: ')) ...value,
  ];
  final members = printed.where((line) => line.startsWith(' ')).length;
  stdout
    ..writeln('${unique.length} unique exported names')
    ..writeln(
      '${printed.length - members} declarations and $members public members '
      'from ${report.declarations.map((e) => e.library).toSet().length} '
      'declaring libraries',
    )
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
    stdout.writeln(
      'FAIL exported names or public members differ from $_goldenPath:',
    );
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
  final defaults = report.platformSections;
  for (final declared in _platforms(_conditions(root, provider))) {
    final variant = _CheckExportBoundary();
    await _analyzeUnder(root, provider, declared, variant);
    final label = declared.entries
        .map((entry) => '${entry.key}==${entry.value}')
        .join(' ');
    report.conditions.add(label);
    report.violations.addAll([
      for (final violation in variant.violations) '[$label] $violation',
      for (final line in _diffNames(defaults, variant.platformSections))
        '[$label] $_differsFromDefault: $line',
    ]);
    report.importOnly.addAll(variant.importOnly);
  }

  return report;
}

const _differsFromDefault =
    'exported names or members differ from the default platform';

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
    // Printed while the collection is alive: the elements belong to it.
    report.members
      ..addAll(_printDeclarations(report.declarations))
      ..addAll(_printAmbiguousExports(report.exports));
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
  report.exports[name] = Map.of(exported);
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
  report.declarations.addAll(
    walker.seen
        .map(_declarationOf)
        .nonNulls
        .where(
          (element) => _forbiddenSource(element) == null,
        ),
  );
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

  /// Every element walked so far.
  Set<Element> get seen => _seen;

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

// ---------------------------------------------------------------------------
// The member golden's printer. It reads the element model only; every type is
// printed by _type below, never by the analyzer's own formatter.
// ---------------------------------------------------------------------------

/// The library-level declaration [element] is or belongs to, when it is one
/// of this package's: a top-level variable for its implicit accessors.
Element? _declarationOf(Element element) {
  final declaration = switch (element) {
    PropertyAccessorElement(isOriginVariable: true, :final variable) =>
      variable,
    _ => element,
  };
  final library = declaration.library;
  if (library == null || !_isOwn(library.uri)) return null;

  return declaration.enclosingElement is LibraryElement ? declaration : null;
}

/// The member sections for [declarations]: per declaring library, each
/// declaration's line followed by its public members' lines, indented.
Map<String, List<String>> _printDeclarations(Set<Element> declarations) {
  _typeNames = _TypeNames(declarations);
  final byLibrary = SplayTreeMap<String, Map<String, Element>>();
  for (final element in declarations) {
    final path = element.library!.uri.toString().substring(_package.length);
    byLibrary.putIfAbsent('members: $path', () => {})[_sortKey(element)] =
        element;
  }

  return {
    for (final MapEntry(:key, :value) in byLibrary.entries)
      key: [
        for (final name in value.keys.toList()..sort())
          ..._printDeclaration(value[name]!),
      ],
  };
}

/// How [_type] names the declaration of a type or alias, set for each
/// printing run.
_TypeNames _typeNames = _TypeNames(const {});

/// A type's name with its library when the name alone could mean another
/// declaration: bare for what `dart:core` exports and for this package's
/// declarations whose name is unique (in the run, against `dart:core` and
/// against every type parameter the printed signatures declare),
/// `Name@<path under lib/>` for this package's others, and
/// `Name@<library URI>` for everything else.
final class _TypeNames {
  _TypeNames(Set<Element> declarations) {
    for (final element in declarations) {
      final name = _nameOf(element);
      _own[name] = (_own[name] ?? 0) + 1;
      [element, ..._membersOf(element)].forEach(_collectTypeParameters);
    }
  }

  final Map<String, int> _own = {};

  /// Every type parameter name in the printed signatures: a nominal type of
  /// the same name is qualified, so `T` is never both.
  final Set<String> _typeParameters = {};

  void _collectTypeParameters(Element element) {
    if (element is TypeParameterizedElement) {
      _typeParameters.addAll(element.typeParameters.map(_nameOf));
    }
    final types = [for (final (type, _) in _typesOf(element)) type];
    while (types.isNotEmpty) {
      final type = types.removeLast();
      if (type is FunctionType) {
        _typeParameters.addAll(type.typeParameters.map(_nameOf));
      }
      types.addAll([...?type.alias?.typeArguments, ..._componentsOf(type)]);
    }
  }

  /// Whether more than one printed declaration is named [name].
  bool isAmbiguous(String name) => (_own[name] ?? 0) > 1;

  /// `Never`, bare unless a type parameter takes its name.
  String never() =>
      _typeParameters.contains('Never') ? 'Never@dart:core' : 'Never';

  String of(Element element) {
    final name = _nameOf(element);
    final library = element.library;
    if (library == null) return name;
    final core = library.typeProvider.objectElement.library;
    final fromCore = core.exportNamespace.get2(name);
    final shadowed = _typeParameters.contains(name);
    if (_isOwn(library.uri)) {
      final unique = (_own[name] ?? 0) <= 1 && fromCore == null && !shadowed;
      final path = library.uri.toString().substring(_package.length);

      return unique ? name : '$name@$path';
    }

    return fromCore == element && !shadowed ? name : '$name@${library.uri}';
  }
}

/// For each public library, the declaring library of every exported name
/// that more than one printed declaration bears, in an `exports: <path>`
/// section: which of two `Item`s a library exports is API.
Map<String, List<String>> _printAmbiguousExports(
  Map<String, Map<String, Element>> exports,
) {
  final sections = <String, List<String>>{};
  for (final MapEntry(key: library, value: names) in exports.entries) {
    final lines = <String>{};
    for (final MapEntry(:key, :value) in names.entries) {
      final declaration = _declarationOf(value);
      if (declaration == null) continue;
      if (!_typeNames.isAmbiguous(_nameOf(declaration))) continue;
      final path = declaration.library!.uri.toString().substring(
        _package.length,
      );
      lines.add('${key.replaceFirst(_setterSuffix, '')}: $path');
    }
    if (lines.isNotEmpty) {
      sections['exports: $library'] = lines.toList()..sort();
    }
  }

  return sections;
}

String _sortKey(Element element) =>
    '${_nameOf(element)}${element is SetterElement ? '=' : ''}';

String _nameOf(Element element) => element.name ?? '<unnamed>';

List<String> _printDeclaration(Element element) {
  final name = _nameOf(element);
  final members = [
    for (final member in _membersOf(element))
      if (_printMember(member) case final line?) '  $name.$line',
    if (element is ClassElement && element.isSealed)
      for (final subtype in _permitted(element)) '  $name: permits $subtype',
  ]..sort();

  return [_printHead(element), ...members];
}

/// The declaration lines of [element]'s supertypes in this package, other
/// than [sealed], transitively: a subtype can reach a public type through a
/// private ancestor.
Iterable<String> _ancestors(InterfaceElement element, ClassElement sealed) {
  final seen = <InterfaceElement>{element, sealed};
  final pending = [element];
  final heads = <String>[];
  while (pending.isNotEmpty) {
    final current = pending.removeLast();
    for (final type in [
      ?current.supertype,
      ...current.mixins,
      ...current.interfaces,
      if (current is MixinElement) ...current.superclassConstraints,
    ]) {
      final ancestor = type.element;
      if (_isOwn(ancestor.library.uri) && seen.add(ancestor)) {
        heads.add(_printHead(ancestor));
        pending.add(ancestor);
      }
    }
  }

  return heads;
}

/// The declaration line of every subtype of the sealed class [sealed],
/// private ones included, and of each sealed subtype's in turn: exhaustive
/// switches over [sealed] depend on which subtypes exist and on what each
/// one extends and implements, so all of it is API.
List<String> _permitted(ClassElement sealed) {
  final found = <String>{};
  final pending = [sealed];
  while (pending.isNotEmpty) {
    final parent = pending.removeLast();
    final library = parent.library;
    final candidates = <InterfaceElement>[
      ...library.classes,
      ...library.mixins,
      ...library.enums,
    ];
    for (final candidate in candidates) {
      final supertypes = [
        ?candidate.supertype,
        ...candidate.mixins,
        ...candidate.interfaces,
        if (candidate is MixinElement) ...candidate.superclassConstraints,
      ];
      if (!supertypes.any((type) => type.element == parent)) continue;
      if (found.add(_printHead(candidate)) &&
          candidate is ClassElement &&
          candidate.isSealed) {
        pending.add(candidate);
      }
      found.addAll(_ancestors(candidate, sealed).map((head) => 'via $head'));
    }
  }

  // An ancestor that is itself a permitted subtype is listed once, as one.
  found.removeWhere(
    (line) => line.startsWith('via ') && found.contains(line.substring(4)),
  );

  return found.isEmpty ? const ['nothing'] : (found.toList()..sort());
}

/// The declaration's own line: modifiers, kind, name, type parameters,
/// supertypes or type.
String _printHead(Element element) {
  final name = _nameOf(element);
  final generics = element is TypeParameterizedElement
      ? _typeParameters(element.typeParameters)
      : '';

  return switch (element) {
    ClassElement() => _words([
      ..._classModifiers(element),
      'class $name$generics${_supertypes(element)}',
    ]),
    MixinElement() => _words([
      if (element.isBase) 'base',
      'mixin $name$generics${_constraints(element)}',
    ]),
    EnumElement() => 'enum $name$generics${_supertypes(element)}',
    ExtensionTypeElement(:final representation) =>
      'extension type $name$generics'
          '(${_type(representation.type)} ${_nameOf(representation)})'
          '${_list(' implements ', element.interfaces, keepObject: true)}',
    ExtensionElement(:final extendedType) =>
      'extension $name$generics on ${_type(extendedType)}',
    TypeAliasElement(:final aliasedType) =>
      'typedef $name$generics = ${_type(aliasedType)}',
    TopLevelVariableElement() => _words([
      if (element.isExternal) 'external',
      ..._variableModifiers(element),
      'variable',
      _type(element.type),
      ?_constantValue(element),
    ], prefix: '$name: '),
    ExecutableElement() => _printExecutable(element, name),
    _ => throw StateError(
      'no canonical form for ${element.kind.displayName} $name',
    ),
  };
}

/// ` on C implements I`.
String _constraints(MixinElement element) =>
    _list(' on ', element.superclassConstraints) +
    _list(' implements ', element.interfaces);

List<String> _classModifiers(ClassElement element) => element.isSealed
    ? ['sealed']
    : [
        if (element.isAbstract) 'abstract',
        if (element.isBase) 'base',
        if (element.isInterface) 'interface',
        if (element.isFinal) 'final',
        if (element.isMixinClass) 'mixin',
      ];

/// ` extends S with M implements I`, leaving out the implicit `Object` and
/// an enum's implicit `Enum`.
String _supertypes(InterfaceElement element) {
  final supertype = element.supertype;
  final implicit =
      supertype == null ||
      supertype.isDartCoreObject ||
      (element is EnumElement && supertype.isDartCoreEnum);

  return '${implicit ? '' : ' extends ${_type(supertype)}'}'
      '${_list(' with ', element.mixins)}'
      '${_list(' implements ', element.interfaces)}';
}

/// [types] after [keyword], leaving out a redundant `Object`, unless
/// [keepObject]: an extension type is an `Object` only if it says so.
String _list(
  String keyword,
  List<DartType> types, {
  bool keepObject = false,
}) {
  final shown = [
    for (final type in types)
      if (keepObject || !type.isDartCoreObject) type,
  ];

  return shown.isEmpty ? '' : '$keyword${shown.map(_type).join(', ')}';
}

/// One member's line, after `Declaration.`, or null when it only stands for
/// another one (a field's implicit accessors, an explicit getter's field) or
/// cannot be called from outside (an enum's constructors).
String? _printMember(Element member) {
  final name = _nameOf(member);

  return switch (member) {
    ConstructorElement(enclosingElement: EnumElement()) => null,
    ConstructorElement() => _words([
      if (member.isExternal) 'external',
      if (member.isConst) 'const',
      if (member.isFactory) 'factory',
      'constructor${_parameters(member.formalParameters)}',
      if (member.redirectedConstructor != null) 'redirecting',
    ], prefix: '$name: '),
    FieldElement(isOriginGetterSetter: true) => null,
    FieldElement() => _words([
      if (member.isStatic) 'static',
      if (member.isAbstract) 'abstract',
      if (member.isExternal) 'external',
      if (member.isCovariant) 'covariant',
      ..._variableModifiers(member),
      if (member.isEnumConstant)
        'enum value #${_enumIndex(member)}'
      else
        'field',
      _type(member.type),
      ?_constantValue(member),
    ], prefix: '$name: '),
    PropertyAccessorElement(isOriginVariable: true) => null,
    ExecutableElement() => _printExecutable(member, name),
    _ => throw StateError(
      'no canonical form for member ${member.kind.displayName} $name',
    ),
  };
}

/// `late`, `const` or `final`, and `settable` when the variable has a
/// public setter: a `late final` one without an initializer has one, and
/// gaining an initializer removes it.
List<String> _variableModifiers(PropertyInducingElement element) => [
  if (element.isLate) 'late',
  if (element.isConst) 'const' else if (element.isFinal) 'final',
  if (element.setter case final setter? when setter.isPublic) 'settable',
];

/// A method, operator, getter, setter or top-level function.
String _printExecutable(ExecutableElement element, String name) {
  final kind = switch (element) {
    GetterElement() => 'getter',
    SetterElement() => 'setter',
    MethodElement(isOperator: true) => 'operator',
    MethodElement() => 'method',
    TopLevelFunctionElement() => 'function',
    _ => throw StateError('no canonical form for $name'),
  };
  final signature = switch (element) {
    GetterElement() => ' -> ${_type(element.returnType)}',
    SetterElement() => _parameters(element.formalParameters),
    _ =>
      '${_typeParameters(element.typeParameters)}'
          '${_parameters(element.formalParameters)}'
          ' -> ${_type(element.returnType)}',
  };
  final member = element.enclosingElement is! LibraryElement;

  return _words([
    if (element.isStatic && member) 'static',
    if (element.isAbstract) 'abstract',
    if (element.isExternal) 'external',
    '$kind$signature',
  ], prefix: '${element is SetterElement ? '$name=' : name}: ');
}

String _words(List<String> words, {String prefix = ''}) =>
    '$prefix${words.join(' ')}';

String _typeParameters(List<TypeParameterElement> parameters) =>
    parameters.isEmpty
    ? ''
    : '<${parameters.map((parameter) {
        final bound = parameter.bound;

        return '${_nameOf(parameter)}'
            '${bound == null ? '' : ' extends ${_type(bound)}'}';
      }).join(', ')}>';

/// `(A a, [B b = 1], {required C c, D d})`; with [positionalNames] false,
/// as in a function type, positional parameters print their types only.
String _parameters(
  List<FormalParameterElement> parameters, {
  bool positionalNames = true,
}) {
  String one(FormalParameterElement parameter) {
    final name = parameter.isNamed || positionalNames
        ? ' ${_nameOf(parameter)}'
        : '';
    final source = _oneLine(parameter.defaultValueCode);
    final resolved = source != null && _reference.hasMatch(source)
        ? _constant(parameter.computeConstantValue())
        : null;
    final value = resolved == null || resolved == source
        ? source
        : '$source ($resolved)';

    return _words([
      if (parameter.isCovariant) 'covariant',
      if (parameter.isRequiredNamed) 'required',
      '${_type(parameter.type)}$name${value == null ? '' : ' = $value'}',
    ]);
  }

  final required = [
    for (final parameter in parameters)
      if (parameter.isRequiredPositional) one(parameter),
  ];
  final optional = [
    for (final parameter in parameters)
      if (parameter.isOptionalPositional) one(parameter),
  ];
  final keyed = [
    for (final parameter in parameters)
      if (parameter.isNamed) one(parameter),
  ];

  return '(${[
    ...required,
    if (optional.isNotEmpty) '[${optional.join(', ')}]',
    if (keyed.isNotEmpty) '{${keyed.join(', ')}}',
  ].join(', ')})';
}

/// A default value that only names a constant: the printer adds the value,
/// since changing the constant changes the default.
final _reference = RegExp(r'^[A-Za-z_$][\w$]*(\.[A-Za-z_$][\w$]*)*$');

/// The position of the enum value [field] among its enum's values: `index`
/// and the order of `values` are API.
int _enumIndex(FieldElement field) =>
    (field.enclosingElement as EnumElement).constants.indexOf(field);

/// `= value` for a `const` variable whose value [_constant] can print.
String? _constantValue(PropertyInducingElement element) {
  if (!element.isConst || element is FieldElement && element.isEnumConstant) {
    return null;
  }
  final value = _constant(element.computeConstantValue());

  return value == null ? null : '= $value';
}

/// A constant's value when it is null, a bool, a number, a string or an
/// enum value; null for anything else, which the golden then leaves out.
String? _constant(DartObject? value) {
  if (value == null) return null;
  if (value.isNull) return 'null';
  final simple =
      value.toBoolValue() ?? value.toIntValue() ?? value.toDoubleValue();
  if (simple != null) return '$simple';
  if (value.toStringValue() case final text?) {
    return _oneLine(jsonEncode(text));
  }
  if (value.variable case final FieldElement field when field.isEnumConstant) {
    return '${_nameOf(field.enclosingElement)}.${_nameOf(field)}';
  }

  return null;
}

/// [source] on one line, as the golden is line-based: line endings
/// normalized to `\n` (a CRLF checkout prints the same), then backslash and
/// newline escaped, reversibly.
String? _oneLine(String? source) => source
    ?.replaceAll('\r\n', '\n')
    .replaceAll('\r', '\n')
    .replaceAll(r'\', r'\\')
    .replaceAll('\n', r'\n');

/// The tool's canonical text for [type]: the alias when the type was written
/// through one, type arguments, and `?` for a nullable type.
String _type(DartType type) {
  final nullable = type.nullabilitySuffix == NullabilitySuffix.question;
  if (type.alias case InstantiatedTypeAliasElement(
    :final element,
    :final typeArguments,
  )) {
    final aliasNullable =
        element.aliasedType.nullabilitySuffix == NullabilitySuffix.question;

    return '${_typeNames.of(element)}${_arguments(typeArguments)}'
        '${nullable && !aliasNullable ? '?' : ''}';
  }
  final suffix = nullable ? '?' : '';

  return switch (type) {
    DynamicType() => 'dynamic',
    VoidType() => 'void',
    InvalidType() => throw StateError('an unresolved type in a signature'),
    NeverType() => '${_typeNames.never()}$suffix',
    InterfaceType(:final element, :final typeArguments) =>
      '${_typeNames.of(element)}${_arguments(typeArguments)}$suffix',
    TypeParameterType(:final element) => '${_nameOf(element)}$suffix',
    FunctionType(
      :final returnType,
      :final typeParameters,
      :final formalParameters,
    ) =>
      '${_type(returnType)} Function${_typeParameters(typeParameters)}'
          '${_parameters(formalParameters, positionalNames: false)}$suffix',
    RecordType() => '${_record(type)}$suffix',
    _ => throw StateError('no canonical form for a ${type.runtimeType}'),
  };
}

/// `(A, {B b})`, and `(A,)` for one positional field alone.
String _record(RecordType type) {
  final positional = type.positionalFields.map((field) => _type(field.type));
  final named = [
    for (final field in type.namedFields) '${_type(field.type)} ${field.name}',
  ];
  final fields = [
    ...positional,
    if (named.isNotEmpty) '{${named.join(', ')}}',
  ];

  final trailing = fields.length == 1 && named.isEmpty ? ',' : '';

  return '(${fields.join(', ')}$trailing)';
}

String _arguments(List<DartType> arguments) =>
    arguments.isEmpty ? '' : '<${arguments.map(_type).join(', ')}>';

/// Identifiers in a Dart [source] that reach the analyzer's display-string
/// formatter, with their line numbers. The printer above must not use it.
List<String> _formatterReferences(String source) {
  final result = parseString(content: source, throwIfDiagnostics: false);
  final found = <String>[];
  result.unit.accept(
    _IdentifierVisitor((node) {
      if (_formatter.hasMatch(node.name)) {
        final line = result.lineInfo.getLocation(node.offset).lineNumber;
        found.add('${node.name} at line $line');
      }
    }),
  );

  return found;
}

final _formatter = RegExp('displaystring', caseSensitive: false);

final class _IdentifierVisitor extends RecursiveAstVisitor<void> {
  _IdentifierVisitor(this._onIdentifier);

  final void Function(SimpleIdentifier node) _onIdentifier;

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    _onIdentifier(node);
    super.visitSimpleIdentifier(node);
  }
}

String _toolSource(String root) =>
    File('$root/tool/check_export_boundary.dart').readAsStringSync();

void _checkToolSource(String source, _CheckExportBoundary report) {
  for (final reference in _formatterReferences(source)) {
    report.violations.add(
      'tool/check_export_boundary.dart: names the analyzer formatter, '
      '$reference; print types with _type',
    );
  }
}

/// The golden file's text for [names].
String _renderGolden(Map<String, List<String>> names) {
  final out = StringBuffer()
    ..writeln('# Every name each public library exports, one section per')
    ..writeln('# library, then every declaration those names reach, with its')
    ..writeln('# public members, once, in a "members:" section for the library')
    ..writeln('# that declares it (and, for a name two of them share, an')
    ..writeln('# "exports:" section saying which one each library exports).')
    ..writeln('# tool/check_export_boundary.dart fails on')
    ..writeln('# any difference. A diff here is a public API change: review')
    ..writeln('# it as one, then regenerate this file with')
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
    // Member lines are indented in the file; the indent is layout only.
    final want = {
      for (final line in expected[library] ?? const <String>[]) line.trim(),
    };
    final have = {
      for (final line in names[library] ?? const <String>[]) line.trim(),
    };
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
    this.alsoMentions = const [],
    this.base,
    this.section,
    this.toolEdit,
  });

  final String name;
  final _Verdict verdict;

  /// Text the failure output must contain.
  final String mentions;

  /// Whether a worker library must be reached through an import.
  final bool needsImport;

  /// Package-relative path to edit (a missing file starts empty).
  final Map<String, String Function(String original)> edits;

  /// More text the failure output must contain.
  final List<String> alsoMentions;

  /// Edits the golden is generated from, in place of the committed golden,
  /// so a control can change one detail of a declaration the package lacks.
  final Map<String, String Function(String original)>? base;

  /// A member section the edited package must print exactly.
  final (String, String)? section;

  /// An edit to this tool's own source before its formatter scan.
  final String Function(String original)? toolEdit;
}

const _proto =
    "import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart'"
    ' as boundary_probe;\n';
const _nestedProbe =
    "import 'package:dart_monty_core/src/boundary_probe_a.dart'"
    ' as boundary_probe;\n';
const _valueAnchor = 'sealed class MontyValue {\n';
const _partAnchor = "part 'monty_value_scalars.dart';";

const _limitsAnchor = 'final class MontyLimits {\n';
const _limitsFile = 'lib/src/platform/monty_limits.dart';
const _frameAnchor =
    'static List<MontyStackFrame> listFromJson(List<Object?> jsonList)';
const _frameFile = 'lib/src/platform/monty_stack_frame.dart';
const _memoryFile = 'lib/src/mount/monty_memory_file.dart';

/// A public method with a bounded type parameter, added to MontyLimits.
String Function(String) _boundProbe(String bound) => _insertAfter(
  _limitsAnchor,
  '  T boundaryProbe<T extends $bound>(T value) => value;\n',
);

/// MontyLimits extending a private class, whose public members are
/// inherited: [members] is that class's body.
String Function(String) _privateBase(String members) =>
    (s) => _replaceOnce(
      s,
      _limitsAnchor,
      'abstract class _BoundaryProbeBase {\n'
      '  const _BoundaryProbeBase();\n'
      '$members}\n'
      'final class MontyLimits extends _BoundaryProbeBase {\n',
    );

/// A private subtype of the sealed `VfsNode` with `VfsFile`'s members,
/// declaring [implements].
String _hiddenNode(String implements) =>
    '\nfinal class _BoundaryProbeNode extends VfsNode$implements {\n'
    "  @override String path = '';\n"
    "  @override VfsContent content = VfsText('');\n"
    '  @override int get permissions => 0;\n'
    '}\n';

/// Exports `Item` from [usual], or from [other] when the condition holds.
String _swapExport(String usual, String other) =>
    "export 'src/boundary_probe_$usual.dart'\n"
    "    if (dart.library.boundary_c) 'src/boundary_probe_$other.dart';\n";

/// A private subtype of the sealed `VfsNode` that reaches `VfsFile` only
/// through a private ancestor, which declares [implements].
String _hiddenAncestor(String implements) =>
    '\nabstract class _BoundaryProbeBase$implements {\n'
    "  String path = '';\n"
    "  VfsContent content = VfsText('');\n"
    '  int get permissions => 0;\n'
    '}\n'
    'final class _BoundaryProbeHidden extends _BoundaryProbeBase\n'
    '    implements VfsNode {}\n';

/// Two declarations named `Item`, both in public signatures.
final _sameNames = <String, String Function(String)>{
  'lib/src/boundary_probe_a.dart': (_) => 'class Item {}\n',
  'lib/src/boundary_probe_b.dart': (_) => 'class Item {}\n',
};

/// A public library using both `Item`s; `boundaryTake` takes [take]'s.
String _items(String take) =>
    "import 'src/boundary_probe_a.dart' as a;\n"
    "import 'src/boundary_probe_b.dart' as b;\n"
    'void boundaryBoth(a.Item x, b.Item y) {}\n'
    'void boundaryTake($take.Item x) {}\n';

/// A class whose type parameter is named `String`; `take` takes the type
/// [prefix] names: `core.` for dart:core's, empty for the type parameter.
String _shadow(String prefix, {String type = 'String'}) =>
    "import 'dart:core' as core;\n"
    'class BoundaryProbe<$type> {\n'
    '  void take($prefix$type x) {}\n'
    '}\n';

/// A default value whose source spans two lines and holds a backslash.
const _multiLine = "void boundaryLines({String s = '''a\nb\\\\n'''}) {}\n";

/// A public library declaring one of each kind the printer handles.
const _fixture = '''
library;

import 'dart:async';

typedef ProbeCallback<T extends Object> =
    Future<T?> Function(int count, {required bool flag, String? label});

abstract base class ProbeBase<T extends num>
    implements Comparable<ProbeBase<T>> {
  const ProbeBase();
  int get id;
}

final class Probe<T extends num> extends ProbeBase<T> with ProbeMixin {
  const Probe(this.value, {this.label = 'x', required this.flag,
      this.limit = 3});
  const factory Probe.redirect(T value, {required bool flag}) = Probe<T>;
  factory Probe.make() => throw UnimplementedError();
  final T value;
  final String label;
  final bool flag;
  final int? limit;
  static late final int cache;
  late final int pending;
  static const int max = 9;
  @override
  int get id => 0;
  set name(String value) {}
  int operator [](int index) => index;
  R map<R extends Object?>(R Function(T) f, {(int, {String s})? record}) =>
      f(value);
  void widen(covariant num x, [List<Map<String, int?>>? rows]) {}
  @override
  int compareTo(ProbeBase<T> other) => 0;
  int _hidden() => 0;
}

mixin ProbeMixin {
  int get mixed => 1;
}

base mixin ProbeOn on ProbeBase<int> {}

enum ProbeKind { a, b }

extension ProbeExtension on Probe<int> {
  int get doubled => 2;
  static int helper() => 1;
}

extension type ProbeId(int raw) implements int {}

extension type ProbeObject(int raw) implements Object {}

sealed class ProbeSealed {}

interface class ProbeInterface {}

abstract mixin class ProbeMixinClass {}

sealed class ProbeShape {}

final class ProbeSquare extends ProbeShape {}

sealed class _ProbeRound implements ProbeShape {}

final class _ProbeCircle extends _ProbeRound {}

int probeFunction<T>(T value, {int? count, (String,)? one}) => 0;

late final String probeLate;

const probeConst = 1;

Never probeNever() => throw StateError('');

dynamic probeDynamic;

void Function()? probeCallback;

FutureOr<int> probeFutureOr() => 1;
''';

const _fixturePrinted = '''
final class Probe<T extends num> extends ProbeBase<T> with ProbeMixin
  Probe.[]: operator(int index) -> int
  Probe.cache: static late final settable field int
  Probe.compareTo: method(ProbeBase<T> other) -> int
  Probe.flag: final field bool
  Probe.id: getter -> int
  Probe.label: final field String
  Probe.limit: final field int?
  Probe.make: factory constructor()
  Probe.map: method<R extends Object?>(R Function(T) f, {(int, {String s})? record}) -> R
  Probe.max: static const field int = 9
  Probe.name=: setter(String value)
  Probe.new: const constructor(T value, {String label = 'x', required bool flag, int? limit = 3})
  Probe.pending: late final settable field int
  Probe.redirect: const factory constructor(T value, {required bool flag}) redirecting
  Probe.value: final field T
  Probe.widen: method(covariant num x, [List<Map<String, int?>>? rows]) -> void
abstract base class ProbeBase<T extends num> implements Comparable<ProbeBase<T>>
  ProbeBase.id: abstract getter -> int
  ProbeBase.new: const constructor()
typedef ProbeCallback<T extends Object> = Future<T?> Function(int, {required bool flag, String? label})
extension ProbeExtension on Probe<int>
  ProbeExtension.doubled: getter -> int
  ProbeExtension.helper: static method() -> int
extension type ProbeId(int raw) implements int
  ProbeId.new: constructor(int raw)
  ProbeId.raw: final field int
interface class ProbeInterface
  ProbeInterface.new: constructor()
enum ProbeKind
  ProbeKind.a: static const enum value #0 ProbeKind
  ProbeKind.b: static const enum value #1 ProbeKind
  ProbeKind.values: static const field List<ProbeKind>
mixin ProbeMixin
  ProbeMixin.mixed: getter -> int
abstract mixin class ProbeMixinClass
  ProbeMixinClass.new: constructor()
extension type ProbeObject(int raw) implements Object
  ProbeObject.new: constructor(int raw)
  ProbeObject.raw: final field int
base mixin ProbeOn on ProbeBase<int>
sealed class ProbeSealed
  ProbeSealed.new: constructor()
  ProbeSealed: permits nothing
sealed class ProbeShape
  ProbeShape.new: constructor()
  ProbeShape: permits final class ProbeSquare extends ProbeShape
  ProbeShape: permits final class _ProbeCircle extends _ProbeRound
  ProbeShape: permits sealed class _ProbeRound implements ProbeShape
final class ProbeSquare extends ProbeShape
  ProbeSquare.new: constructor()
probeCallback: settable variable void Function()?
probeConst: const variable int = 1
probeDynamic: settable variable dynamic
probeFunction: function<T>(T value, {int? count, (String,)? one}) -> int
probeFutureOr: function() -> FutureOr@dart:async<int>
probeLate: late final settable variable String
probeNever: function() -> Never
''';

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
    _Verdict.both,
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
    _Verdict.both,
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
    _Verdict.both,
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
  _Control(
    'public member added',
    _Verdict.golden,
    '+ MontyLimits.boundaryProbe: getter -> int',
    {
      _limitsFile: _insertAfter(
        _limitsAnchor,
        '  int get boundaryProbe => 0;\n',
      ),
    },
  ),
  _Control(
    'public member removed',
    _Verdict.golden,
    '- MontyLimits.defaultMaxSuspensions: static const field int',
    {
      _limitsFile: (s) => _replaceOnce(
        s,
        '  static const int defaultMaxSuspensions = 1000;',
        '',
      ),
    },
  ),
  _Control(
    'constructor removed',
    _Verdict.golden,
    '- MontyLimits.jsAligned: factory constructor({int? maxMemory, '
        'double? maxDurationSecs, int? maxRecursionDepth})',
    {
      _limitsFile: (s) => _replaceOnce(
        s,
        'factory MontyLimits.jsAligned({',
        'static MontyLimits jsAligned({',
      ),
    },
    alsoMentions: ['+ MontyLimits.jsAligned: static method('],
  ),
  _Control(
    'parameter renamed',
    _Verdict.golden,
    '+ MontyMemoryFile.new: factory constructor(String path, '
        'Object content, {int mode = 0x1A4})',
    {
      _memoryFile: (s) => _replaceOnce(
        s,
        '    int permissions = 0x1A4,',
        '    int mode = 0x1A4,',
      ),
    },
    alsoMentions: ['- MontyMemoryFile.new: factory constructor('],
  ),
  _Control(
    'parameter type changed',
    _Verdict.golden,
    '+ MontyStackFrame.listFromJson: '
        'static method(Iterable<Object?> jsonList) -> List<MontyStackFrame>',
    {
      _frameFile: (s) => _replaceOnce(
        s,
        _frameAnchor,
        _frameAnchor.replaceFirst('(List<', '(Iterable<'),
      ),
    },
  ),
  _Control(
    'nullability of a type argument changed',
    _Verdict.golden,
    '+ MontyStackFrame.listFromJson: '
        'static method(List<Object> jsonList) -> List<MontyStackFrame>',
    {
      _frameFile: (s) => _replaceOnce(
        s,
        _frameAnchor,
        _frameAnchor.replaceFirst('Object?', 'Object'),
      ),
    },
  ),
  _Control(
    'default value changed',
    _Verdict.golden,
    '+ MontyMemoryFile.withContent: constructor(String path, '
        'VfsContent content, {int permissions = 0x1ED})',
    {
      _memoryFile: (s) => _replaceOnce(
        s,
        '    this.permissions = 0x1A4,',
        '    this.permissions = 0x1ED,',
      ),
    },
  ),
  _Control(
    'const dropped from a constructor',
    _Verdict.golden,
    '+ MontyLimits.new: constructor({int? memoryBytes,',
    {
      _limitsFile: (s) =>
          _replaceOnce(s, '  const MontyLimits({', '  MontyLimits({'),
    },
    alsoMentions: ['- MontyLimits.new: const constructor('],
  ),
  _Control(
    'static member made an instance member',
    _Verdict.golden,
    '+ MontyStackFrame.listFromJson: '
        'method(List<Object?> jsonList) -> List<MontyStackFrame>',
    {
      _frameFile: (s) => _replaceOnce(
        s,
        _frameAnchor,
        _frameAnchor.replaceFirst('static ', ''),
      ),
    },
  ),
  _Control(
    'final class made base',
    _Verdict.golden,
    '+ base class MontyLimits',
    {
      _limitsFile: (s) =>
          _replaceOnce(s, _limitsAnchor, 'base class MontyLimits {\n'),
    },
    alsoMentions: ['- final class MontyLimits'],
  ),
  _Control(
    'type parameter bound changed',
    _Verdict.golden,
    '+ MontyLimits.boundaryProbe: method<T extends int>(T value) -> T',
    {_limitsFile: _boundProbe('int')},
    base: {_limitsFile: _boundProbe('num')},
    alsoMentions: [
      '- MontyLimits.boundaryProbe: method<T extends num>(T value) -> T',
    ],
  ),
  _Control(
    'private member added (allowed)',
    _Verdict.pass,
    '',
    {
      _limitsFile: _insertAfter(
        _limitsAnchor,
        '  int get _boundaryProbe => 0;\n'
        '  int get boundaryProbeUse => _boundaryProbe;\n',
      ),
    },
    base: {
      _limitsFile: _insertAfter(
        _limitsAnchor,
        '  int get boundaryProbeUse => 0;\n',
      ),
    },
  ),
  _Control(
    'member of a private supertype inherited by a public class',
    _Verdict.golden,
    '+ _BoundaryProbeBase.inherited: getter -> int',
    {_limitsFile: _privateBase('  int get inherited => 0;\n')},
    base: {_limitsFile: _privateBase('')},
  ),
  _Control(
    'implicit setter removed',
    _Verdict.golden,
    '- MontyLimits.boundaryProbe: late final settable field int',
    {
      _limitsFile: _insertAfter(
        _limitsAnchor,
        '  late final int boundaryProbe = 0;\n',
      ),
    },
    base: {
      _limitsFile: _insertAfter(
        _limitsAnchor,
        '  late final int boundaryProbe;\n',
      ),
    },
    alsoMentions: ['+ MontyLimits.boundaryProbe: late final field int'],
  ),
  _Control(
    'parameter switched between two types of one name',
    _Verdict.golden,
    '+ boundaryTake: function(Item@src/boundary_probe_b.dart x) -> void',
    {..._sameNames, 'lib/boundary_probe_items.dart': (_) => _items('b')},
    base: {..._sameNames, 'lib/boundary_probe_items.dart': (_) => _items('a')},
  ),
  _Control(
    'extension type no longer implements Object',
    _Verdict.golden,
    '- extension type BoundaryProbe(int raw) implements Object',
    {
      'lib/boundary_probe_ext.dart': (_) =>
          'extension type BoundaryProbe(int raw) {}\n',
    },
    base: {
      'lib/boundary_probe_ext.dart': (_) =>
          'extension type BoundaryProbe(int raw) implements Object {}\n',
    },
  ),
  _Control(
    'parameter switched from a core type to a type parameter of its name',
    _Verdict.golden,
    '- BoundaryProbe.take: method(String@dart:core x) -> void',
    {'lib/boundary_probe_shadow.dart': (_) => _shadow('')},
    base: {'lib/boundary_probe_shadow.dart': (_) => _shadow('core.')},
    alsoMentions: ['+ BoundaryProbe.take: method(String x) -> void'],
  ),
  _Control(
    'parameter switched from Never to a type parameter of its name',
    _Verdict.golden,
    '- BoundaryProbe.take: method(Never@dart:core x) -> void',
    {'lib/boundary_probe_shadow.dart': (_) => _shadow('', type: 'Never')},
    base: {
      'lib/boundary_probe_shadow.dart': (_) => _shadow('core.', type: 'Never'),
    },
    alsoMentions: ['+ BoundaryProbe.take: method(Never x) -> void'],
  ),
  _Control(
    'public library re-exports the other of two same-named types',
    _Verdict.golden,
    '+ Item: src/boundary_probe_b.dart',
    {
      ..._sameNames,
      'lib/boundary_probe_items.dart': (_) => _items('a'),
      'lib/boundary_probe_reexport.dart': (_) =>
          "export 'src/boundary_probe_b.dart';\n",
    },
    base: {
      ..._sameNames,
      'lib/boundary_probe_items.dart': (_) => _items('a'),
      'lib/boundary_probe_reexport.dart': (_) =>
          "export 'src/boundary_probe_a.dart';\n",
    },
    alsoMentions: ['- Item: src/boundary_probe_a.dart'],
  ),
  _Control(
    'private subtype added to a sealed class',
    _Verdict.golden,
    '+ VfsNode: permits final class _BoundaryProbeNode extends VfsNode',
    {
      'lib/src/mount/vfs_node.dart': (s) =>
          '$s\nfinal class _BoundaryProbeNode extends VfsNode {}\n',
    },
  ),
  _Control(
    'private subtype of a sealed class stops implementing a public one',
    _Verdict.golden,
    '- VfsNode: permits final class _BoundaryProbeNode extends VfsNode '
        'implements VfsFile',
    {'lib/src/mount/vfs_node.dart': (s) => '$s${_hiddenNode('')}'},
    base: {
      'lib/src/mount/vfs_node.dart': (s) =>
          '$s${_hiddenNode(' implements VfsFile')}',
    },
  ),
  _Control(
    'private ancestor of a sealed subtype stops implementing a public type',
    _Verdict.golden,
    '- VfsNode: permits via abstract class _BoundaryProbeBase '
        'implements VfsFile',
    {'lib/src/mount/vfs_node.dart': (s) => '$s${_hiddenAncestor('')}'},
    base: {
      'lib/src/mount/vfs_node.dart': (s) =>
          '$s${_hiddenAncestor(' implements VfsFile')}',
    },
  ),
  _Control(
    'enum values reordered',
    _Verdict.golden,
    '+ MountMode.readWrite: static const enum value #0 MountMode',
    {
      'lib/src/mount/mount_mode.dart': (s) => _replaceOnce(
        _replaceOnce(s, '  readOnly,\n', ''),
        '  readWrite,\n',
        '  readWrite,\n  readOnly,\n',
      ),
    },
  ),
  _Control(
    'constant named by a default value changed',
    _Verdict.golden,
    'int? memoryUsageLimit = defaultMemoryUsageLimit (200000000)})',
    {
      'lib/src/mount/vfs_limits.dart': (s) => _replaceOnce(
        s,
        'defaultMemoryUsageLimit = 100000000;',
        'defaultMemoryUsageLimit = 200000000;',
      ),
    },
    alsoMentions: [
      '+ defaultMemoryUsageLimit: const variable int = 200000000',
    ],
  ),
  _Control(
    'conditional exports swap two same-named types between libraries',
    _Verdict.both,
    'boundary_c==true] $_differsFromDefault:   + Item: '
        'src/boundary_probe_b.dart',
    {
      ..._sameNames,
      'lib/boundary_probe_items.dart': (_) => _items('a'),
      'lib/boundary_probe_reexport.dart': (_) => _swapExport('a', 'b'),
      'lib/boundary_probe_reexport2.dart': (_) => _swapExport('b', 'a'),
    },
  ),
  _Control(
    'multi-line default value prints the same with CRLF line endings',
    _Verdict.pass,
    '',
    {
      'lib/boundary_probe_lines.dart': (_) =>
          _multiLine.replaceAll('\n', '\r\n'),
    },
    base: {'lib/boundary_probe_lines.dart': (_) => _multiLine},
  ),
  _Control(
    'multi-line default value round-trips through the golden',
    _Verdict.pass,
    '',
    {'lib/boundary_probe_lines.dart': (_) => _multiLine},
    base: {'lib/boundary_probe_lines.dart': (_) => _multiLine},
    section: (
      'members: boundary_probe_lines.dart',
      r"boundaryLines: function({String s = '''a\nb\\\\n'''}) -> void",
    ),
  ),
  _Control(
    'printer output for a fixture library',
    _Verdict.golden,
    '+ ProbeCallback',
    {'lib/boundary_probe_fixture.dart': (_) => _fixture},
    section: ('members: boundary_probe_fixture.dart', _fixturePrinted),
  ),
  _Control(
    'tool names the analyzer formatter',
    _Verdict.boundary,
    'names the analyzer formatter, getDisplayString at line',
    {},
    toolEdit: (s) => '$s\nString _probe(DartType t) => t.getDisplayString();\n',
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
  String committed,
  _Control control,
) async {
  final golden = switch (control.base) {
    null => committed,
    final base => _renderGolden(
      (await _analyzeBoundary(root, _overlay(root, base))).sections,
    ),
  };
  final report = await _analyzeBoundary(root, _overlay(root, control.edits));
  final source = _toolSource(root);
  _checkToolSource(control.toolEdit?.call(source) ?? source, report);
  final diff = _diffGolden(golden, report.sections);
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
  if (control.section case (final key, final expected)?) {
    final printed = (report.members[key] ?? const []).join('\n');
    if (printed != expected.trim()) {
      return 'section [$key] printed:\n$printed\nexpected:\n${expected.trim()}';
    }
  }
  for (final text in [control.mentions, ...control.alsoMentions]) {
    if (!output.contains(text)) {
      return 'output does not mention "$text":\n$output';
    }
  }

  return null;
}

/// The package as [edits] change it, in memory.
OverlayResourceProvider _overlay(
  String root,
  Map<String, String Function(String original)> edits,
) {
  final provider = OverlayResourceProvider(PhysicalResourceProvider.INSTANCE);
  for (final MapEntry(:key, :value) in edits.entries) {
    final file = File('$root/$key');
    final original = file.existsSync() ? file.readAsStringSync() : '';
    provider.setOverlay(
      file.path,
      content: value(original),
      modificationStamp: 0,
    );
  }

  return provider;
}

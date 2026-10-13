// The scoped helpers repeat the parameters of the calls they wrap:
// MontyPool.withPool those of start, withSession those of checkout. Read
// from the source with package:analyzer, so a parameter added, renamed,
// retyped or given another default on one side only fails here.
//
// VM only: package:analyzer reads files through dart:io.
@Tags(['unit', 'vm-only'])
@TestOn('vm')
library;

import 'dart:io';

import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:test/test.dart';

const _source = 'lib/src/worker/monty_pool.dart';

/// The difference a changed `scriptName` default on withSession reports.
const _scriptNameDiff =
    "scriptName: withSession (String, 'other.py'), "
    "checkout (String, 'main.py')";

/// Each named parameter of each method in [source]: name -> (type, default).
Map<String, Map<String, (String, String?)>> _namedParameters(String source) {
  final unit = parseString(
    content: source,
    featureSet: FeatureSet.latestLanguageVersion(),
  ).unit;
  final collector = _Methods();
  unit.accept(collector);

  return collector.methods;
}

final class _Methods extends RecursiveAstVisitor<void> {
  final Map<String, Map<String, (String, String?)>> methods = {};

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    methods[node.name.lexeme] = {
      for (final p in node.parameters?.parameters ?? <FormalParameter>[])
        if (p.isNamed) _name(p): (_type(p), _default(p)),
    };
  }
}

String _name(FormalParameter p) =>
    p.name?.lexeme ?? fail('a parameter without a name: ${p.toSource()}');

/// [p]'s declared type, marked when it is required.
String _type(FormalParameter p) =>
    '${p.isRequired ? 'required ' : ''}${p.type?.toSource() ?? 'dynamic'}';

String? _default(FormalParameter p) => p.defaultClause?.value.toSource();

/// Where the named parameters of [helper] and [wrapped] differ.
List<String> _differences(
  Map<String, Map<String, (String, String?)>> methods,
  String helper,
  String wrapped,
) {
  final h = methods[helper] ?? fail('no method $helper');
  final w = methods[wrapped] ?? fail('no method $wrapped');

  return [
    for (final name in {...h.keys, ...w.keys})
      if (h[name] != w[name]) '$name: $helper ${h[name]}, $wrapped ${w[name]}',
  ];
}

void main() {
  final source = File(_source).readAsStringSync();

  test("withPool takes exactly start's named parameters", () {
    final methods = _namedParameters(source);
    expect(methods['start'], hasLength(8));
    expect(_differences(methods, 'withPool', 'start'), isEmpty);
  });

  test("withSession takes exactly checkout's named parameters", () {
    final methods = _namedParameters(source);
    expect(methods['checkout'], hasLength(9));
    expect(_differences(methods, 'withSession', 'checkout'), isEmpty);
  });

  test('a default, a type or a parameter changed on one side is caught', () {
    // The check against copies of the real source, each broken one way.
    String once(String from, String to) {
      expect(from.allMatches(source), isNotEmpty, reason: from);

      return source.replaceFirst(from, to);
    }

    // withSession's copy of the default: the last one in the file.
    const from = "String scriptName = 'main.py',";
    final at = source.lastIndexOf(from);
    expect(at, greaterThan(source.indexOf(from)));
    final defaultChanged = source.replaceRange(
      at,
      at + from.length,
      "String scriptName = 'other.py',",
    );
    expect(
      _differences(
        _namedParameters(defaultChanged),
        'withSession',
        'checkout',
      ),
      [_scriptNameDiff],
    );
    final typeChanged = once('int? maxProcesses,', 'num? maxProcesses,');
    expect(
      _differences(_namedParameters(typeChanged), 'withPool', 'start'),
      hasLength(1),
    );
    final dropped = once(
      '    String? workerLocation,\n  }) async {',
      '  }) async {',
    );
    expect(
      _differences(_namedParameters(dropped), 'withPool', 'start'),
      ['workerLocation: withPool null, start (String?, null)'],
    );
  });
}

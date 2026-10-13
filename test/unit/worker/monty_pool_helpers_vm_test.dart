// The scoped helpers take the same settings as the calls they wrap:
// MontyPool.withPool those of start, withSession those of checkout (one
// internal options record each until the cutover decides the public
// signatures). Read from the source with package:analyzer, so a parameter
// added, renamed, retyped or given another default on one side only fails
// here.
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

/// The difference a retyped `options` on withPool reports.
const _retypedDiff =
    'options: withPool (Object, const PoolOptions()), '
    'start (PoolOptions, const PoolOptions())';

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
    expect(methods['start'], {
      'options': ('PoolOptions', 'const PoolOptions()'),
    });
    expect(_differences(methods, 'withPool', 'start'), isEmpty);
  });

  test("withSession takes exactly checkout's named parameters", () {
    final methods = _namedParameters(source);
    expect(methods['checkout'], {
      'options': ('SessionConfig', 'const SessionConfig()'),
    });
    expect(_differences(methods, 'withSession', 'checkout'), isEmpty);
  });

  test('a default, a type or a parameter changed on one side is caught', () {
    // The check against copies of the real source, each broken one way:
    // always the helper's copy, the last one in the file.
    String last(String from, String to) {
      final at = source.lastIndexOf(from);
      expect(at, greaterThan(source.indexOf(from)), reason: from);

      return source.replaceRange(at, at + from.length, to);
    }

    final defaultChanged = _namedParameters(
      last(
        'SessionConfig options = const SessionConfig()',
        "SessionConfig options = const SessionConfig(scriptName: 'x.py')",
      ),
    );
    expect(
      _differences(defaultChanged, 'withSession', 'checkout'),
      [contains("SessionConfig(scriptName: 'x.py')")],
    );
    final retyped = _namedParameters(
      last(
        'PoolOptions options = const PoolOptions()',
        'Object options = const PoolOptions()',
      ),
    );
    expect(_differences(retyped, 'withPool', 'start'), [_retypedDiff]);
    // withPool's signature is the only one ending in `}) async {`.
    const withPoolEnd =
        '    PoolOptions options = const PoolOptions(),\n  }) async {';
    expect(withPoolEnd.allMatches(source).length, 1);
    final extra = source.replaceFirst(
      withPoolEnd,
      '    PoolOptions options = const PoolOptions(),\n'
      '    int extra = 0,\n'
      '  }) async {',
    );
    expect(
      _differences(_namedParameters(extra), 'withPool', 'start'),
      ['extra: withPool (int, 0), start null'],
    );
  });
}

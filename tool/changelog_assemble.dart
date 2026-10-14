// Folds changes/*.md fragments into CHANGELOG.md, then deletes them.
//
// Run at tag or release time, in its own PR (label `changelog-assembly`):
//
//   dart tool/changelog_assemble.dart                  # into ## Unreleased
//   dart tool/changelog_assemble.dart --version 0.24.0 # into a new ## 0.24.0
//   dart tool/changelog_assemble.dart --dry-run        # print, change nothing
//
// A fragment is `### <Section>` followed by entries (see changes/README.md).
// Entries are appended at the end of the matching `### <Section>` of the target
// release section, in fragment filename order; a missing section is created in
// the conventional order. With --version the current `## Unreleased` content
// moves under the new `## <version>` header and an empty `## Unreleased`
// stays above it.
//
// Pure dart:io, no package deps: `dart tool/changelog_assemble.dart`.
// `--self-test` runs the folding on in-memory text.
import 'dart:io';

const sectionOrder = [
  'Breaking',
  'Added',
  'Changed',
  'Deprecated',
  'Removed',
  'Fixed',
  'Security',
  'Internal',
];

final _header = RegExp(r'^### (\S.*?)\s*$');

/// Parses fragment text into section name -> entry text.
Map<String, String> parseFragment(String name, String text) {
  final out = <String, StringBuffer>{};
  StringBuffer? cur;
  var fence = false;
  for (final line in text.split('\n')) {
    final t = line.trimLeft();
    if (t.startsWith('```') || t.startsWith('~~~')) {
      fence = !fence;
    } else if (fence && line.startsWith('### ')) {
      throw FormatException('$name: "### " line inside a code fence');
    }
    final m = _header.firstMatch(line);
    if (m != null) {
      final s = m.group(1)!;
      if (!sectionOrder.contains(s)) {
        throw FormatException('$name: unknown section "$s"');
      }
      cur = out.putIfAbsent(s, StringBuffer.new);
    } else if (line.startsWith('## ') || line.startsWith('# ')) {
      throw FormatException('$name: release-level heading in a fragment');
    } else if (cur != null) {
      cur.writeln(line);
    } else if (line.trim().isNotEmpty) {
      throw FormatException('$name: text before the first ### header');
    }
  }
  final res = <String, String>{};
  for (final e in out.entries) {
    final body = e.value.toString().trim();
    if (body.isEmpty) throw FormatException('$name: empty "${e.key}" section');
    res[e.key] = body;
  }
  if (res.isEmpty) throw FormatException('$name: no sections');
  return res;
}

/// Folds [entries] (section -> list of entry blocks) into the body lines of one
/// release section (the lines after its `## ` header, up to the next one).
List<String> foldIntoSection(
  List<String> body,
  Map<String, List<String>> entries,
) {
  var lines = List<String>.from(body);
  for (final section in sectionOrder) {
    final add = entries[section];
    if (add == null) continue;
    final text = add.join('\n\n').split('\n');
    final idx = lines.indexWhere((l) => l == '### $section');
    if (idx >= 0) {
      var end = lines.indexWhere((l) => l.startsWith('### '), idx + 1);
      if (end < 0) {
        end = lines.length;
      }
      while (end > idx + 1 && lines[end - 1].trim().isEmpty) {
        end--;
      }
      lines.insertAll(end, ['', ...text]);
    } else {
      // Insert before the first existing section that sorts later.
      final myRank = sectionOrder.indexOf(section);
      var at = lines.length;
      for (var i = 0; i < lines.length; i++) {
        final m = _header.firstMatch(lines[i]);
        if (m != null) {
          final r = sectionOrder.indexOf(m.group(1)!);
          if (r > myRank) {
            at = i;
            break;
          }
        }
      }
      final block = ['### $section', '', ...text, ''];
      if (at == lines.length) {
        while (lines.isNotEmpty && lines.last.trim().isEmpty) {
          lines.removeLast();
        }
        lines = [...lines, '', ...block];
      } else {
        lines.insertAll(at, block);
      }
    }
  }
  return lines;
}

/// Returns the new CHANGELOG text.
String assemble(
  String changelog,
  Map<String, List<String>> entries, {
  String? version,
  String date = '',
}) {
  final lines = changelog.split('\n');
  final uIdx = lines.indexWhere((l) => l.trim() == '## Unreleased');
  if (uIdx < 0) {
    throw const FormatException('CHANGELOG.md has no ## Unreleased');
  }
  var uEnd = lines.indexWhere((l) => l.startsWith('## '), uIdx + 1);
  if (uEnd < 0) {
    uEnd = lines.length;
  }
  final body = lines.sublist(uIdx + 1, uEnd);
  final head = lines.sublist(0, uIdx + 1);
  final tail = lines.sublist(uEnd);
  while (body.isNotEmpty && body.last.trim().isEmpty) {
    body.removeLast();
  }
  if (version == null) {
    final folded = foldIntoSection(body, entries);
    return [...head, ...folded, '', ...tail].join('\n');
  }
  final folded = foldIntoSection(body, entries);
  final title = date.isEmpty ? '## $version' : '## $version - $date';
  return [...head, '', title, ...folded, '', ...tail].join('\n');
}

Never _fail(String m) {
  stderr.writeln('FAIL: $m');
  exit(1);
}

void _selfTest() {
  const base =
      '# Changelog\n\n## Unreleased\n\n### Added\n\n- old\n\n'
      '### Fixed\n\n- oldfix\n\n## 1.0.0\n\n### Added\n\n- ancient\n';
  final e = <String, List<String>>{
    'Added': ['- new'],
    'Changed': ['- chg'],
    'Breaking': ['- brk'],
  };
  final out = assemble(base, e);
  void need(String what, {required bool ok}) {
    if (!ok) {
      _fail('self-test: $what\n$out');
    }
  }

  need('Added appended', ok: out.contains('- old\n\n- new\n'));
  need(
    'Breaking before Added',
    ok: out.indexOf('### Breaking') < out.indexOf('### Added'),
  );
  need(
    'Changed before Fixed',
    ok: out.indexOf('### Changed') < out.indexOf('### Fixed'),
  );
  need(
    'older release untouched',
    ok: out.indexOf('- ancient') > out.indexOf('## 1.0.0'),
  );
  final v = assemble(base, e, version: '2.0.0', date: '2026-01-01');
  need(
    'version header, empty Unreleased above',
    ok: v.contains('## Unreleased\n\n## 2.0.0 - 2026-01-01\n\n'),
  );
  var threw = false;
  try {
    parseFragment('x.md', 'no header');
  } on FormatException {
    threw = true;
  }
  if (!threw) _fail('self-test: unheadered fragment accepted');
  stdout.writeln('self-test passed');
}

void main(List<String> args) {
  if (args.contains('--self-test')) {
    _selfTest();
    return;
  }
  String? version;
  var dry = false;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--dry-run') {
      dry = true;
    } else if (args[i] == '--version' && i + 1 < args.length) {
      version = args[++i];
    } else {
      _fail('usage: changelog_assemble.dart [--version X.Y.Z] [--dry-run]');
    }
  }
  final dir = Directory('changes');
  final files = dir.existsSync()
      ? (dir
            .listSync()
            .whereType<File>()
            .where(
              (f) =>
                  f.path.endsWith('.md') &&
                  f.uri.pathSegments.last != 'README.md',
            )
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path)))
      : <File>[];
  if (files.isEmpty) _fail('no fragments in changes/');
  final entries = <String, List<String>>{};
  for (final f in files) {
    try {
      parseFragment(
        f.path,
        f.readAsStringSync(),
      ).forEach((s, t) => entries.putIfAbsent(s, () => []).add(t));
    } on FormatException catch (e) {
      _fail(e.message);
    }
  }
  final cl = File('CHANGELOG.md');
  final now = DateTime.now().toUtc().toIso8601String().substring(0, 10);
  String out;
  try {
    out = assemble(
      cl.readAsStringSync(),
      entries,
      version: version,
      date: version == null ? '' : now,
    );
  } on FormatException catch (e) {
    _fail(e.message);
  }
  if (dry) {
    stdout.write(out);
    return;
  }
  cl.writeAsStringSync(out);
  for (final f in files) {
    f.deleteSync();
  }
  stdout.writeln('folded ${files.length} fragment(s) into CHANGELOG.md');
}

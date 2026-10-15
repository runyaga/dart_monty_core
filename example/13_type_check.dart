// Examples print what they show; the number in the name is the reading order.
// ignore_for_file: avoid_print, file_names
//
// 13 — Type checking
//
// A session checked out with typeCheck: true type-checks each snippet
// before running it. A snippet the check rejects throws MontyTypingError
// and does not run; the session survives. The check sees what earlier
// snippets defined, and typeCheckStubs declares names the host provides
// (inputs, external functions) so the checker knows their types.
//
// Covers: withSession(typeCheck:, typeCheckStubs:, typeCheckFormat:),
//         MontyTypingError, skipTypeCheck.
//
// Run: dart run example/13_type_check.dart

import 'package:dart_monty_core/dart_monty_core.dart';

Future<void> main() async {
  await Monty.withPool((monty) async {
    await monty.withSession(_checked, typeCheck: true);
    await monty.withSession(
      _stubs,
      typeCheck: true,
      typeCheckStubs: 'def fetch_price(sku: str) -> float: ...',
      typeCheckFormat: 'concise',
    );
  });
}

Future<void> _checked(MontySession session) async {
  // ── Clean code runs ─────────────────────────────────────────────────────
  print('\n── clean code ──');
  final ok = await session.feedRun('x: int = 1\ny: int = x + 1\ny');
  print('y = $ok');
  _check(ok == const MontyInt(2), 'clean code');

  // ── A mismatch is rejected before anything runs ───────────────────────────
  print('\n── annotated mistake ──');
  final error = await _typingError(session, 'x = 99\nz: str = x');
  print(error);
  // The rejected snippet did not run: x is still 1.
  _check(await session.feedRun('x') == const MontyInt(1), 'did not run');

  // ── Inference without annotations ─────────────────────────────────────────
  print('\n── inference ──');
  print(await _typingError(session, 'w = "anything"\nv = w + 1'));

  // ── skipTypeCheck runs one snippet unchecked ──────────────────────────────
  print('\n── skipTypeCheck ──');
  try {
    await session.feedRun('w = "anything"\nv = w + 1', skipTypeCheck: true);
    throw StateError('the unchecked snippet did not raise');
  } on MontyRuntimeError catch (e) {
    print('ran, and raised at run time: $e');
    _check(e.exception.excType == 'TypeError', 'runtime TypeError');
  }
}

Future<void> _stubs(MontySession session) async {
  // ── typeCheckStubs declares host-provided names ───────────────────────────
  print('\n── typeCheckStubs ──');
  final externals = {
    'fetch_price': (List<MontyValue> args, Map<String, MontyValue> _) =>
        const MontyFloat(9.5),
  };
  final total = await session.feedRun(
    'total: float = fetch_price("A1") * 2\ntotal',
    externals: externals,
  );
  print('total = $total');
  _check(total == const MontyFloat(19), 'stubbed call');

  // The stub's types catch a wrong argument, here in the concise format.
  final error = await _typingError(session, 'fetch_price(42)');
  print(error);
}

Future<MontyTypingError> _typingError(MontySession session, String code) async {
  try {
    await session.feedRun(code);
  } on MontyTypingError catch (e) {
    return e;
  }
  throw StateError('the type check accepted: $code');
}

void _check(bool ok, String what) {
  if (!ok) throw StateError('unexpected result: $what');
}

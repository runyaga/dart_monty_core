/// The one rule for rendering a finite `double` as text that still reads as a
/// float.
library;

/// Renders a finite [v] so that the text still says "float".
///
/// **`'$v'` is not enough, and this is the fourth place that has bitten.** On
/// dart2js `int` and `double` are one runtime type, so `'${4.0}'` is `"4"` —
/// the int/float collapse of core#128, reappearing in Dart's own rendering
/// rather than on the wire. dart2wasm has real doubles and never sees it.
///
/// The three earlier sites were the repr differential's renderer, the wire-text
/// helper in `monty_value_scalars.dart`, and the web demo's formatter (fixed in
/// `b1a8b71` after being found by eye on the deployed page, not by a test).
/// `inputs_encoder.dart` was the fourth, where it was worse than cosmetic: it
/// rendered a `double` input into Python source as `x = 4`, so the sandbox
/// received an **`int`** on the web and a **`float`** on the VM for the same
/// call.
///
/// Non-finite values are deliberately NOT handled here. `NaN` and the
/// infinities have no single spelling that is correct everywhere — Python
/// source wants `float('nan')`, the wire envelope wants `"NaN"`, and the demo
/// wants `nan` — so each caller must decide before reaching this function.
/// Passing one in is a caller bug rather than something to guess about.
String exactDoubleText(double v) {
  assert(v.isFinite, 'exactDoubleText is for finite doubles; got $v');

  // `-0.0` renders as `-0` on dart2js and would lose the sign the `.0` rule
  // below cannot restore, so it is spelled out.
  if (v == 0 && v.isNegative) return '-0.0';

  final text = '$v';
  // An exponent form (`1e+21`) already reads as a float in every consumer, so
  // only the bare-integer rendering needs the point appended.
  if (!text.contains('.') && !text.contains('e')) return '$text.0';

  return text;
}

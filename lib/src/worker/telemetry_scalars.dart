/// Scalar representations used by upstream's OpenTelemetry attributes.
library;

final BigInt _exactJsInteger = BigInt.one << 53;

/// Preserves signed attribute integers without rounding or saturation.
Object telemetryInteger(BigInt value) {
  // D-103: dart2js records integers beyond ±2^53 as exact decimal strings.
  // Unlike dart2wasm and the VM, dart2js shares int's storage with double.
  if (identical(0, 0.0) && value.abs() > _exactJsInteger) return '$value';

  return value.isValidInt ? value.toInt() : value;
}

/// Upstream OtelValue Display: shortest decimal, no exponent or trailing .0.
/// Nonfinite arena floats already arrive as Python's nan/inf/-inf strings.
String telemetryScalarText(Object value) {
  if (value is! double) return '$value';
  if (value.isNaN) return 'nan';
  if (!value.isFinite) return value.isNegative ? '-inf' : 'inf';
  if (value == 0) return value.isNegative ? '-0' : '0';
  final text = value.toString();
  final exponentAt = text.indexOf('e');
  if (exponentAt < 0) {
    return text.endsWith('.0') ? text.substring(0, text.length - 2) : text;
  }

  return _expandDecimal(text, exponentAt, negative: value.isNegative);
}

String _expandDecimal(String text, int exponentAt, {required bool negative}) {
  final sign = negative ? '-' : '';
  final mantissa = text.substring(sign.length, exponentAt);
  final exponent = int.parse(text.substring(exponentAt + 1));
  final dot = mantissa.indexOf('.');
  final digits = mantissa.replaceAll('.', '');
  final point = (dot < 0 ? mantissa.length : dot) + exponent;
  if (point <= 0) return '${sign}0.${'0' * -point}$digits';
  if (point >= digits.length) {
    return '$sign$digits${'0' * (point - digits.length)}';
  }

  return '$sign${digits.substring(0, point)}.${digits.substring(point)}';
}

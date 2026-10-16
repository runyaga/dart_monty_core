part of 'telemetry_values.dart';

String _bytesContent(List<int> bytes) {
  final quote = bytes.contains(39) && !bytes.contains(34) ? 34 : 39;
  final text = StringBuffer();
  for (final byte in bytes) {
    text.write(switch (byte) {
      92 => r'\\',
      9 => r'\t',
      10 => r'\n',
      13 => r'\r',
      _ when byte == quote => '\\${String.fromCharCode(byte)}',
      >= 32 && <= 126 => String.fromCharCode(byte),
      _ => '\\x${byte.toRadixString(16).padLeft(2, '0')}',
    });
  }

  return text.toString();
}

String _complex(pb.Complex value) {
  final real = bitsToDouble(value.real);
  final imag = bitsToDouble(value.imag);
  final imaginary = _floatRepr(imag).replaceFirst(RegExp(r'\.0$'), '');
  if (real == 0 && !real.isNegative) return '${imaginary}j';
  final realText = _floatRepr(real).replaceFirst(RegExp(r'\.0$'), '');
  final sign = imaginary.startsWith('-') ? '' : '+';

  return '($realText$sign${imaginary}j)';
}

String _floatRepr(double value) {
  if (!value.isFinite) return _finite(value) as String;
  final scientific = value.abs().toStringAsExponential();
  final parts = scientific.split('e');
  final exponent = int.parse(parts.lastOrNull ?? '0');
  if (exponent < -4 || exponent >= 16) {
    final negative = value.isNegative ? '-' : '';
    final mantissa = parts.firstOrNull ?? '';

    return '$negative${mantissa.replaceFirst(RegExp(r'\.0$'), '')}'
        'e${exponent < 0 ? '-' : '+'}${_pad(exponent.abs())}';
  }

  return exactDoubleText(value);
}

String _timezone(pb.TimeZone value) {
  final offset = value.offsetSeconds;
  if (offset == 0 && !value.hasName()) return 'datetime.timezone.utc';
  final days = offset < 0 ? (offset - 86399) ~/ 86400 : offset ~/ 86400;
  final seconds = offset % 86400;
  final parts = [
    if (days != 0) 'days=$days',
    if (seconds != 0) 'seconds=$seconds',
  ];
  final delta = parts.isEmpty ? '0' : parts.join(', ');

  return 'datetime.timezone(datetime.timedelta($delta)'
      '${value.hasName() ? ', ${pythonRepr(value.name)}' : ''})';
}

String _file(pb.FileHandle file) {
  final mode = parseFileMode(file.mode).canonical ?? file.mode;
  final type = _fileType(mode);

  return '<_io.$type name=${pythonRepr(file.path)} mode=${pythonRepr(mode)}>';
}

// serde_json 1.0.151 / zmij 1.0.23: fixed notation for exponents -5..15,
// no exponent zero padding, and an explicit plus for positive exponents.
String _serdeFloat(double value) {
  final scientific = value.toStringAsExponential();
  final parts = scientific.split('e');
  final exponent = int.parse(parts.lastOrNull ?? '0');
  if (exponent >= -5 && exponent <= 15) return exactDoubleText(value);
  final mantissa = (parts.firstOrNull ?? '').replaceFirst(RegExp(r'\.0$'), '');

  return '${mantissa}e${exponent < 0 ? '' : '+'}$exponent';
}

String _fileType(String mode) {
  if (!mode.contains('b')) return 'TextIOWrapper';
  if (mode.contains('+')) return 'BufferedRandom';

  return mode.startsWith('r') ? 'BufferedReader' : 'BufferedWriter';
}

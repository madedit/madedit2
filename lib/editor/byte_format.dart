/// Formatting of raw bytes into source-code and hex-string text.
///
/// Pure Dart so it can be tested headless (tool/byte_format_test.dart).
library;

/// Largest byte range the copy-bytes dialog will format. Turning a whole GB
/// file into text would allocate a multi-GB string for no benefit.
const int copyBytesMaxBytes = 16 << 20;

const String _hexDigits = '0123456789ABCDEF';

/// Bytes as a C initializer list: `0x00, 0x0A, ...`, [perLine] entries per
/// line, comma separated, no trailing comma. Uppercase hex digits.
String bytesToCArray(List<int> bytes, {int perLine = 16}) {
  if (bytes.isEmpty) return '';
  final per = perLine < 1 ? 1 : perLine;
  final sb = StringBuffer();
  for (var i = 0; i < bytes.length; i++) {
    if (i == 0) {
      // first entry: no separator
    } else if (i % per == 0) {
      sb.write('\n');
    } else {
      sb.write(', ');
    }
    final b = bytes[i] & 0xFF;
    sb.write('0x');
    sb.write(_hexDigits[b >> 4]);
    sb.write(_hexDigits[b & 0xF]);
  }
  return sb.toString();
}

/// Bytes as a hex string, [separator] between bytes (default a single space):
/// `00 A1 FF`. Uppercase hex digits.
String bytesToHexString(List<int> bytes, {String separator = ' '}) {
  final sb = StringBuffer();
  for (var i = 0; i < bytes.length; i++) {
    if (i > 0) sb.write(separator);
    final b = bytes[i] & 0xFF;
    sb.write(_hexDigits[b >> 4]);
    sb.write(_hexDigits[b & 0xF]);
  }
  return sb.toString();
}

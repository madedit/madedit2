import 'dart:convert';

import 'package:crypto/crypto.dart';

/// A checksum computed over a byte range.
class ChecksumResult {
  const ChecksumResult({required this.algorithm, required this.hex});

  final String algorithm;
  final String hex;

  int get byteLength => hex.length ~/ 2;
}

/// Algorithms shown in the checksum dialog.
const List<String> checksumAlgorithms = [
  'MD5',
  'SHA-1',
  'SHA-224',
  'SHA-256',
  'SHA-384',
  'SHA-512',
  'SHA-512/224',
  'SHA-512/256',
];

/// Hashes [bytes] with [algorithm], or null when the name is unsupported.
ChecksumResult? computeChecksum(String algorithm, List<int> bytes) {
  final hash = _hashFor(algorithm);
  if (hash == null) return null;
  return ChecksumResult(
    algorithm: algorithm,
    hex: hash.convert(bytes).toString(),
  );
}

/// Streaming sink for one algorithm. Call [add] with document-sized chunks
/// and [close] once; [close] returns the result.
class ChecksumAccumulator {
  ChecksumAccumulator(String algorithm) {
    final hash = _hashFor(algorithm);
    if (hash == null) throw ArgumentError('unsupported checksum: $algorithm');
    this.algorithm = algorithm;
    _digest = _DigestSink();
    _sink = hash.startChunkedConversion(_digest);
  }

  late final String algorithm;
  late final ByteConversionSink _sink;
  late final _DigestSink _digest;
  bool _closed = false;

  void add(List<int> chunk) {
    if (_closed) throw StateError('checksum accumulator is closed');
    _sink.add(chunk);
  }

  ChecksumResult close() {
    if (_closed) throw StateError('checksum accumulator is closed');
    _closed = true;
    _sink.close();
    return ChecksumResult(algorithm: algorithm, hex: _digest.digest.toString());
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? digest;

  @override
  void add(Digest data) => digest = data;

  @override
  void close() {}
}

/// Hex digest for [bytes], throwing when [algorithm] is unsupported.
String checksumHex(String algorithm, List<int> bytes) {
  final result = computeChecksum(algorithm, bytes);
  if (result == null) throw ArgumentError('unsupported checksum: $algorithm');
  return result.hex;
}

/// Hex digest for the UTF-8 bytes of [text].
String utf8Checksum(String algorithm, String text) =>
    checksumHex(algorithm, utf8.encode(text));

/// Human-readable byte size, e.g. `1.5 MB`. Uses binary units.
String formatByteSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  double v = bytes / 1024;
  const units = ['KB', 'MB', 'GB', 'TB', 'PB'];
  var unit = 0;
  while (v >= 1024 && unit < units.length - 1) {
    v /= 1024;
    unit++;
  }
  final text = v >= 100
      ? v.toStringAsFixed(0)
      : v >= 10
      ? v.toStringAsFixed(1)
      : v.toStringAsFixed(2);
  return '$text ${units[unit]}';
}

Hash? _hashFor(String algorithm) => switch (algorithm) {
  'MD5' => md5,
  'SHA-1' => sha1,
  'SHA-224' => sha224,
  'SHA-256' => sha256,
  'SHA-384' => sha384,
  'SHA-512' => sha512,
  'SHA-512/224' => sha512224,
  'SHA-512/256' => sha512256,
  _ => null,
};

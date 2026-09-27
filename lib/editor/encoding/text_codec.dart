// Text encoding layer (foundation).
//
// The document model stays byte-based end to end; a TextCodec is applied
// only at the boundaries:
//   - read boundary:  bytes -> String (text / hex views)
//   - write boundary: String -> bytes (keyboard / paste input)
// Switching the encoding of an open file is pure reinterpretation: no
// document byte changes. Pure Dart (no flutter, no IO) so everything here is
// headless-testable via tool/encoding_test.dart.

import 'dart:typed_data';

/// Result of decoding a byte range with a [TextCodec].
///
/// [byteOffsets] has one entry per UTF-16 code unit of [text]:
/// `byteOffsets[i]` is the offset (relative to the start of the decoded byte
/// range) of the FIRST byte of the character that produced code unit `i`.
/// All code units of a multi-byte character map back to the same first byte,
/// so byte -> code unit and code unit -> byte are both derivable (needed by
/// caret positioning, hit-testing and highlight span mapping).
class DecodedText {
  final String text;
  final Uint32List byteOffsets;

  /// Total bytes consumed (== input length).
  final int byteLength;

  const DecodedText(this.text, this.byteOffsets, this.byteLength);

  /// First byte offset of the character containing code unit [cu];
  /// [byteLength] when [cu] is at (or past) the end of [text].
  int byteForCodeUnit(int cu) =>
      cu >= byteOffsets.length ? byteLength : byteOffsets[cu];

  /// Index of the FIRST code unit of the character covering [byte];
  /// `text.length` when [byte] is at (or past) the end of the range.
  int codeUnitForByte(int byte) {
    if (byte >= byteLength) return byteOffsets.length;
    var lo = 0, hi = byteOffsets.length - 1, ans = 0;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (byteOffsets[mid] <= byte) {
        ans = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    // Step back to the first code unit sharing the same start byte
    // (surrogate pairs produce two code units with equal offsets).
    while (ans > 0 && byteOffsets[ans - 1] == byteOffsets[ans]) {
      ans--;
    }
    return ans;
  }
}

/// Result of encoding text with a [TextCodec].
class EncodedText {
  final Uint8List bytes;

  /// Number of characters the codec could not represent; each was written
  /// out as literal "U+XXXX" code point notation instead.
  final int fallbackCount;

  const EncodedText(this.bytes, this.fallbackCount);
}

/// Value of the code unit starting at byte [i] of [b] (the caller guarantees
/// `i + unit <= b.length` and that [i] is unit-aligned). This is what the
/// newline scanners compare against 0x0A: for UTF-16/32 a raw 0x0A byte scan
/// would also hit the low byte of characters like U+010A, so line structure
/// must be found per unit, not per byte.
int unitValueAt(List<int> b, int i, int unit, bool littleEndian) {
  if (unit == 1) return b[i];
  if (unit == 2) {
    return littleEndian ? b[i] | (b[i + 1] << 8) : (b[i] << 8) | b[i + 1];
  }
  return littleEndian
      ? b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24)
      : (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];
}

/// Byte length of the first character in [d] (0 when empty). Used for
/// caret-right stepping: the caret always sits on a character boundary, so
/// decoding a few bytes at it measures the next character for any codec.
int firstCharBytes(DecodedText d) {
  if (d.byteOffsets.isEmpty) return 0;
  for (var i = 1; i < d.byteOffsets.length; i++) {
    if (d.byteOffsets[i] != 0) return d.byteOffsets[i];
  }
  return d.byteLength;
}

/// "U+XXXX" notation (uppercase hex, at least 4 digits) written into the
/// document when a codec cannot represent a character — e.g. an emoji typed
/// into a Big5 file becomes the ASCII text "U+1F600". One-way by design.
String codePointNotation(int codePoint) =>
    'U+${codePoint.toRadixString(16).toUpperCase().padLeft(4, '0')}';

/// A text encoding. Stateless and byte-addressable: decoding may start at
/// any character boundary with no carried state (which is why stateful
/// encodings like ISO-2022-JP are excluded by design).
abstract class TextCodec {
  const TextCodec();

  /// Canonical display name, e.g. "UTF-8", "UTF-16 LE", "Big5".
  String get name;

  /// Code unit size in bytes: 1 (single-byte and ASCII-compatible DBCS),
  /// 2 (UTF-16), 4 (UTF-32).
  int get unitSize;

  /// Byte order of a code unit; meaningless (and true) when [unitSize] == 1.
  bool get littleEndian => true;

  /// True when scanning raw bytes for 0x0A finds exactly the newlines
  /// (single-byte codepages, UTF-8, and the supported DBCS families whose
  /// trail bytes never include 0x0A). UTF-16/32 are false and need
  /// unit-aware line scanning instead.
  bool get newlineByteScanSafe => unitSize == 1;

  DecodedText decode(Uint8List bytes);

  bool canEncode(int codePoint);

  /// Encode [text]; characters that cannot be represented are written as
  /// literal "U+XXXX" notation and counted in [EncodedText.fallbackCount].
  EncodedText encode(String text);
}

/// Base for codecs that encode one code point at a time; implements the
/// shared "U+XXXX" fallback policy on top of [encodeCodePoint].
abstract class RuneCodec extends TextCodec {
  const RuneCodec();

  /// Append the encoding of [codePoint] to [out]; return false when the
  /// codec cannot represent it (the caller then writes U+XXXX notation).
  bool encodeCodePoint(int codePoint, BytesBuilder out);

  @override
  bool canEncode(int codePoint) => encodeCodePoint(codePoint, BytesBuilder());

  @override
  EncodedText encode(String text) {
    final out = BytesBuilder();
    var fallback = 0;
    for (var r in text.runes) {
      if (r >= 0xD800 && r <= 0xDFFF) r = 0xFFFD; // lone surrogate
      if (!encodeCodePoint(r, out)) {
        fallback++;
        for (final c in codePointNotation(r).codeUnits) {
          encodeCodePoint(c, out); // ASCII, representable in every codec
        }
      }
    }
    return EncodedText(out.takeBytes(), fallback);
  }
}

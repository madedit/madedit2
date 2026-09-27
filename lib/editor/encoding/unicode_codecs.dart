// Unicode codecs: UTF-8, UTF-16 LE/BE, UTF-32 LE/BE.
//
// All decoders are strict: malformed sequences become U+FFFD (one per
// offending byte for UTF-8, one per unit for UTF-16/32) so that byte offsets
// stay consistent and nothing is silently skipped.

import 'dart:typed_data';

import 'text_codec.dart';

class Utf8TextCodec extends RuneCodec {
  const Utf8TextCodec();

  @override
  String get name => 'UTF-8';

  @override
  int get unitSize => 1;

  @override
  DecodedText decode(Uint8List b) {
    final text = StringBuffer();
    final offs = <int>[];
    final n = b.length;
    var i = 0;
    while (i < n) {
      final start = i;
      final b0 = b[i];
      var cp = -1;
      if (b0 < 0x80) {
        cp = b0;
        i++;
      } else if (b0 >= 0xC2 && b0 <= 0xDF) {
        if (i + 1 < n && (b[i + 1] & 0xC0) == 0x80) {
          cp = ((b0 & 0x1F) << 6) | (b[i + 1] & 0x3F);
          i += 2;
        }
      } else if (b0 >= 0xE0 && b0 <= 0xEF) {
        // E0 requires A0..BF as first trail (no overlong), ED requires
        // 80..9F (no surrogates).
        final lo1 = b0 == 0xE0 ? 0xA0 : 0x80;
        final hi1 = b0 == 0xED ? 0x9F : 0xBF;
        if (i + 2 < n &&
            b[i + 1] >= lo1 &&
            b[i + 1] <= hi1 &&
            (b[i + 2] & 0xC0) == 0x80) {
          cp = ((b0 & 0x0F) << 12) | ((b[i + 1] & 0x3F) << 6) | (b[i + 2] & 0x3F);
          i += 3;
        }
      } else if (b0 >= 0xF0 && b0 <= 0xF4) {
        // F0 requires 90..BF (no overlong), F4 requires 80..8F (<= U+10FFFF).
        final lo1 = b0 == 0xF0 ? 0x90 : 0x80;
        final hi1 = b0 == 0xF4 ? 0x8F : 0xBF;
        if (i + 3 < n &&
            b[i + 1] >= lo1 &&
            b[i + 1] <= hi1 &&
            (b[i + 2] & 0xC0) == 0x80 &&
            (b[i + 3] & 0xC0) == 0x80) {
          cp = ((b0 & 0x07) << 18) |
              ((b[i + 1] & 0x3F) << 12) |
              ((b[i + 2] & 0x3F) << 6) |
              (b[i + 3] & 0x3F);
          i += 4;
        }
      }
      if (cp < 0) {
        cp = 0xFFFD;
        i = start + 1;
      }
      if (cp > 0xFFFF) {
        offs
          ..add(start)
          ..add(start);
        text
          ..writeCharCode(0xD800 + ((cp - 0x10000) >> 10))
          ..writeCharCode(0xDC00 + ((cp - 0x10000) & 0x3FF));
      } else {
        offs.add(start);
        text.writeCharCode(cp);
      }
    }
    return DecodedText(text.toString(), Uint32List.fromList(offs), n);
  }

  @override
  bool encodeCodePoint(int cp, BytesBuilder out) {
    if (cp < 0x80) {
      out.addByte(cp);
    } else if (cp < 0x800) {
      out
        ..addByte(0xC0 | (cp >> 6))
        ..addByte(0x80 | (cp & 0x3F));
    } else if (cp < 0x10000) {
      out
        ..addByte(0xE0 | (cp >> 12))
        ..addByte(0x80 | ((cp >> 6) & 0x3F))
        ..addByte(0x80 | (cp & 0x3F));
    } else {
      out
        ..addByte(0xF0 | (cp >> 18))
        ..addByte(0x80 | ((cp >> 12) & 0x3F))
        ..addByte(0x80 | ((cp >> 6) & 0x3F))
        ..addByte(0x80 | (cp & 0x3F));
    }
    return true;
  }
}

class Utf16TextCodec extends RuneCodec {
  @override
  final bool littleEndian;

  const Utf16TextCodec({required this.littleEndian});

  @override
  String get name => littleEndian ? 'UTF-16 LE' : 'UTF-16 BE';

  @override
  int get unitSize => 2;

  int _unit(Uint8List b, int i) =>
      littleEndian ? b[i] | (b[i + 1] << 8) : (b[i] << 8) | b[i + 1];

  @override
  DecodedText decode(Uint8List b) {
    final text = StringBuffer();
    final offs = <int>[];
    final n = b.length;
    var i = 0;
    while (i + 1 < n) {
      final u = _unit(b, i);
      if (u >= 0xD800 && u <= 0xDBFF && i + 3 < n) {
        final u2 = _unit(b, i + 2);
        if (u2 >= 0xDC00 && u2 <= 0xDFFF) {
          // Both code units of the pair map to the pair's FIRST byte, as the
          // DecodedText contract says and as UTF-8/UTF-32 do. Mapping the
          // low surrogate to i+2 made charLeft() land mid-pair, so Backspace
          // after an emoji deleted half of it (an unpaired surrogate on disk).
          offs
            ..add(i)
            ..add(i);
          text
            ..writeCharCode(u)
            ..writeCharCode(u2);
          i += 4;
          continue;
        }
      }
      offs.add(i);
      text.writeCharCode(u >= 0xD800 && u <= 0xDFFF ? 0xFFFD : u);
      i += 2;
    }
    if (i < n) {
      // Stray trailing byte (odd-length range).
      offs.add(i);
      text.writeCharCode(0xFFFD);
    }
    return DecodedText(text.toString(), Uint32List.fromList(offs), n);
  }

  void _writeUnit(int u, BytesBuilder out) {
    if (littleEndian) {
      out
        ..addByte(u & 0xFF)
        ..addByte(u >> 8);
    } else {
      out
        ..addByte(u >> 8)
        ..addByte(u & 0xFF);
    }
  }

  @override
  bool encodeCodePoint(int cp, BytesBuilder out) {
    if (cp <= 0xFFFF) {
      _writeUnit(cp, out);
    } else {
      _writeUnit(0xD800 + ((cp - 0x10000) >> 10), out);
      _writeUnit(0xDC00 + ((cp - 0x10000) & 0x3FF), out);
    }
    return true;
  }
}

class Utf32TextCodec extends RuneCodec {
  @override
  final bool littleEndian;

  const Utf32TextCodec({required this.littleEndian});

  @override
  String get name => littleEndian ? 'UTF-32 LE' : 'UTF-32 BE';

  @override
  int get unitSize => 4;

  @override
  DecodedText decode(Uint8List b) {
    final text = StringBuffer();
    final offs = <int>[];
    final n = b.length;
    var i = 0;
    while (i + 3 < n) {
      final cp = littleEndian
          ? b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24)
          : (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];
      final valid = cp >= 0 && cp <= 0x10FFFF && !(cp >= 0xD800 && cp <= 0xDFFF);
      if (!valid) {
        offs.add(i);
        text.writeCharCode(0xFFFD);
      } else if (cp > 0xFFFF) {
        offs
          ..add(i)
          ..add(i);
        text
          ..writeCharCode(0xD800 + ((cp - 0x10000) >> 10))
          ..writeCharCode(0xDC00 + ((cp - 0x10000) & 0x3FF));
      } else {
        offs.add(i);
        text.writeCharCode(cp);
      }
      i += 4;
    }
    if (i < n) {
      // 1-3 stray trailing bytes become a single U+FFFD.
      offs.add(i);
      text.writeCharCode(0xFFFD);
    }
    return DecodedText(text.toString(), Uint32List.fromList(offs), n);
  }

  @override
  bool encodeCodePoint(int cp, BytesBuilder out) {
    if (littleEndian) {
      out
        ..addByte(cp & 0xFF)
        ..addByte((cp >> 8) & 0xFF)
        ..addByte((cp >> 16) & 0xFF)
        ..addByte((cp >> 24) & 0xFF);
    } else {
      out
        ..addByte((cp >> 24) & 0xFF)
        ..addByte((cp >> 16) & 0xFF)
        ..addByte((cp >> 8) & 0xFF)
        ..addByte(cp & 0xFF);
    }
    return true;
  }
}

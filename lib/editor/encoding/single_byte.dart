// Generic single-byte codec (family A: ISO-8859-x, Windows-125x, KOI8,
// DOS codepages...). One 256-entry table per codepage; tables for the full
// list are generated from the WHATWG encoding indexes in a later step.
// Latin-1 (identity mapping) is built in.

import 'dart:typed_data';

import 'text_codec.dart';

class SingleByteCodec extends RuneCodec {
  @override
  final String name;

  /// byte -> code point; 0xFFFD marks "undefined in this codepage".
  final Uint16List _toUnicode;

  Map<int, int>? _fromUnicode; // built lazily on first encode

  SingleByteCodec(this.name, Uint16List toUnicode)
      : assert(toUnicode.length == 256),
        _toUnicode = toUnicode;

  @override
  int get unitSize => 1;

  @override
  DecodedText decode(Uint8List b) {
    final n = b.length;
    final units = Uint16List(n);
    final offs = Uint32List(n);
    for (var i = 0; i < n; i++) {
      units[i] = _toUnicode[b[i]];
      offs[i] = i;
    }
    return DecodedText(String.fromCharCodes(units), offs, n);
  }

  Map<int, int> get _reverse {
    var map = _fromUnicode;
    if (map == null) {
      map = <int, int>{};
      // Reverse iteration so that when two bytes map to the same code point
      // the LOWER byte wins (matters for duplicated entries in some tables).
      for (var i = 255; i >= 0; i--) {
        final u = _toUnicode[i];
        if (u != 0xFFFD) map[u] = i;
      }
      _fromUnicode = map;
    }
    return map;
  }

  @override
  bool encodeCodePoint(int cp, BytesBuilder out) {
    final b = _reverse[cp];
    if (b == null) return false;
    out.addByte(b);
    return true;
  }
}

/// Builds a codec from the generated table format: [high] holds the 128
/// characters for bytes 0x80..0xFF (BMP only), bytes 0x00..0x7F are ASCII.
SingleByteCodec singleByteFromHigh(String name, String high) {
  assert(high.codeUnits.length == 128);
  final t = Uint16List(256);
  for (var i = 0; i < 128; i++) {
    t[i] = i;
    t[128 + i] = high.codeUnitAt(i);
  }
  return SingleByteCodec(name, t);
}

/// Latin-1 (ISO-8859-1): byte value == code point.
final SingleByteCodec latin1TextCodec = SingleByteCodec(
  'Latin-1 (ISO-8859-1)',
  Uint16List.fromList(List<int>.generate(256, (i) => i)),
);

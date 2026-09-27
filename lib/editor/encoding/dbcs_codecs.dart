// DBCS codecs (family B: ASCII-compatible multi-byte): Big5, GBK/GB18030,
// Shift-JIS, EUC-JP, EUC-KR. Decode/encode algorithms follow the WHATWG
// Encoding Standard; the pointer tables are generated from its indexes
// (tables/*.dart). Trail bytes in all of these never include 0x0A, so the
// byte-anchor line navigation works unchanged (newlineByteScanSafe = true).

import 'dart:typed_data';

import 'tables/big5_data.dart';
import 'tables/euc_kr_data.dart';
import 'tables/gb18030_data.dart';
import 'tables/jis0208_data.dart';
import 'tables/jis0212_data.dart';
import 'text_codec.dart';

Uint32List _expand(String data) {
  final out = <int>[];
  for (final r in data.runes) {
    out.add(r);
  }
  return Uint32List.fromList(out);
}

/// pointer -> code point table with a lazily built reverse map.
class _Index {
  final Uint32List cps;

  /// Encoder-side pointer restrictions per the WHATWG spec.
  final int reverseFrom;
  final int reverseExcludeFrom, reverseExcludeTo; // inclusive; -1 = none
  final Set<int> lastWins; // code points whose LAST pointer wins

  Map<int, int>? _reverse;

  _Index(String data,
      {this.reverseFrom = 0,
      this.reverseExcludeFrom = -1,
      this.reverseExcludeTo = -1,
      this.lastWins = const {}})
      : cps = _expand(data);

  int cpAt(int pointer) =>
      pointer >= 0 && pointer < cps.length ? cps[pointer] : 0xFFFD;

  Map<int, int> get reverse {
    var m = _reverse;
    if (m == null) {
      m = <int, int>{};
      for (var p = reverseFrom; p < cps.length; p++) {
        if (p >= reverseExcludeFrom && p <= reverseExcludeTo) continue;
        final cp = cps[p];
        if (cp == 0xFFFD) continue;
        if (!m.containsKey(cp)) {
          m[cp] = p;
        } else if (lastWins.contains(cp)) {
          m[cp] = p;
        }
      }
      _reverse = m;
    }
    return m;
  }
}

/// Accumulates decoded text plus the per-code-unit start byte offsets.
class _Sink {
  final _sb = StringBuffer();
  final _offs = <int>[];

  void add(int cp, int start) {
    if (cp > 0xFFFF) {
      _offs
        ..add(start)
        ..add(start);
      _sb
        ..writeCharCode(0xD800 + ((cp - 0x10000) >> 10))
        ..writeCharCode(0xDC00 + ((cp - 0x10000) & 0x3FF));
    } else {
      _offs.add(start);
      _sb.writeCharCode(cp);
    }
  }

  DecodedText done(int byteLength) =>
      DecodedText(_sb.toString(), Uint32List.fromList(_offs), byteLength);
}

// ── Big5 ─────────────────────────────────────────────────────────────────

class Big5TextCodec extends RuneCodec {
  // Encoder skips the HKSCS region (pointers below (0xA1-0x81)*157) and for
  // six duplicated code points uses the last pointer, per the WHATWG spec.
  static final _Index _index = _Index(big5Data,
      reverseFrom: (0xA1 - 0x81) * 157,
      lastWins: const {0x2550, 0x255E, 0x2561, 0x256A, 0x5341, 0x5345});

  @override
  String get name => 'Big5';

  @override
  int get unitSize => 1;

  @override
  DecodedText decode(Uint8List b) {
    final s = _Sink();
    final n = b.length;
    var i = 0;
    while (i < n) {
      final b0 = b[i];
      if (b0 < 0x80) {
        s.add(b0, i);
        i++;
        continue;
      }
      var consumed = 0;
      if (b0 >= 0x81 && b0 <= 0xFE && i + 1 < n) {
        final t = b[i + 1];
        if ((t >= 0x40 && t <= 0x7E) || (t >= 0xA1 && t <= 0xFE)) {
          final p = (b0 - 0x81) * 157 + (t < 0x7F ? t - 0x40 : t - 0x62);
          // Four pointers decode to two-code-point sequences (spec prose).
          const pairs = {
            1133: [0x00CA, 0x0304],
            1135: [0x00CA, 0x030C],
            1164: [0x00EA, 0x0304],
            1166: [0x00EA, 0x030C],
          };
          final pair = pairs[p];
          if (pair != null) {
            s
              ..add(pair[0], i)
              ..add(pair[1], i);
            consumed = 2;
          } else {
            final cp = _index.cpAt(p);
            if (cp != 0xFFFD) {
              s.add(cp, i);
              consumed = 2;
            }
          }
        }
      }
      if (consumed == 0) {
        s.add(0xFFFD, i);
        consumed = 1; // resync on the next byte
      }
      i += consumed;
    }
    return s.done(n);
  }

  @override
  bool encodeCodePoint(int cp, BytesBuilder out) {
    if (cp < 0x80) {
      out.addByte(cp);
      return true;
    }
    final p = _index.reverse[cp];
    if (p == null) return false;
    final t = p % 157;
    out
      ..addByte(p ~/ 157 + 0x81)
      ..addByte(t < 0x3F ? t + 0x40 : t + 0x62);
    return true;
  }
}

// ── GBK / GB18030 ────────────────────────────────────────────────────────

class Gb18030TextCodec extends RuneCodec {
  /// False = GBK (two-byte only); true = GB18030 (adds four-byte sequences,
  /// which cover all of Unicode).
  final bool fourByte;

  static final _Index _index = _Index(gb18030Data);

  const Gb18030TextCodec({required this.fourByte});

  @override
  String get name => fourByte ? 'GB18030' : 'GBK';

  @override
  int get unitSize => 1;

  static int? _rangesCp(int pointer) {
    if (pointer == 7457) return 0xE7C7;
    if ((pointer > 39419 && pointer < 189000) || pointer > 1237575) return null;
    var lo = 0, hi = gb18030Ranges.length ~/ 2 - 1, ans = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (gb18030Ranges[mid * 2] <= pointer) {
        ans = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    if (ans < 0) return null;
    return gb18030Ranges[ans * 2 + 1] + (pointer - gb18030Ranges[ans * 2]);
  }

  static int _rangesPointer(int cp) {
    if (cp == 0xE7C7) return 7457;
    var lo = 0, hi = gb18030Ranges.length ~/ 2 - 1, ans = 0;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (gb18030Ranges[mid * 2 + 1] <= cp) {
        ans = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return gb18030Ranges[ans * 2] + (cp - gb18030Ranges[ans * 2 + 1]);
  }

  @override
  DecodedText decode(Uint8List b) {
    final s = _Sink();
    final n = b.length;
    var i = 0;
    while (i < n) {
      final b0 = b[i];
      if (b0 < 0x80) {
        s.add(b0, i);
        i++;
        continue;
      }
      var consumed = 0;
      if (b0 >= 0x81 && b0 <= 0xFE && i + 1 < n) {
        final t = b[i + 1];
        if (fourByte &&
            t >= 0x30 &&
            t <= 0x39 &&
            i + 3 < n &&
            b[i + 2] >= 0x81 &&
            b[i + 2] <= 0xFE &&
            b[i + 3] >= 0x30 &&
            b[i + 3] <= 0x39) {
          final p = (b0 - 0x81) * 12600 +
              (t - 0x30) * 1260 +
              (b[i + 2] - 0x81) * 10 +
              (b[i + 3] - 0x30);
          final cp = _rangesCp(p);
          if (cp != null) {
            s.add(cp, i);
            consumed = 4;
          }
        } else if (t >= 0x40 && t <= 0xFE && t != 0x7F) {
          final p = (b0 - 0x81) * 190 + (t < 0x7F ? t - 0x40 : t - 0x41);
          final cp = _index.cpAt(p);
          if (cp != 0xFFFD) {
            s.add(cp, i);
            consumed = 2;
          }
        }
      }
      if (consumed == 0) {
        s.add(0xFFFD, i);
        consumed = 1;
      }
      i += consumed;
    }
    return s.done(n);
  }

  @override
  bool encodeCodePoint(int cp, BytesBuilder out) {
    if (cp < 0x80) {
      out.addByte(cp);
      return true;
    }
    final p = _index.reverse[cp];
    if (p != null) {
      final t = p % 190;
      out
        ..addByte(p ~/ 190 + 0x81)
        ..addByte(t < 0x3F ? t + 0x40 : t + 0x41);
      return true;
    }
    if (!fourByte || (cp >= 0xD800 && cp <= 0xDFFF)) return false;
    final q = _rangesPointer(cp);
    out
      ..addByte(q ~/ 12600 + 0x81)
      ..addByte(q % 12600 ~/ 1260 + 0x30)
      ..addByte(q % 1260 ~/ 10 + 0x81)
      ..addByte(q % 10 + 0x30);
    return true;
  }
}

// ── Shift-JIS ────────────────────────────────────────────────────────────

class ShiftJisTextCodec extends RuneCodec {
  // Encoder excludes pointers 8272..8835 (NEC/IBM duplicates) per the spec.
  static final _Index _index =
      _Index(jis0208Data, reverseExcludeFrom: 8272, reverseExcludeTo: 8835);

  @override
  String get name => 'Shift-JIS';

  @override
  int get unitSize => 1;

  @override
  DecodedText decode(Uint8List b) {
    final s = _Sink();
    final n = b.length;
    var i = 0;
    while (i < n) {
      final b0 = b[i];
      if (b0 <= 0x80) {
        s.add(b0, i); // 0x00..0x7F ASCII; 0x80 maps to U+0080 per spec
        i++;
        continue;
      }
      if (b0 >= 0xA1 && b0 <= 0xDF) {
        s.add(0xFF61 + b0 - 0xA1, i); // halfwidth katakana
        i++;
        continue;
      }
      var consumed = 0;
      final isLead = (b0 >= 0x81 && b0 <= 0x9F) || (b0 >= 0xE0 && b0 <= 0xFC);
      if (isLead && i + 1 < n) {
        final t = b[i + 1];
        if (t >= 0x40 && t <= 0xFC && t != 0x7F) {
          final p = (b0 < 0xA0 ? b0 - 0x81 : b0 - 0xC1) * 188 +
              (t < 0x7F ? t - 0x40 : t - 0x41);
          final cp = p >= 8836 && p <= 10715
              ? 0xE000 + p - 8836 // private-use extension area
              : _index.cpAt(p);
          if (cp != 0xFFFD) {
            s.add(cp, i);
            consumed = 2;
          }
        }
      }
      if (consumed == 0) {
        s.add(0xFFFD, i);
        consumed = 1;
      }
      i += consumed;
    }
    return s.done(n);
  }

  @override
  bool encodeCodePoint(int cp, BytesBuilder out) {
    if (cp <= 0x80) {
      out.addByte(cp);
      return true;
    }
    if (cp == 0x00A5) {
      out.addByte(0x5C); // yen sign
      return true;
    }
    if (cp == 0x203E) {
      out.addByte(0x7E); // overline
      return true;
    }
    if (cp >= 0xFF61 && cp <= 0xFF9F) {
      out.addByte(cp - 0xFF61 + 0xA1);
      return true;
    }
    int? p;
    if (cp >= 0xE000 && cp <= 0xE757) {
      p = 8836 + cp - 0xE000;
    } else {
      p = _index.reverse[cp];
    }
    if (p == null) return false;
    final l = p ~/ 188, t = p % 188;
    out
      ..addByte(l < 0x1F ? l + 0x81 : l + 0xC1)
      ..addByte(t < 0x3F ? t + 0x40 : t + 0x41);
    return true;
  }
}

// ── EUC-JP ───────────────────────────────────────────────────────────────

class EucJpTextCodec extends RuneCodec {
  static final _Index _index0208 = _Index(jis0208Data);
  static final _Index _index0212 = _Index(jis0212Data); // decode-only

  @override
  String get name => 'EUC-JP';

  @override
  int get unitSize => 1;

  @override
  DecodedText decode(Uint8List b) {
    final s = _Sink();
    final n = b.length;
    var i = 0;
    while (i < n) {
      final b0 = b[i];
      if (b0 < 0x80) {
        s.add(b0, i);
        i++;
        continue;
      }
      var consumed = 0;
      if (b0 == 0x8E && i + 1 < n && b[i + 1] >= 0xA1 && b[i + 1] <= 0xDF) {
        s.add(0xFF61 + b[i + 1] - 0xA1, i); // halfwidth katakana
        consumed = 2;
      } else if (b0 == 0x8F &&
          i + 2 < n &&
          b[i + 1] >= 0xA1 &&
          b[i + 1] <= 0xFE &&
          b[i + 2] >= 0xA1 &&
          b[i + 2] <= 0xFE) {
        final cp =
            _index0212.cpAt((b[i + 1] - 0xA1) * 94 + (b[i + 2] - 0xA1));
        if (cp != 0xFFFD) {
          s.add(cp, i);
          consumed = 3;
        }
      } else if (b0 >= 0xA1 &&
          b0 <= 0xFE &&
          i + 1 < n &&
          b[i + 1] >= 0xA1 &&
          b[i + 1] <= 0xFE) {
        final cp = _index0208.cpAt((b0 - 0xA1) * 94 + (b[i + 1] - 0xA1));
        if (cp != 0xFFFD) {
          s.add(cp, i);
          consumed = 2;
        }
      }
      if (consumed == 0) {
        s.add(0xFFFD, i);
        consumed = 1;
      }
      i += consumed;
    }
    return s.done(n);
  }

  @override
  bool encodeCodePoint(int cp, BytesBuilder out) {
    if (cp < 0x80) {
      out.addByte(cp);
      return true;
    }
    if (cp == 0x00A5) {
      out.addByte(0x5C);
      return true;
    }
    if (cp == 0x203E) {
      out.addByte(0x7E);
      return true;
    }
    if (cp >= 0xFF61 && cp <= 0xFF9F) {
      out
        ..addByte(0x8E)
        ..addByte(cp - 0xFF61 + 0xA1);
      return true;
    }
    final p = _index0208.reverse[cp]; // jis0212 is decode-only per spec
    if (p == null) return false;
    out
      ..addByte(p ~/ 94 + 0xA1)
      ..addByte(p % 94 + 0xA1);
    return true;
  }
}

// ── EUC-KR ───────────────────────────────────────────────────────────────

class EucKrTextCodec extends RuneCodec {
  static final _Index _index = _Index(eucKrData);

  @override
  String get name => 'EUC-KR';

  @override
  int get unitSize => 1;

  @override
  DecodedText decode(Uint8List b) {
    final s = _Sink();
    final n = b.length;
    var i = 0;
    while (i < n) {
      final b0 = b[i];
      if (b0 < 0x80) {
        s.add(b0, i);
        i++;
        continue;
      }
      var consumed = 0;
      if (b0 >= 0x81 &&
          b0 <= 0xFE &&
          i + 1 < n &&
          b[i + 1] >= 0x41 &&
          b[i + 1] <= 0xFE) {
        final cp = _index.cpAt((b0 - 0x81) * 190 + (b[i + 1] - 0x41));
        if (cp != 0xFFFD) {
          s.add(cp, i);
          consumed = 2;
        }
      }
      if (consumed == 0) {
        s.add(0xFFFD, i);
        consumed = 1;
      }
      i += consumed;
    }
    return s.done(n);
  }

  @override
  bool encodeCodePoint(int cp, BytesBuilder out) {
    if (cp < 0x80) {
      out.addByte(cp);
      return true;
    }
    final p = _index.reverse[cp];
    if (p == null) return false;
    out
      ..addByte(p ~/ 190 + 0x81)
      ..addByte(p % 190 + 0x41);
    return true;
  }
}

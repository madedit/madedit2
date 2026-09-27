// Codec registry: every available codec in menu order.

import 'dbcs_codecs.dart';
import 'single_byte.dart';
import 'tables/single_byte_data.dart';
import 'text_codec.dart';
import 'unicode_codecs.dart';

export 'dbcs_codecs.dart';
export 'single_byte.dart';
export 'text_codec.dart';
export 'unicode_codecs.dart';

const utf8TextCodec = Utf8TextCodec();
const utf16LeTextCodec = Utf16TextCodec(littleEndian: true);
const utf16BeTextCodec = Utf16TextCodec(littleEndian: false);
const utf32LeTextCodec = Utf32TextCodec(littleEndian: true);
const utf32BeTextCodec = Utf32TextCodec(littleEndian: false);
const gbkTextCodec = Gb18030TextCodec(fourByte: false);
const gb18030TextCodec = Gb18030TextCodec(fourByte: true);

/// All registered codecs, in the order the encoding menu lists them:
/// Unicode family, CJK (DBCS), then the single-byte codepages.
final List<TextCodec> allTextCodecs = [
  utf8TextCodec,
  utf16LeTextCodec,
  utf16BeTextCodec,
  utf32LeTextCodec,
  utf32BeTextCodec,
  Big5TextCodec(),
  gbkTextCodec,
  gb18030TextCodec,
  ShiftJisTextCodec(),
  EucJpTextCodec(),
  EucKrTextCodec(),
  latin1TextCodec,
  for (final d in singleByteTableDefs) singleByteFromHigh(d.name, d.high),
];

/// Lookup by canonical [TextCodec.name] (exact match); null when unknown.
TextCodec? textCodecByName(String name) {
  for (final c in allTextCodecs) {
    if (c.name == name) return c;
  }
  return null;
}

/// Menu grouping: (group key, codecs). Keys are stable identifiers the shell
/// localizes as `enc_group_<key>` (this layer stays flutter-free).
final List<(String, List<TextCodec>)> textCodecMenuGroups = [
  ('unicode', allTextCodecs.sublist(0, 5)),
  ('cjk', allTextCodecs.sublist(5, 11)),
  ('singleByte', allTextCodecs.sublist(11)),
];

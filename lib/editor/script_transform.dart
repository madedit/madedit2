// Line-streaming text transform over a Document (the user-scripting core).
//
// Walks the byte range [start, end) window by window (bounded memory, so a
// GB-scale file works), hands each window's complete lines to [transform]
// (which runs the user script), and splices back every line the transform
// changed. Edits are applied within a batch from the highest offset down, so
// earlier offsets stay valid; the continuation position and the range limit
// are then shifted by the batch's net byte delta.
//
// Line semantics match the editor core: '\n' terminates a line, an
// immediately preceding '\r' belongs to the terminator; the transform sees
// content only (no terminator) and its output has newlines normalized to the
// file's style. A single line longer than [chunkBytes] is passed through
// untouched (and counted) — transforming it would mean unbounded memory.
//
// Byte positions always come from the decode map ([DecodedText.byteForCodeUnit]),
// never from re-encoding, which drifts on U+FFFD / decode-only code points.
//
// Pure Dart, no flutter imports (headless-testable with a fake transform).

import 'dart:math';

import 'document.dart';
import 'search.dart' show searchChunk;

/// Outcome of one [applyLineTransform] run. [reverses] is in application
/// order — push `ReverseEdit.group(reverses.reversed.toList())` for one-step
/// undo (the caller owns the undo stack).
class LineTransformResult {
  LineTransformResult({
    required this.reverses,
    required this.changedLines,
    required this.scannedLines,
    required this.skippedLong,
    required this.fallbackCount,
    this.error,
  });

  final List<ReverseEdit> reverses;
  final int changedLines;
  final int scannedLines;

  /// Lines longer than the window that were passed through untouched.
  final int skippedLong;

  /// Characters the codec could not encode (written as literal "U+XXXX").
  final int fallbackCount;

  /// Non-null when [transform] threw: the run stopped there, but [reverses]
  /// still covers the batches already spliced — the caller must push them
  /// onto its undo stack even on error, or those edits become un-undoable.
  final String? error;
}

/// Run [transform] over every line of [doc] in `[start, end)` and splice the
/// changed lines back. [start] must be a line start; [end] must be a line
/// start or the document end (null = document end). [newline] is the file's
/// newline style ('\n' or '\r\n'); newlines in transform output are
/// normalized to it. [transform] receives a window's worth of consecutive
/// lines plus the 1-based ordinal of the first one (within the processed
/// range) and must return the same number of lines.
Future<LineTransformResult> applyLineTransform(
  Document doc,
  Future<List<String?>> Function(List<String> lines, int firstLineNo)
  transform, {
  int start = 0,
  int? end,
  String newline = '\n',
  int chunkBytes = searchChunk,
}) async {
  var limit = end ?? doc.length;
  var pos = start;
  var lineNo = 1;
  final reverses = <ReverseEdit>[];
  var changed = 0, scanned = 0, skippedLong = 0, fallbacks = 0;
  String? error;

  while (pos < limit) {
    // ── Collect one window's complete lines (content byte ranges). ──
    final readLen = min(chunkBytes, limit - pos);
    final d = await doc.readRangeDecoded(pos, readLen);
    final text = d.text;
    final lines = <String>[];
    // Per line: content start / content end / end of its terminator (== the
    // content end for an unterminated final line) — the last one is what a
    // deletion removes.
    final starts = <int>[], ends = <int>[], termEnds = <int>[];
    var i = 0;
    while (true) {
      final nl = text.indexOf('\n', i);
      if (nl < 0) break;
      var ce = nl;
      if (ce > i && text.codeUnitAt(ce - 1) == 0x0D) ce--; // CRLF terminator
      lines.add(text.substring(i, ce));
      starts.add(pos + d.byteForCodeUnit(i));
      ends.add(pos + d.byteForCodeUnit(ce));
      termEnds.add(pos + d.byteForCodeUnit(nl + 1));
      i = nl + 1;
    }
    int nextPos;
    var skippedHere = 0;
    if (pos + readLen >= limit) {
      // Window reaches the range end: the tail (if any) is the final,
      // unterminated line ([end] is a line boundary, so a non-empty tail
      // only happens at the document end).
      if (i < text.length) {
        lines.add(text.substring(i));
        starts.add(pos + d.byteForCodeUnit(i));
        ends.add(pos + readLen);
        termEnds.add(pos + readLen); // no terminator to delete
      }
      nextPos = limit;
    } else if (i > 0) {
      // Incomplete tail line: re-anchor the next window at its start (this
      // also re-reads a CRLF or multi-byte character cut by the window edge).
      nextPos = pos + d.byteForCodeUnit(i);
    } else {
      // No newline in the whole window → one line longer than the window.
      // Pass it through untouched; only locate its end to move past it.
      skippedHere = 1;
      nextPos = await _nextLineStart(doc, pos, limit, chunkBytes);
    }

    // ── Transform this batch and splice changed lines, highest offset first. ──
    if (lines.isNotEmpty) {
      final List<String?> out; // null entry = delete that line
      try {
        out = await transform(List.unmodifiable(lines), lineNo);
        if (out.length != lines.length) {
          throw StateError(
            'transform returned ${out.length} lines for ${lines.length}',
          );
        }
      } catch (e) {
        // Stop here but keep the batches already applied: the caller must
        // still get their reverses for the undo stack.
        error = e.toString();
        break;
      }
      var delta = 0;
      for (var k = lines.length - 1; k >= 0; k--) {
        final o = out[k];
        if (o == null) {
          // Delete the line: content plus its terminator (an unterminated
          // final line just loses its content).
          final s = starts[k], len = termEnds[k] - s;
          if (len > 0) reverses.add(await doc.delete(s, len));
          changed++;
          delta -= len;
          continue;
        }
        if (o == lines[k]) continue;
        final enc = doc.codec.encode(_normalizeNewlines(o, newline));
        fallbacks += enc.fallbackCount;
        final s = starts[k], len = ends[k] - s;
        if (len > 0) reverses.add(await doc.delete(s, len));
        if (enc.bytes.isNotEmpty) {
          reverses.add(await doc.insertBytes(s, enc.bytes));
        }
        changed++;
        delta += enc.bytes.length - len;
      }
      // All edits sit before the continuation point and the range end.
      nextPos += delta;
      limit += delta;
    }
    scanned += lines.length + skippedHere;
    skippedLong += skippedHere;
    lineNo += lines.length + skippedHere;
    pos = nextPos;
  }

  return LineTransformResult(
    reverses: reverses,
    changedLines: changed,
    scannedLines: scanned,
    skippedLong: skippedLong,
    fallbackCount: fallbacks,
    error: error,
  );
}

// CRLF → LF first so a lone '\n' from the script and a full '\r\n' both end
// up as [newline]; no-op for LF files.
String _normalizeNewlines(String s, String newline) {
  if (!s.contains('\n') && !s.contains('\r')) return s;
  final lf = s.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  return newline == '\n' ? lf : lf.replaceAll('\n', newline);
}

// Byte offset just past the next '\n' at/after [pos] (or [limit] when none),
// scanning decoded windows. [pos] is character-aligned; windows advance by
// whole bytes, which keeps unit codecs aligned (chunk is a multiple of 4) and
// cannot make family-B codecs hallucinate a newline (no trail byte is 0x0A).
Future<int> _nextLineStart(
  Document doc,
  int pos,
  int limit,
  int chunkBytes,
) async {
  var scan = pos;
  while (scan < limit) {
    final readLen = min(chunkBytes, limit - scan);
    final d = await doc.readRangeDecoded(scan, readLen);
    final nl = d.text.indexOf('\n');
    if (nl >= 0) return scan + d.byteForCodeUnit(nl + 1);
    scan += readLen;
  }
  return limit;
}

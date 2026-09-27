// Mapping a document offset back into the coordinates of a stale window.
//
// The editor paints from a window of lines read asynchronously; between an
// edit and the frame where the re-read window lands, the caret has already
// moved in NEW coordinates while the painted text is still the OLD one. A
// caret one past the old line end resolved to the next row's start, so
// typing at a line end flashed the caret at the start of the line below for
// a frame (blink timer / IME setState) before the reload snapped it back.
// Mapping the offset through the inverse of the splices since the window
// was read paints it where the old text says it is. Pure Dart.

/// [offset] (current document coordinates) expressed in the coordinates of
/// a window read before [splices] were applied. Each splice is
/// `(offset, delta)`: delta > 0 = that many bytes inserted at offset,
/// delta < 0 = that many bytes removed there. Oldest splice first.
int offsetBeforeSplices(int offset, List<(int, int)> splices) {
  var c = offset;
  for (var i = splices.length - 1; i >= 0; i--) {
    final (at, delta) = splices[i];
    if (delta > 0) {
      if (c >= at + delta) {
        c -= delta;
      } else if (c > at) {
        c = at; // inside the inserted text: the insertion point
      }
    } else if (c >= at) {
      c -= delta; // at/after a deletion: past the removed bytes
    }
  }
  return c;
}

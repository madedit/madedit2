// madedit2 user script (Tools menu). A script is one settings/scripts/<name>.js
// file defining a global function:
//
//   transformLine(line, lineNo)
//     line   : one line of text, without its newline terminator
//     lineNo : 1-based ordinal of the line within the processed range
//     return : the new line text; null/undefined leaves the line unchanged.
//              A returned '\n' inserts extra lines (normalized to the file's
//              newline style).
//
// Scripts run sandboxed (no file/network access) with a time limit per chunk.
// With a selection, only the lines it covers are processed; otherwise the
// whole file streams through, so GB-scale files work too (single lines longer
// than 1 MB are passed through untouched).
//
// This example uppercases the first word of every line.
function transformLine(line, lineNo) {
  return line.replace(/^(\s*)(\w+)/, (m, ws, w) => ws + w.toUpperCase());
}

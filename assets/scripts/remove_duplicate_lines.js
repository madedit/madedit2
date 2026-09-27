// madedit2 user script (Tools menu): removes every repeated line, keeping
// the first occurrence. Streams with the line contract, so it works on files
// of any length; the set of lines seen so far is the only thing held in
// memory (a file with millions of distinct lines will hit the script memory
// limit and stop with an error rather than exhaust the machine).
//
// Shows the run hooks: beginTransform() runs once before the first line and
// endTransform() once after the last, and script globals persist for the
// whole run, so `seen` carries across the ~1 MB chunks the file is fed in.
//
// See api.md next to this file for the full contract.

var seen = null;

function beginTransform() {
  seen = new Set();
}

function transformLine(line, lineNo) {
  if (seen.has(line)) return false; // false = delete this line
  seen.add(line);
  return null; // null = keep the line as it is
}

function endTransform() {
  seen = null; // release the set as soon as the run is over
}

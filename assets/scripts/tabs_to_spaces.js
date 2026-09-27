// Built-in madedit2 script: expand tabs to spaces, column-aware. A tab
// advances to the NEXT tab stop, it is not a fixed run of spaces (a tab at
// column 3 with TAB = 4 expands to a single space). Columns count every
// character as 1 (the usual tab-expansion convention, CJK included).
// See api.md in this folder for the scripting contract.
const TAB = 4; // tab stop width; edit to taste, then reload scripts
function transformLine(line) {
  if (!line.includes("\t")) return null;
  let out = "";
  let col = 0;
  for (const ch of line) {
    if (ch === "\t") {
      const n = TAB - (col % TAB);
      out += " ".repeat(n);
      col += n;
    } else {
      out += ch;
      col++;
    }
  }
  return out;
}

// Built-in madedit2 script: convert leading-indentation spaces to tabs.
// Only the indentation is touched; spaces inside the line (alignment,
// string literals) are deliberately left alone, which makes this safe to
// run on source code. Every TAB spaces become one tab; a remainder smaller
// than TAB stays as spaces. An indentation that already mixes tabs is
// normalized by column.
// See api.md in this folder for the scripting contract.
const TAB = 4; // tab stop width; edit to taste, then reload scripts
function transformLine(line) {
  const m = line.match(/^[ \t]+/);
  if (!m) return null;
  // Measure the indentation in columns (tabs advance to the next stop).
  let col = 0;
  for (const ch of m[0]) {
    col += ch === "\t" ? TAB - (col % TAB) : 1;
  }
  const indent = "\t".repeat(Math.floor(col / TAB)) + " ".repeat(col % TAB);
  if (indent === m[0]) return null;
  return indent + line.slice(m[0].length);
}

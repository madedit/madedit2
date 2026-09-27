// Built-in madedit2 script: uppercase every line (or the selected lines).
// Unicode-aware (accented letters, Greek, Cyrillic, ... all convert).
// See api.md in this folder for the scripting contract.
function transformLine(line) {
  const t = line.toUpperCase();
  return t === line ? null : t; // null = unchanged (skips the edit)
}

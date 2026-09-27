// Built-in madedit2 script: halfwidth ASCII -> fullwidth.
// U+0021..U+007E (! A 5 ...) map to U+FF01..U+FF5E (offset 0xFEE0);
// a regular space becomes the ideographic space U+3000.
// See api.md in this folder for the scripting contract.
function transformLine(line) {
  let out = "";
  for (const ch of line) {
    const c = ch.codePointAt(0);
    if (c >= 0x21 && c <= 0x7e) out += String.fromCodePoint(c + 0xfee0);
    else if (c === 0x20) out += "　";
    else out += ch;
  }
  return out === line ? null : out;
}

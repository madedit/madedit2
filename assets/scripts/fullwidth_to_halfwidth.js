// Built-in madedit2 script: fullwidth ASCII -> halfwidth.
// U+FF01..U+FF5E (！ Ａ ５ ...) map to U+0021..U+007E (offset 0xFEE0);
// the ideographic space U+3000 becomes a regular space. CJK text and
// everything else is left alone.
// See api.md in this folder for the scripting contract.
function transformLine(line) {
  let out = "";
  for (const ch of line) {
    const c = ch.codePointAt(0);
    if (c >= 0xff01 && c <= 0xff5e) out += String.fromCodePoint(c - 0xfee0);
    else if (c === 0x3000) out += " ";
    else out += ch;
  }
  return out === line ? null : out;
}

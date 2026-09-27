// madedit2 user script (Tools menu): sorts the lines of the selection (or
// the whole file) with the whole-text contract: transformText gets the text
// in one piece, which is what an operation that needs every line at once
// requires. Files above the whole-text limit (Settings → Advanced…) are
// refused; select part of the file in that case.
//
// See api.md next to this file for the full contract.

function transformText(text) {
  // Keep the file's line endings: split on \n, strip a trailing \r per line,
  // and join back the same way.
  var crlf = text.indexOf("\r\n") >= 0;
  var lines = text.split("\n");
  var trailing = lines.length > 0 && lines[lines.length - 1] === "";
  if (trailing) lines.pop();
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].endsWith("\r")) lines[i] = lines[i].slice(0, -1);
  }
  lines.sort();
  var nl = crlf ? "\r\n" : "\n";
  return lines.join(nl) + (trailing ? nl : "");
}

# madedit2 User Scripting API

A script is one file in `settings/scripts/`: a `.js` file (JavaScript, run by
QuickJS) or a `.lua` file (Lua 5.4). The file name (without its extension) is
the name shown in the **Tools** menu. After adding or editing a script, click
**Tools → Reload Scripts**; no restart needed.

The reference below uses JavaScript; Lua differences are listed at the end
under "Lua scripts". Everything else (how scripts run, the limits) is the
same for both languages.

## Shape of a script

A script defines one (or both) of two global functions:

```js
// Line contract: called once per line, streamed, so it works on files of any size.
function transformLine(line, lineNo) {
  // return the new line text; null/undefined = unchanged; false = delete the line
  return line.toUpperCase();
}

// Whole-text contract: called once with the whole selection (or file).
function transformText(text) {
  // return the replacement, or null/undefined to leave it unchanged
  return text.split("\n").sort().join("\n");
}
```

When both are defined, `transformText` is used.

### `transformLine(line, lineNo)`

| Parameter / return | Meaning |
|---|---|
| `line` | one line of text, **without** its newline terminator |
| `lineNo` | 1-based ordinal of the line within the processed range (restarts at 1 when running on a selection) |
| return a string | replaces the line's content |
| return `null` / `undefined` | line stays as it is (faster than returning the original string) |
| return `false` | **deletes the line** (terminator included) |
| return anything else / throw | the run stops; the error (with the line number) is shown on screen |

The returned string may contain `\n`: it is normalized to the file's newline
style (LF or CRLF), effectively splitting one line into several. Returning an
empty string `""` clears the line's content but keeps the line; return
`false` to remove it.

Global variables **persist for the whole run** (one engine instance serves
all chunks), so a script can count, accumulate, or remember that it is
inside a block. Two optional hooks bracket a run:

```js
function beginTransform() { /* called once before the first line */ }
function endTransform()   { /* called once after the last line */ }
```

### `transformText(text)`

`text` is the whole selection, or the whole file when nothing is selected,
with the file's own line endings. Return the replacement string (its line
endings are normalized to the file's style), or `null`/`undefined` to leave
the text unchanged. Use this for anything that needs the full picture:
sorting, cross-line regular expressions, reformatting a document.

Because the whole text is held in memory several times over, this contract
is limited by **Settings → Advanced… → Whole-text script limit** (default
32 MB). A larger selection or file is refused with a message; select part of
the file, raise the limit, or write the script with `transformLine` instead.

## How scripts run

- Clicking a script in the **Tools** menu runs it over the **whole current
  file**, or, when there is a (linear) selection, over just **the lines the
  selection touches** (whole lines).
- One run = **one undo step** (a single Ctrl+Z reverts everything).
- Not available in hex mode (byte-oriented); a column (rectangular) selection
  is treated as no selection (whole file).
- With `transformLine`, the file is streamed through the script chunk by
  chunk (~1 MB), so GB-scale files work without loading everything into
  memory. With `transformText`, the selection (or the file) is handed over
  in one piece (subject to the whole-text limit above).
- While a script runs, a "Running script" dialog appears after a moment and
  closes when the run ends.

## Environment and limits

- The engine is QuickJS with modern JavaScript (ES2020+: arrow functions,
  template literals, named regex groups, `replaceAll`, BigInt, ...).
- **Sandboxed**: there are no host APIs at all: no file or network access,
  no `console` / `setTimeout` / `require` / `import`. Pure text in, text out.
- Each chunk of lines has an execution budget of about **10 seconds**;
  overrunning it (e.g. `while (true)`) aborts the run with an error. Memory is
  capped at 256 MB. A `transformText` call gets a budget and a memory cap that
  grow with the text (roughly 1 s and 8× per MB, within limits).
- A **single line** longer than about 1 MB (terminator included) is not
  handed to the script and passes through untouched; the completion message
  reports how many lines were skipped.
- Global variables persist for the whole run and are reset for the next one;
  `lineNo` still gives the position within the processed range.
- Results are written back in the file's current encoding; characters the
  encoding cannot represent become literal `U+XXXX` notation (same behavior
  as Replace).
- A script with a syntax error, or defining neither `transformLine` nor
  `transformText`, is reported in the log at load time and shows a message
  when run. An error thrown by `beginTransform` stops the run before it
  starts.

## Examples

```js
// Strip trailing whitespace from every line
function transformLine(line) {
  return line.replace(/\s+$/, "");
}
```

```js
// Prefix every line with its number (within the processed range)
function transformLine(line, lineNo) {
  return lineNo + "\t" + line;
}
```

```js
// Only touch lines containing TODO; return null to leave the rest alone
function transformLine(line) {
  return line.includes("TODO") ? line.toUpperCase() : null;
}
```

```js
// Swap the first two CSV columns
function transformLine(line) {
  const cols = line.split(",");
  if (cols.length < 2) return null;
  [cols[0], cols[1]] = [cols[1], cols[0]];
  return cols.join(",");
}
```

## Built-in scripts

These ship with madedit2 (seeded into `settings/scripts/` on first run) and
double as editable examples. Feel free to modify or delete them; they come
back only on a fresh install:

| Script | What it does |
|---|---|
| `to_upper` / `to_lower` | Uppercase / lowercase (Unicode-aware) |
| `fullwidth_to_halfwidth` | Fullwidth ASCII `Ｆｕｌｌ` → halfwidth `Full` (U+FF01-FF5E, ideographic space included) |
| `halfwidth_to_fullwidth` | The reverse mapping |
| `tabs_to_spaces` | Expand tabs, column-aware (a tab advances to the next tab stop); tab width is a `const TAB` at the top of the script |
| `spaces_to_tabs` | Convert leading indentation to tabs; spaces inside the line are left alone |
| `upper_first_word` | Uppercase the first word of every line (the original example) |
| `trim_trailing` (Lua) | Strip trailing whitespace (the Lua flavor example) |

Note: sorting lines is out of scope for `transformLine`: the contract is
strictly line-in/line-out, and reordering needs cross-line access.

## Lua scripts

`.lua` files run on Lua 5.4 with the same contract, named the Lua way:

```lua
function transform_line(line, line_no)
  -- return the new line text; return nil to leave the line unchanged
  return line:upper()
end
```

| JavaScript | Lua |
|---|---|
| `transformLine(line, lineNo)` | `transform_line(line, line_no)` |
| `transformText(text)` | `transform_text(text)` |
| `beginTransform()` / `endTransform()` | `begin_transform()` / `end_transform()` |
| return `null` / `undefined` = unchanged | return `nil` = unchanged |
| return `false` = delete the line | return `false` = delete the line |
| regular expressions (`replace(/…/)`) | **Lua patterns** (`line:gsub("%s+$", "")`), with different syntax: `%d` `%s` `%w` correspond to regex `\d` `\s` `\w`, and there is no `|` alternation |

Everything else is identical: the sandbox (only the string/table/math/utf8
standard libraries, no io/os), the 10-second budget, the memory cap, the
1 MB per-line limit, one-step undo, and selection handling. Note that Lua's
`string.upper`/`string.lower` only convert ASCII; for Unicode-aware case
mapping use a JavaScript script. Returned strings must be valid UTF-8
(byte strings assembled with `string.char` may not be).

```lua
-- Strip trailing whitespace (the built-in trim_trailing.lua)
function transform_line(line)
  local trimmed = line:gsub("%s+$", "")
  if trimmed == line then return nil end
  return trimmed
end
```

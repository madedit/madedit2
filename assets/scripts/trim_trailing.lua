-- madedit2 user script (Tools menu), Lua flavor. A Lua script is one
-- settings/scripts/<name>.lua file defining a global function:
--
--   transform_line(line, line_no)
--     line    : one line of text, without its newline terminator
--     line_no : 1-based ordinal of the line within the processed range
--     return  : the new line text; nil leaves the line unchanged.
--
-- Same sandbox and limits as JS scripts (see api.md); note Lua uses its own
-- pattern syntax (string.gsub etc.), not regular expressions.
--
-- This example removes trailing whitespace from every line.
function transform_line(line, line_no)
  local trimmed = line:gsub("%s+$", "")
  if trimmed == line then return nil end
  return trimmed
end

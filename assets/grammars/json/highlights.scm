; JSON 語法高亮查詢（tree-sitter-json）。
; capture 名稱須對應 Rust 端 RECOGNIZED 表（rust/src/api/highlight.rs）。
; tree-sitter-highlight 對「同節點多重 capture」採後者優先 →
; 把較特定的 key 放最後，使 JSON key 取 @string.special.key（property 色）而非 @string。
(string) @string
(number) @number
[(null) (true) (false)] @constant.builtin
(escape_sequence) @escape
(comment) @comment
(pair key: (_) @string.special.key)

// Tree-sitter syntax highlighting (Rust backend, called cross-platform via flutter_rust_bridge).
//
// Uses tree-sitter-highlight: parses a piece of text and runs the highlights query, producing
// byte-range highlight events. The priority of nested highlights (inner overrides outer) is
// handled by tree-sitter-highlight via a stack; the Dart side only needs to map the byte ranges
// back to per-line character spans. The view layer window-parses the visible lines, so it stays
// cheap even for GB-sized files.

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex, OnceLock};

use flutter_rust_bridge::frb;
use streaming_iterator::StreamingIterator;
use tree_sitter::wasmtime::Engine;
use tree_sitter::{InputEdit, Point, Query, QueryCursor, Tree, WasmStore};
use tree_sitter_highlight::{HighlightConfiguration, HighlightEvent, Highlighter};

/// A single highlight: byte range (within the spliced text) + style id (must align with the Hl in lib/editor/highlight.dart).
pub struct HlSpan {
    pub start: u32,
    pub end: u32,
    pub style: u32,
}

// Recognized capture name → style id. tree-sitter-highlight's configure matches a capture name
// against these by dotted parts: a recognized name applies when all of its parts occur in the
// capture name, the one with the **most parts** wins (constant.builtin beats constant), and a
// tie keeps the **earlier** entry (keyword.function → keyword, listed before function).
// capture_styles() below reproduces this. The style ids align with the Dart Hl:
// keyword1 string2 comment3 number4 type5 function6 constant7 property8 operator9 punctuation10
// heading11 link12 emphasis13 strong14 raw15 diffAdd16 diffDel17.
const RECOGNIZED: &[(&str, u32)] = &[
    ("comment", 3),
    ("string.special.key", 8), // JSON key → property
    ("string", 2),
    ("escape", 2),
    ("number", 4),
    ("constant.builtin", 7),
    ("constant", 7),
    ("boolean", 7),
    ("keyword", 1),
    ("type", 5),
    ("function", 6),
    ("property", 8),
    ("operator", 9),
    ("punctuation", 10),
    // ── Category 1: legacy/bare-name aliases → map to existing colors. Filling in the top-level
    //    name already covers its subtypes (e.g. conditional.ternary, function.method). ──
    ("conditional", 1), // legacy: equivalent to keyword.conditional
    ("repeat", 1),
    ("include", 1),
    ("import", 1),
    ("exception", 1),
    ("storageclass", 1),
    ("preproc", 1),     // C preprocessor
    ("tag", 1),         // HTML/XML tag name → blue (same as VS Code)
    ("label", 7),       // label (goto, etc.)
    ("constructor", 5), // constructor → type color
    ("module", 5),
    ("namespace", 5),
    ("interface", 5),
    ("method", 6),      // bare method → function
    ("attribute", 6),   // decorator/annotation (@decorator, #[..]) → function yellow
    ("float", 4),       // bare float → number
    ("character", 2),   // character literal → string
    ("field", 8),       // bare field → property
    ("delimiter", 10),  // bare delimiter → punctuation
    // ── Markdown (grammars use both text.* [legacy] and markup.* [modern]; both are matched) ──
    ("text.title", 11),
    ("markup.heading", 11),
    ("text.uri", 12),
    ("text.reference", 12),
    ("markup.link", 12),
    ("text.emphasis", 13),
    ("markup.italic", 13),
    ("text.strong", 14),
    ("markup.strong", 14),
    ("text.literal", 15),
    ("markup.raw", 15),
    ("markup.list", 10), // list marker → punctuation
    // ── diff ──
    ("diff.plus", 16),
    ("diff.minus", 17),
];

// Custom JSON highlight query. For multiple captures on the same node, tree-sitter-highlight uses
// **last one wins**, so we put the more specific key last → a JSON key gets @string.special.key
// (property) rather than @string.
const JSON_HIGHLIGHTS: &str = r#"
(string) @string
(number) @number
[(null) (true) (false)] @constant.builtin
(escape_sequence) @escape
(comment) @comment
(pair key: (_) @string.special.key)
"#;

fn make_config(lang: &str) -> Option<HighlightConfiguration> {
    let (language, query) = match lang {
        "json" => (tree_sitter_json::LANGUAGE.into(), JSON_HIGHLIGHTS),
        _ => return None,
    };
    let names: Vec<&str> = RECOGNIZED.iter().map(|(n, _)| *n).collect();
    let mut cfg = HighlightConfiguration::new(language, lang, query, "", "").ok()?;
    cfg.configure(&names);
    Some(cfg)
}

// Run tree-sitter-highlight and collect the HighlightEvents into byte-range spans (shared by the static and wasm paths).
fn run_highlight(hl: &mut Highlighter, cfg: &HighlightConfiguration, source: &str) -> Vec<HlSpan> {
    let styles: Vec<u32> = RECOGNIZED.iter().map(|(_, s)| *s).collect();
    let src = source.as_bytes();
    let iter = match hl.highlight(cfg, src, None, |_: &str| -> Option<&HighlightConfiguration> {
        None
    }) {
        Ok(it) => it,
        Err(_) => return Vec::new(),
    };
    let mut stack: Vec<u32> = Vec::new();
    let mut out: Vec<HlSpan> = Vec::new();
    for ev in iter {
        match ev {
            Ok(HighlightEvent::HighlightStart(h)) => {
                stack.push(*styles.get(h.0).unwrap_or(&0));
            }
            Ok(HighlightEvent::HighlightEnd) => {
                stack.pop();
            }
            Ok(HighlightEvent::Source { start, end }) => {
                if let Some(&style) = stack.last() {
                    if style != 0 && end > start {
                        out.push(HlSpan {
                            start: start as u32,
                            end: end as u32,
                            style,
                        });
                    }
                }
            }
            Err(_) => break,
        }
    }
    out
}

/// Highlight [source] using the **statically compiled-in** grammar for [lang] (e.g. "json"),
/// returning byte-range spans. Unsupported languages or parse failures return empty (the Dart side
/// falls back to the pure-Dart highlighter).
#[frb(sync)]
pub fn highlight(lang: String, source: String) -> Vec<HlSpan> {
    highlight_static(&lang, &source)
}

/// Async variant of [highlight]: flutter_rust_bridge runs it on a worker thread, so highlighting a
/// whole (multi-MB) file does not block the UI isolate. Same result as [highlight].
pub fn highlight_off_thread(lang: String, source: String) -> Vec<HlSpan> {
    highlight_static(&lang, &source)
}

fn highlight_static(lang: &str, source: &str) -> Vec<HlSpan> {
    let Some(cfg) = make_config(lang) else {
        return Vec::new();
    };
    let mut hl = Highlighter::new();
    run_highlight(&mut hl, &cfg, source)
}

// A ready-to-use wasm highlighter per language (grammar already compiled, store already bound into the parser).
struct WasmHl {
    highlighter: Highlighter,
    config: HighlightConfiguration,
}

// The raw grammar bytes registered from Dart, kept globally so a highlighter can be rebuilt for
// any language (on any thread) without Dart having to hand the multi-MB wasm over again.
struct GrammarSrc {
    wasm: Vec<u8>,
    query: String,
}

fn wasm_sources() -> &'static Mutex<HashMap<String, Arc<GrammarSrc>>> {
    static SRC: OnceLock<Mutex<HashMap<String, Arc<GrammarSrc>>>> = OnceLock::new();
    SRC.get_or_init(|| Mutex::new(HashMap::new()))
}

// Idle, ready-to-use highlighters per language. A WasmHl can be **moved** between threads
// (tree-sitter marks WasmStore Send) but not shared, and a whole-file parse can take seconds, so
// the lock is only held while checking one out / putting it back — never during the parse itself.
//
// A pool rather than a thread_local cache: flutter_rust_bridge hands every async call a fresh
// worker thread, so a per-thread cache never hit and each whole-file highlight recompiled the
// grammar (~100 ms for markdown, more for the big ones). Bounded: at most [MAX_IDLE] parked
// highlighters per language, each holding a compiled wasm module.
const MAX_IDLE: usize = 4;

fn wasm_pool() -> &'static Mutex<HashMap<String, Vec<WasmHl>>> {
    static POOL: OnceLock<Mutex<HashMap<String, Vec<WasmHl>>>> = OnceLock::new();
    POOL.get_or_init(|| Mutex::new(HashMap::new()))
}

// Languages whose grammar failed to build (e.g. wasm incompatible with the runtime). Remembered so
// a failure is not retried on every highlight call.
fn wasm_failed() -> &'static Mutex<HashSet<String>> {
    static FAILED: OnceLock<Mutex<HashSet<String>>> = OnceLock::new();
    FAILED.get_or_init(|| Mutex::new(HashSet::new()))
}

// Check out a highlighter for [lang]: one from the pool, or freshly built on first use. `None` if
// the language was never registered or its grammar failed to build. Pair with [park_wasm_hl].
fn take_wasm_hl(lang: &str) -> Option<WasmHl> {
    let parked = wasm_pool()
        .lock()
        .ok()
        .and_then(|mut p| p.get_mut(lang).and_then(|v| v.pop()));
    if let Some(hl) = parked {
        return Some(hl);
    }
    if wasm_failed().lock().is_ok_and(|s| s.contains(lang)) {
        return None;
    }
    // Nothing parked: rebuild from the registered source. Absent source → never registered, so
    // don't remember a failure (a later register must still work).
    let src = wasm_sources()
        .lock()
        .ok()
        .and_then(|m| m.get(lang).cloned())?;
    match build_wasm_hl(lang, &src.wasm, &src.query) {
        Some(hl) => Some(hl),
        None => {
            if let Ok(mut failed) = wasm_failed().lock() {
                failed.insert(lang.to_string());
            }
            None
        }
    }
}

// Return a checked-out highlighter to the pool (dropped when the pool is full).
fn park_wasm_hl(lang: &str, hl: WasmHl) {
    if let Ok(mut p) = wasm_pool().lock() {
        let idle = p.entry(lang.to_string()).or_default();
        if idle.len() < MAX_IDLE {
            idle.push(hl);
        }
    }
}

// Run [f] with a highlighter for [lang] (see [take_wasm_hl]); `None` is passed if unavailable.
fn with_wasm_hl<R>(lang: &str, f: impl FnOnce(Option<&mut WasmHl>) -> R) -> R {
    let Some(mut hl) = take_wasm_hl(lang) else {
        return f(None);
    };
    let out = f(Some(&mut hl));
    park_wasm_hl(lang, hl);
    out
}

/// Try loading a WASM grammar and return whether it succeeded. The Dart side uses this at startup
/// to weed out **incompatible** wasm (e.g. built with old emscripten / the old `dylink` format),
/// falling back to static tree-sitter / pure-Dart highlighting instead.
#[frb(sync)]
pub fn wasm_grammar_loads(lang: String, wasm: Vec<u8>) -> bool {
    let engine = Engine::default();
    let Ok(mut store) = WasmStore::new(&engine) else {
        return false;
    };
    store.load_language(&lang, &wasm).is_ok()
}

/// Register (compile + cache) a **WASM grammar loaded at runtime** (a syntax plugin) under [lang].
/// Pass the grammar's `.wasm` bytes and highlights.scm content **once**; afterwards call
/// [highlight_wasm] with only `(lang, source)`. This avoids marshalling the multi-MB wasm across
/// the FFI boundary on every highlight call (e.g. cpp's wasm is ~5 MB, so doing it per scroll
/// frame / keystroke is what made highlighting lag). Returns whether the grammar built
/// successfully; the result (including failure) is cached, so calling again is cheap.
#[frb(sync)]
pub fn register_wasm_grammar(lang: String, wasm: Vec<u8>, query: String) -> bool {
    if let Ok(mut src) = wasm_sources().lock() {
        src.entry(lang.clone()).or_insert_with(|| {
            Arc::new(GrammarSrc {
                wasm,
                query,
            })
        });
    }
    with_wasm_hl(&lang, |hl| hl.is_some())
}

/// Highlight [source] with a grammar previously registered via [register_wasm_grammar], looked up
/// by [lang]. Returns empty if the language was never registered or its build failed. Passing only
/// `(lang, source)` keeps each call cheap — the wasm bytes stay in Rust's thread_local cache.
#[frb(sync)]
pub fn highlight_wasm(lang: String, source: String) -> Vec<HlSpan> {
    with_wasm_hl(&lang, |hl| match hl {
        Some(entry) => run_highlight(&mut entry.highlighter, &entry.config, &source),
        None => Vec::new(), // not registered / known build failure → no retry
    })
}

/// Async variant of [highlight_wasm]: flutter_rust_bridge runs it on a worker thread, so
/// highlighting a whole (multi-MB) file does not block the UI isolate. The grammar must already
/// have been registered via [register_wasm_grammar]; the worker borrows a compiled highlighter
/// from the shared pool (see [with_wasm_hl]) and parks it again when done.
pub fn highlight_wasm_off_thread(lang: String, source: String) -> Vec<HlSpan> {
    with_wasm_hl(&lang, |hl| match hl {
        Some(entry) => run_highlight(&mut entry.highlighter, &entry.config, &source),
        None => Vec::new(),
    })
}

// Compile the wasm grammar and build a reusable highlighter (only when the pool has none parked).
fn build_wasm_hl(lang: &str, wasm: &[u8], query: &str) -> Option<WasmHl> {
    let engine = Engine::default();
    let mut store = WasmStore::new(&engine).ok()?;
    let language = store.load_language(lang, wasm).ok()?;
    let names: Vec<&str> = RECOGNIZED.iter().map(|(n, _)| *n).collect();
    let mut config = HighlightConfiguration::new(language, lang, query, "", "").ok()?;
    config.configure(&names);
    let mut highlighter = Highlighter::new();
    highlighter.parser().set_wasm_store(store).ok()?; // let the parser run wasm languages
    Some(WasmHl {
        highlighter,
        config,
    })
}

/// Languages **statically compiled into** this backend (lowercase file extension). WASM plugin support is determined by the Dart side's scan.
#[frb(sync)]
pub fn supported_language(ext: String) -> bool {
    matches!(ext.as_str(), "json")
}


// ─────────────────────────────────────────────────────────────────────────────
// Incremental whole-file highlighting sessions.
//
// A session keeps a document's text and its syntax tree. An edit replaces a range of lines:
// the tree is told about the byte edit (`Tree::edit`), re-parsed against the old tree
// (tree-sitter reuses every unchanged subtree, so this is milliseconds even for a multi-MB file),
// and the highlights query is re-run only over the lines whose syntax changed
// (`Tree::changed_ranges` ∪ the edited lines). tree-sitter-highlight cannot do this — its
// `highlight()` always parses from scratch — so the query is run here with the same rules it
// applies (no injections / locals are used by this app): among several captures on one node the
// last pattern wins, a node whose winning capture is unrecognized stays transparent, and an inner
// highlight overrides the outer one. Verified against tree-sitter-highlight in
// tool/rust_highlight_test.dart.
// ─────────────────────────────────────────────────────────────────────────────

/// One highlighted span within a line, in UTF-16 code units (what Dart's ParagraphBuilder indexes
/// by), so the Dart side needs no text to apply it.
pub struct HlLineSpan {
    pub line: u32,
    pub start: u32,
    pub end: u32,
    pub style: u32,
}

/// Result of [hl_doc_edit]: lines `[start_line, end_line)` (new numbering) were re-highlighted;
/// [spans] holds their complete new spans (a line without spans is simply absent).
pub struct HlPatch {
    pub start_line: i64,
    pub end_line: i64,
    pub spans: Vec<HlLineSpan>,
}

struct HlDoc {
    lang: String,
    wasm: bool,
    source: String,
    line_starts: Vec<usize>, // byte offset of each line's start; `[0] == 0`, len == line count
    tree: Tree,
    hl: WasmHl, // parser (+ wasm store) and query; also used for the static grammar
    styles: Vec<u32>, // query capture index → style id (0 = unrecognized)
}

fn hl_docs() -> &'static Mutex<HashMap<i64, HlDoc>> {
    static DOCS: OnceLock<Mutex<HashMap<i64, HlDoc>>> = OnceLock::new();
    DOCS.get_or_init(|| Mutex::new(HashMap::new()))
}

// Ids closed while their doc was checked out by an in-flight edit: the edit must drop the doc
// instead of putting it back.
fn hl_docs_closed() -> &'static Mutex<HashSet<i64>> {
    static CLOSED: OnceLock<Mutex<HashSet<i64>>> = OnceLock::new();
    CLOSED.get_or_init(|| Mutex::new(HashSet::new()))
}

// Capture index → style id, exactly like HighlightConfiguration::configure resolves capture
// names against RECOGNIZED: a recognized name matches when every dotted part of it occurs among
// the capture name's parts, the one with the most parts wins, and ties keep the earlier entry.
fn capture_styles(query: &Query) -> Vec<u32> {
    query
        .capture_names()
        .iter()
        .map(|name| {
            let parts: Vec<&str> = name.split('.').collect();
            let mut best: Option<(usize, u32)> = None;
            for (rec, style) in RECOGNIZED {
                let mut len = 0;
                let mut ok = true;
                for part in rec.split('.') {
                    len += 1;
                    if !parts.contains(&part) {
                        ok = false;
                        break;
                    }
                }
                if ok && best.is_none_or(|(l, _)| len > l) {
                    best = Some((len, *style));
                }
            }
            best.map_or(0, |(_, s)| s)
        })
        .collect()
}

fn line_starts_of(s: &str) -> Vec<usize> {
    let mut v = vec![0];
    for (i, b) in s.bytes().enumerate() {
        if b == b'\n' {
            v.push(i + 1);
        }
    }
    v
}

fn line_of(ls: &[usize], byte: usize) -> usize {
    ls.partition_point(|&s| s <= byte).saturating_sub(1)
}

fn point_at(ls: &[usize], byte: usize) -> Point {
    let row = line_of(ls, byte);
    Point::new(row, byte - ls[row])
}

// End of a line's content (its '\n' excluded; the text end for the last line).
fn line_end(src: &str, ls: &[usize], line: usize) -> usize {
    if line + 1 < ls.len() {
        ls[line + 1] - 1
    } else {
        src.len()
    }
}

// Run the highlights query over the nodes intersecting [range] and flatten the captures into
// non-overlapping byte spans clipped to [range], reproducing tree-sitter-highlight's event stream
// (see the module comment above).
fn query_spans(
    query: &Query,
    styles: &[u32],
    tree: &Tree,
    source: &str,
    range: std::ops::Range<usize>,
) -> Vec<HlSpan> {
    let mut cursor = QueryCursor::new();
    cursor.set_byte_range(range.clone());
    let mut caps = cursor.captures(query, tree.root_node(), source.as_bytes());
    // Nodes in capture order (by start byte); per node the last pattern's capture decides.
    let mut nodes: Vec<(usize, usize, u32)> = Vec::new();
    let mut pending: Option<(usize, usize, usize, u32)> = None; // node id, start, end, style
    while let Some((m, ci)) = caps.next() {
        let cap = m.captures[*ci];
        let style = styles.get(cap.index as usize).copied().unwrap_or(0);
        let id = cap.node.id();
        match pending.as_mut() {
            Some(p) if p.0 == id => p.3 = style,
            _ => {
                if let Some(p) = pending.take() {
                    if p.3 != 0 {
                        nodes.push((p.1, p.2, p.3));
                    }
                }
                pending = Some((id, cap.node.start_byte(), cap.node.end_byte(), style));
            }
        }
    }
    if let Some(p) = pending {
        if p.3 != 0 {
            nodes.push((p.1, p.2, p.3));
        }
    }

    // Same stack discipline as tree-sitter-highlight: a highlight ends (LIFO) once the next
    // capture starts at or past its end; the text in between is painted with the innermost
    // open highlight.
    let mut out: Vec<HlSpan> = Vec::new();
    let mut stack: Vec<(usize, u32)> = Vec::new(); // (end, style)
    let mut cursor_b = 0usize;
    let emit = |s: usize, e: usize, style: u32, out: &mut Vec<HlSpan>| {
        let s = s.max(range.start);
        let e = e.min(range.end);
        if e > s {
            out.push(HlSpan {
                start: s as u32,
                end: e as u32,
                style,
            });
        }
    };
    for (s, e, style) in nodes {
        while let Some(&(top_end, top_style)) = stack.last() {
            if top_end > s {
                break;
            }
            if top_end > cursor_b {
                emit(cursor_b, top_end, top_style, &mut out);
                cursor_b = top_end;
            }
            stack.pop();
        }
        if let Some(&(_, top_style)) = stack.last() {
            if s > cursor_b {
                emit(cursor_b, s, top_style, &mut out);
            }
        }
        if s > cursor_b {
            cursor_b = s;
        }
        stack.push((e, style));
    }
    while let Some((top_end, top_style)) = stack.pop() {
        if top_end > cursor_b {
            emit(cursor_b, top_end, top_style, &mut out);
            cursor_b = top_end;
        }
    }
    out
}

// Byte spans (over the whole source) → per-line UTF-16 spans for lines [x, y).
fn to_line_spans(src: &str, ls: &[usize], x: usize, y: usize, spans: &[HlSpan]) -> Vec<HlLineSpan> {
    let mut out = Vec::new();
    let mut si = 0; // first span that may still touch the current line
    for line in x..y {
        let l0 = ls[line];
        let l1 = line_end(src, ls, line);
        while si < spans.len() && (spans[si].end as usize) <= l0 {
            si += 1;
        }
        let text = &src[l0..l1];
        let mut chars = text.char_indices().peekable();
        let mut ui = 0u32; // UTF-16 index reached so far
        let mut utf16_at = |target: usize| -> u32 {
            while let Some(&(pos, ch)) = chars.peek() {
                if pos >= target {
                    break;
                }
                chars.next();
                ui += ch.len_utf16() as u32;
            }
            ui
        };
        let mut k = si;
        while k < spans.len() && (spans[k].start as usize) < l1 {
            let s = (spans[k].start as usize).max(l0) - l0;
            let e = (spans[k].end as usize).min(l1) - l0;
            if e > s {
                let us = utf16_at(s);
                let ue = utf16_at(e);
                if ue > us {
                    out.push(HlLineSpan {
                        line: line as u32,
                        start: us,
                        end: ue,
                        style: spans[k].style,
                    });
                }
            }
            if (spans[k].end as usize) > l1 {
                break; // continues on the next line
            }
            k += 1;
        }
    }
    out
}

// A parser + query for [lang]: from the wasm pool, or the statically compiled-in grammar.
fn take_hl(lang: &str, wasm: bool) -> Option<WasmHl> {
    if wasm {
        return take_wasm_hl(lang);
    }
    let config = make_config(lang)?;
    Some(WasmHl {
        highlighter: Highlighter::new(),
        config,
    })
}

fn park_hl(lang: &str, wasm: bool, hl: WasmHl) {
    if wasm {
        park_wasm_hl(lang, hl);
    }
}

/// Open an incremental highlighting session for document [id] (replacing any previous session
/// under that id): parse [source] whole and return its byte-range spans (as [highlight] would),
/// keeping the text and syntax tree for later [hl_doc_edit] calls. `None` = the grammar is not
/// available (the caller falls back to window parsing). Runs on a worker thread.
pub fn hl_doc_open(id: i64, lang: String, wasm: bool, source: String) -> Option<Vec<HlSpan>> {
    if let Some(old) = hl_docs().lock().ok().and_then(|mut d| d.remove(&id)) {
        park_hl(&old.lang, old.wasm, old.hl);
    }
    let mut hl = take_hl(&lang, wasm)?;
    // tree-sitter-highlight binds the language inside highlight(); a fresh parser has none.
    if hl.highlighter.parser().set_language(&hl.config.language).is_err() {
        park_hl(&lang, wasm, hl);
        return None;
    }
    let Some(tree) = hl.highlighter.parser().parse(source.as_bytes(), None) else {
        park_hl(&lang, wasm, hl);
        return None;
    };
    let styles = capture_styles(&hl.config.query);
    let spans = query_spans(&hl.config.query, &styles, &tree, &source, 0..source.len());
    let line_starts = line_starts_of(&source);
    if let Ok(mut docs) = hl_docs().lock() {
        docs.insert(
            id,
            HlDoc {
                lang,
                wasm,
                source,
                line_starts,
                tree,
                hl,
                styles,
            },
        );
    }
    Some(spans)
}

/// Replace lines `[start_line, old_end_line)` of session [id] with [new_lines] (line numbering as
/// of the previous call), re-parse incrementally and return the lines whose highlighting must be
/// replaced. `None` = no such session (or the edit was out of range): the caller reopens.
/// Runs on a worker thread; edits of one session must not overlap.
pub fn hl_doc_edit(id: i64, start_line: i64, old_end_line: i64, new_lines: Vec<String>) -> Option<HlPatch> {
    let mut doc = hl_docs().lock().ok()?.remove(&id)?;
    let out = doc_edit(&mut doc, start_line as usize, old_end_line as usize, &new_lines);
    let closed = hl_docs_closed()
        .lock()
        .map(|mut c| c.remove(&id))
        .unwrap_or(false);
    if out.is_none() || closed {
        park_hl(&doc.lang, doc.wasm, doc.hl);
    } else if let Ok(mut docs) = hl_docs().lock() {
        docs.insert(id, doc);
    }
    out
}

fn doc_edit(doc: &mut HlDoc, a: usize, b: usize, new_lines: &[String]) -> Option<HlPatch> {
    let old_count = doc.line_starts.len();
    if a > b || b > old_count {
        return None;
    }
    let m = new_lines.len();
    if a == b && m == 0 {
        return Some(HlPatch {
            start_line: a as i64,
            end_line: a as i64,
            spans: Vec::new(),
        });
    }
    // The byte range standing for lines [a, b) and its replacement. Lines are joined by '\n' with
    // none after the last, so deleting up to the end also eats the '\n' before line a, and
    // appending after the last line prepends one.
    let len = doc.source.len();
    let (start_b, end_b, repl) = if m == 0 {
        if b == old_count {
            let s = if a > 0 { doc.line_starts[a] - 1 } else { 0 };
            (s, len, String::new())
        } else {
            (doc.line_starts[a], doc.line_starts[b], String::new())
        }
    } else {
        let joined = new_lines.join("\n");
        if a == old_count {
            (len, len, format!("\n{joined}"))
        } else if b == old_count {
            (doc.line_starts[a], len, joined)
        } else {
            (doc.line_starts[a], doc.line_starts[b], format!("{joined}\n"))
        }
    };
    let new_end = start_b + repl.len();
    let start_position = point_at(&doc.line_starts, start_b);
    let old_end_position = point_at(&doc.line_starts, end_b);
    doc.source.replace_range(start_b..end_b, &repl);
    doc.line_starts = line_starts_of(&doc.source);
    let edit = InputEdit {
        start_byte: start_b,
        old_end_byte: end_b,
        new_end_byte: new_end,
        start_position,
        old_end_position,
        new_end_position: point_at(&doc.line_starts, new_end),
    };
    doc.tree.edit(&edit);
    let new_tree = doc
        .hl
        .highlighter
        .parser()
        .parse(doc.source.as_bytes(), Some(&doc.tree))?;
    // Lines to re-query: the edited text plus wherever the syntax changed around it.
    let (mut lo, mut hi) = (start_b, new_end);
    for r in doc.tree.changed_ranges(&new_tree) {
        lo = lo.min(r.start_byte);
        hi = hi.max(r.end_byte);
    }
    doc.tree = new_tree;
    let src_len = doc.source.len();
    let hi = hi.min(src_len);
    let x = line_of(&doc.line_starts, lo);
    let mut y = line_of(&doc.line_starts, hi.saturating_sub(1).max(lo)) + 1;
    // Cover every replacement line, and the line after a pure deletion (its context changed).
    let new_count = doc.line_starts.len();
    y = y.max((a + m.max(1)).min(new_count));
    let range = doc.line_starts[x]..line_end(&doc.source, &doc.line_starts, y - 1);
    let spans = query_spans(&doc.hl.config.query, &doc.styles, &doc.tree, &doc.source, range);
    Some(HlPatch {
        start_line: x as i64,
        end_line: y as i64,
        spans: to_line_spans(&doc.source, &doc.line_starts, x, y, &spans),
    })
}

/// A foldable region: hiding rows `start_row + 1 ..= end_row` collapses it
/// (rows are 0-based lines of the session's source).
pub struct FoldRange {
    pub start_row: u32,
    pub end_row: u32,
}

/// Foldable regions of session [id], from its syntax tree (see
/// [collect_folds]); `None` = no such session. Sync: a tree walk, no parse.
#[frb(sync)]
pub fn hl_doc_folds(id: i64) -> Option<Vec<FoldRange>> {
    let docs = hl_docs().lock().ok()?;
    let doc = docs.get(&id)?;
    Some(collect_folds(&doc.tree, &doc.source))
}

/// Which node kinds fold, without per-language queries (the installed
/// grammars ship highlights.scm only): a node spanning several rows whose
/// first child is an opening bracket, whose kind names a block / body /
/// section / list, or that is a comment. A body that starts on a later row
/// than its parent (Python `block`, Allman-style `{`) folds the parent
/// instead, so the header line is the `def` / signature. The closing
/// bracket's line stays visible.
fn collect_folds(tree: &Tree, source: &str) -> Vec<FoldRange> {
    fn opens(t: &str) -> bool {
        matches!(t, "{" | "(" | "[")
    }
    fn closes(t: &str) -> bool {
        matches!(t, "}" | ")" | "]" | "end" | "fi" | "done" | "esac")
    }
    fn kind_folds(kind: &str) -> bool {
        kind == "block"
            || kind.ends_with("_block")
            || kind == "body"
            || kind.ends_with("_body")
            || kind.ends_with("section")
            || kind == "element"
            || (kind.ends_with("_list") && !kind.contains("parameter") && !kind.contains("argument"))
            || kind.contains("comment")
    }
    let mut out: Vec<FoldRange> = Vec::new();
    let mut cursor = tree.walk();
    loop {
        let node = cursor.node();
        let sr = node.start_position().row;
        let end_pos = node.end_position();
        // A node that ends exactly at column 0 (its last token is a newline —
        // a markdown `section`, a trailing-newline block) owns nothing on
        // that row: the row belongs to whatever comes next, so it must not
        // be folded away with this node.
        let er = if end_pos.column == 0 && end_pos.row > sr {
            end_pos.row - 1
        } else {
            end_pos.row
        };
        if er > sr {
            let first_open = node
                .child(0)
                .filter(|c| !c.is_named())
                .map(|c| opens(&source[c.byte_range()]))
                .unwrap_or(false);
            if first_open || kind_folds(node.kind()) {
                // Header row: the node's own, or its parent's when the node is a
                // body starting below the construct it belongs to.
                // Not for sections: a markdown subsection is its own fold even
                // though the last one shares its end row with the parent
                // section (promoting it would lose "## B" entirely).
                let mut header = sr;
                if !node.kind().ends_with("section") {
                    if let Some(p) = node.parent() {
                        let psr = p.start_position().row;
                        if psr < sr && p.end_position().row == er {
                            header = psr;
                        }
                    }
                }
                // Keep a closing bracket's line visible.
                let mut end = er;
                if node.child_count() > 0 {
                    if let Some(last) = node.child((node.child_count() - 1) as u32) {
                        if !last.is_named()
                            && closes(&source[last.byte_range()])
                            && last.start_position().row == er
                        {
                            end = er - 1;
                        }
                    }
                }
                if end > header && out.last().map(|f| f.start_row as usize != header).unwrap_or(true)
                    && !out.iter().rev().take(4).any(|f| f.start_row as usize == header)
                {
                    out.push(FoldRange { start_row: header as u32, end_row: end as u32 });
                    if out.len() >= 100_000 {
                        break;
                    }
                }
            }
        }
        if cursor.goto_first_child() {
            continue;
        }
        loop {
            if cursor.goto_next_sibling() {
                break;
            }
            if !cursor.goto_parent() {
                return out;
            }
        }
    }
    out
}

/// Drop session [id] (no-op if there is none).
#[frb(sync)]
pub fn hl_doc_close(id: i64) {
    let doc = hl_docs().lock().ok().and_then(|mut d| d.remove(&id));
    match doc {
        Some(doc) => park_hl(&doc.lang, doc.wasm, doc.hl),
        None => {
            // Possibly checked out by an in-flight edit: tell it not to come back.
            if let Ok(mut c) = hl_docs_closed().lock() {
                c.insert(id);
            }
        }
    }
}

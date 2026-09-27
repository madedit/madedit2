// User scripting plugin (QuickJS via rquickjs, called cross-platform via flutter_rust_bridge).
//
// A user script (settings/scripts/*.js) defines one or both of
//   transformLine(line, lineNo) -> string | null | undefined | false
//   transformText(text)         -> string | null | undefined
// plus optional hooks beginTransform() / endTransform(). The Dart side streams
// the document's lines through a **session** ([script_session_open] …
// [script_session_close]): one engine instance lives for the whole run, so a
// script's globals carry state from chunk to chunk (a counter, "inside a
// comment" flags…). For transformLine a returned string replaces the line,
// null/undefined leaves it as is and `false` deletes it; transformText gets
// the whole selected range (bounded by the Dart side's size cap) and returns
// the replacement or null for "unchanged".
//
// Threading: a QuickJS Runtime is neither Send nor Sync, so each session owns
// a dedicated OS thread that holds the runtime and serves requests over a
// channel; the FRB worker thread that handles a call just blocks on the
// reply. Sources are registered once into a global map; [js_register_script]
// compiles on the calling thread to surface syntax errors immediately. The
// Lua backend (lua_script.rs) plugs into the same session machinery through
// the [Runner] trait, so the Dart side is engine-agnostic past `open`.
//
// Safety rails: an interrupt handler enforces a wall-clock deadline per call
// (runaway `while(true)` scripts abort instead of hanging the thread), and
// the runtime carries a memory limit — both scaled up for a whole-text call.
// Scripts get no host APIs at all (no filesystem / network / timers) — pure
// text in, text out.

use std::cell::RefCell;
use std::collections::HashMap;
use std::sync::atomic::{AtomicI64, AtomicU64, Ordering};
use std::sync::mpsc::{channel, Sender};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Instant;

use flutter_rust_bridge::frb;
use rquickjs::{CatchResultExt, Context, Function, Runtime, Value};

/// Wall-clock budget for one chunk of lines.
pub(crate) const CALL_BUDGET_MS: u64 = 10_000;
/// Base memory cap; a line chunk works on ~1 MB of text at a time.
pub(crate) const MEMORY_LIMIT: usize = 256 * 1024 * 1024;

/// Budget / memory for a whole-text call, scaled by the text size.
#[frb(ignore)]
pub(crate) fn text_budget_ms(bytes: usize) -> u64 {
    (CALL_BUDGET_MS + (bytes as u64 / (1 << 20)) * 1_000).min(600_000)
}
#[frb(ignore)]
pub(crate) fn text_memory_limit(bytes: usize) -> usize {
    MEMORY_LIMIT.max(bytes.saturating_mul(8)).min(2 * 1024 * 1024 * 1024)
}

/// Result of one chunked transform call. `error == None` means success:
/// `lines` and `deleted` both have the input's length (`deleted[i]` = the
/// script returned `false` for line i, whose `lines[i]` is then unused).
/// On error both are empty.
pub struct JsTransformOut {
    pub lines: Vec<String>,
    pub deleted: Vec<bool>,
    pub error: Option<String>,
}

#[frb(ignore)]
impl JsTransformOut {
    pub(crate) fn err(e: String) -> Self {
        JsTransformOut {
            lines: Vec::new(),
            deleted: Vec::new(),
            error: Some(e),
        }
    }
}

/// Result of a whole-text call: `text == None` with no error = unchanged.
pub struct ScriptTextOut {
    pub text: Option<String>,
    pub error: Option<String>,
}

/// What [script_session_open] hands back: the session id (valid when
/// `error` is None) and which contract functions the script defines.
pub struct ScriptOpen {
    pub id: i64,
    pub has_line: bool,
    pub has_text: bool,
    pub error: Option<String>,
}

// name -> registered source. Overwritten on re-register (script reload).
fn script_sources() -> &'static Mutex<HashMap<String, Arc<String>>> {
    static SRC: OnceLock<Mutex<HashMap<String, Arc<String>>>> = OnceLock::new();
    SRC.get_or_init(|| Mutex::new(HashMap::new()))
}

#[frb(ignore)]
pub(crate) fn js_source(name: &str) -> Option<Arc<String>> {
    script_sources().lock().ok().and_then(|m| m.get(name).cloned())
}

// A compiled script: its own runtime + context with the script already
// evaluated (so the contract functions sit in the globals).
#[frb(ignore)]
pub(crate) struct ScriptCtx {
    // Field order = drop order: the Context must drop before its Runtime.
    context: Context,
    runtime: Runtime,
    source: Arc<String>,
    // Deadline for the interrupt handler, in ms since `epoch` (0 = no deadline).
    deadline_ms: Arc<AtomicU64>,
    epoch: Instant,
}

thread_local! {
    static SCRIPT_CACHE: RefCell<HashMap<String, ScriptCtx>> = RefCell::new(HashMap::new());
}

#[frb(ignore)]
pub(crate) fn build_ctx(source: Arc<String>) -> Result<ScriptCtx, String> {
    let runtime = Runtime::new().map_err(|e| e.to_string())?;
    runtime.set_memory_limit(MEMORY_LIMIT);
    let epoch = Instant::now();
    let deadline_ms = Arc::new(AtomicU64::new(0));
    {
        let deadline = Arc::clone(&deadline_ms);
        runtime.set_interrupt_handler(Some(Box::new(move || {
            let d = deadline.load(Ordering::Relaxed);
            d != 0 && epoch.elapsed().as_millis() as u64 > d
        })));
    }
    let context = Context::full(&runtime).map_err(|e| e.to_string())?;
    context.with(|ctx| -> Result<(), String> {
        ctx.eval::<(), _>(source.as_bytes())
            .catch(&ctx)
            .map_err(|e| e.to_string())?;
        // Fail registration early when no contract function exists.
        let line: Result<Function, _> = ctx.globals().get("transformLine");
        let text: Result<Function, _> = ctx.globals().get("transformText");
        if line.is_err() && text.is_err() {
            return Err(
                "script defines neither transformLine(line, lineNo) nor transformText(text)"
                    .to_string(),
            );
        }
        Ok(())
    })?;
    Ok(ScriptCtx {
        context,
        runtime,
        source,
        deadline_ms,
        epoch,
    })
}

#[frb(ignore)]
impl ScriptCtx {
    fn arm(&self, budget_ms: u64) {
        self.deadline_ms.store(
            self.epoch.elapsed().as_millis() as u64 + budget_ms,
            Ordering::Relaxed,
        );
    }
    fn disarm(&self) {
        self.deadline_ms.store(0, Ordering::Relaxed);
    }
}

/// One engine instance serving a session (implemented by the JS and Lua
/// contexts); the session thread only talks to this.
#[frb(ignore)]
pub(crate) trait Runner {
    fn has(&self, func: &str) -> bool;
    fn call_hook(&self, func: &str) -> Result<(), String>;
    fn transform_lines(&self, lines: &[String], first_line_no: i64) -> JsTransformOut;
    fn transform_text(&self, text: &str) -> ScriptTextOut;
}

#[frb(ignore)]
impl Runner for ScriptCtx {
    fn has(&self, func: &str) -> bool {
        self.context
            .with(|ctx| ctx.globals().get::<_, Function>(func).is_ok())
    }

    fn call_hook(&self, func: &str) -> Result<(), String> {
        self.arm(CALL_BUDGET_MS);
        let r = self.context.with(|ctx| -> Result<(), String> {
            let f: Function = ctx.globals().get(func).map_err(|e| e.to_string())?;
            f.call::<_, Value>(())
                .catch(&ctx)
                .map(|_| ())
                .map_err(|e| format!("{func}: {e}"))
        });
        self.disarm();
        r
    }

    fn transform_lines(&self, lines: &[String], first_line_no: i64) -> JsTransformOut {
        self.arm(CALL_BUDGET_MS);
        let out = self.context.with(|ctx| -> Result<(Vec<String>, Vec<bool>), String> {
            let f: Function = ctx
                .globals()
                .get("transformLine")
                .map_err(|_| "script does not define transformLine(line, lineNo)".to_string())?;
            let mut out = Vec::with_capacity(lines.len());
            let mut deleted = Vec::with_capacity(lines.len());
            for (i, line) in lines.iter().enumerate() {
                let line_no = first_line_no + i as i64;
                // JS numbers are doubles anyway; line ordinals stay < 2^53.
                let r: Result<Value, _> = f.call((line.as_str(), line_no as f64));
                let v = r.catch(&ctx).map_err(|e| format!("line {line_no}: {e}"))?;
                if v.is_null() || v.is_undefined() {
                    out.push(line.clone()); // unchanged
                    deleted.push(false);
                } else if let Some(s) = v.as_string() {
                    out.push(s.to_string().map_err(|e| format!("line {line_no}: {e}"))?);
                    deleted.push(false);
                } else if v.as_bool() == Some(false) {
                    out.push(String::new());
                    deleted.push(true);
                } else {
                    return Err(format!(
                        "line {line_no}: transformLine returned {} (want string, null or false)",
                        v.type_name()
                    ));
                }
            }
            Ok((out, deleted))
        });
        self.disarm();
        match out {
            Ok((lines, deleted)) => JsTransformOut {
                lines,
                deleted,
                error: None,
            },
            Err(e) => JsTransformOut::err(e),
        }
    }

    fn transform_text(&self, text: &str) -> ScriptTextOut {
        self.runtime.set_memory_limit(text_memory_limit(text.len()));
        self.arm(text_budget_ms(text.len()));
        let out = self.context.with(|ctx| -> Result<Option<String>, String> {
            let f: Function = ctx
                .globals()
                .get("transformText")
                .map_err(|_| "script does not define transformText(text)".to_string())?;
            let r: Result<Value, _> = f.call((text,));
            let v = r.catch(&ctx).map_err(|e| e.to_string())?;
            if v.is_null() || v.is_undefined() {
                Ok(None)
            } else if let Some(s) = v.as_string() {
                Ok(Some(s.to_string().map_err(|e| e.to_string())?))
            } else {
                Err(format!(
                    "transformText returned {} (want string or null)",
                    v.type_name()
                ))
            }
        });
        self.disarm();
        self.runtime.set_memory_limit(MEMORY_LIMIT);
        match out {
            Ok(text) => ScriptTextOut { text, error: None },
            Err(e) => ScriptTextOut {
                text: None,
                error: Some(e),
            },
        }
    }
}

// Run [f] with this thread's context for script [name], (re)building it when
// missing or when the registered source changed since it was built. Used by
// registration (compile check) only; runs go through sessions.
fn with_script<R>(name: &str, f: impl FnOnce(Result<&ScriptCtx, String>) -> R) -> R {
    let Some(src) = js_source(name) else {
        return f(Err(format!("script not registered: {name}")));
    };
    SCRIPT_CACHE.with(|cache| {
        let mut map = cache.borrow_mut();
        let stale = map
            .get(name)
            .map(|c| !Arc::ptr_eq(&c.source, &src) && *c.source != *src)
            .unwrap_or(true);
        if stale {
            match build_ctx(src) {
                Ok(c) => {
                    map.insert(name.to_string(), c);
                }
                Err(e) => {
                    map.remove(name); // do not cache failures: source may be re-registered fixed
                    return f(Err(e));
                }
            }
        }
        f(Ok(map.get(name).expect("just inserted")))
    })
}

/// Register (or re-register) a user script under [name]. The source is compiled
/// once here to surface syntax errors / a missing contract function
/// immediately. Returns the error message, or `None` on success.
#[frb(sync)]
pub fn js_register_script(name: String, source: String) -> Option<String> {
    if let Ok(mut m) = script_sources().lock() {
        m.insert(name.clone(), Arc::new(source));
    }
    with_script(&name, |c| c.err())
}

/// Drop scripts that are no longer installed (called after a rescan).
#[frb(sync)]
pub fn js_retain_scripts(names: Vec<String>) {
    if let Ok(mut m) = script_sources().lock() {
        m.retain(|k, _| names.iter().any(|n| n == k));
    }
    SCRIPT_CACHE.with(|cache| {
        cache.borrow_mut().retain(|k, _| names.iter().any(|n| n == k));
    });
}

// ─────────────────────────────────────────────────────────────────────────────
// Sessions: one dedicated thread per run, owning the engine.
// ─────────────────────────────────────────────────────────────────────────────

enum Req {
    Lines(Vec<String>, i64, Sender<JsTransformOut>),
    Text(String, Sender<ScriptTextOut>),
    Close,
}

fn sessions() -> &'static Mutex<HashMap<i64, Sender<Req>>> {
    static S: OnceLock<Mutex<HashMap<i64, Sender<Req>>>> = OnceLock::new();
    S.get_or_init(|| Mutex::new(HashMap::new()))
}

static NEXT_ID: AtomicI64 = AtomicI64::new(1);

// Hook names per engine (Lua cannot use `end`).
fn hook_names(engine: &str) -> (&'static str, &'static str) {
    if engine == "lua" {
        ("begin_transform", "end_transform")
    } else {
        ("beginTransform", "endTransform")
    }
}
fn contract_names(engine: &str) -> (&'static str, &'static str) {
    if engine == "lua" {
        ("transform_line", "transform_text")
    } else {
        ("transformLine", "transformText")
    }
}

/// Open a run of script [name] on [engine] ("js" | "lua"): builds a fresh
/// engine instance on its own thread, evaluates the script and calls its
/// begin hook. On success the returned id serves [script_session_transform_lines]
/// / [script_session_transform_text] until [script_session_close]. Runs on a
/// worker thread (the build can take a moment).
pub fn script_session_open(engine: String, name: String) -> ScriptOpen {
    let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
    let (tx, rx) = channel::<Req>();
    let (otx, orx) = channel::<ScriptOpen>();
    let (begin_hook, end_hook) = hook_names(&engine);
    let (line_fn, text_fn) = contract_names(&engine);
    let engine_name = engine.clone();
    let spawned = std::thread::Builder::new()
        .name(format!("script-{name}"))
        .spawn(move || {
            let built: Result<Box<dyn Runner>, String> = if engine_name == "lua" {
                super::lua_script::build_runner(&name)
            } else {
                match js_source(&name) {
                    None => Err(format!("script not registered: {name}")),
                    Some(src) => build_ctx(src).map(|c| Box::new(c) as Box<dyn Runner>),
                }
            };
            let runner = match built {
                Ok(r) => r,
                Err(e) => {
                    let _ = otx.send(ScriptOpen {
                        id,
                        has_line: false,
                        has_text: false,
                        error: Some(e),
                    });
                    return;
                }
            };
            if runner.has(begin_hook) {
                if let Err(e) = runner.call_hook(begin_hook) {
                    let _ = otx.send(ScriptOpen {
                        id,
                        has_line: false,
                        has_text: false,
                        error: Some(e),
                    });
                    return;
                }
            }
            let _ = otx.send(ScriptOpen {
                id,
                has_line: runner.has(line_fn),
                has_text: runner.has(text_fn),
                error: None,
            });
            for req in rx {
                match req {
                    Req::Lines(lines, first, reply) => {
                        let _ = reply.send(runner.transform_lines(&lines, first));
                    }
                    Req::Text(text, reply) => {
                        let _ = reply.send(runner.transform_text(&text));
                    }
                    Req::Close => break,
                }
            }
            if runner.has(end_hook) {
                let _ = runner.call_hook(end_hook); // best effort at teardown
            }
        });
    if let Err(e) = spawned {
        return ScriptOpen {
            id,
            has_line: false,
            has_text: false,
            error: Some(format!("cannot start script thread: {e}")),
        };
    }
    let open = orx.recv().unwrap_or(ScriptOpen {
        id,
        has_line: false,
        has_text: false,
        error: Some("script thread died".to_string()),
    });
    if open.error.is_none() {
        if let Ok(mut s) = sessions().lock() {
            s.insert(id, tx);
        }
    }
    open
}

fn session_sender(id: i64) -> Option<Sender<Req>> {
    sessions().lock().ok().and_then(|s| s.get(&id).cloned())
}

/// Run the line contract over [lines] on session [id]; [first_line_no] is the
/// 1-based ordinal of `lines[0]` within the processed range. Runs on a worker
/// thread (it blocks until the session thread answers).
// first_line_no is i64 (not u64) so it maps to a plain Dart int across FRB.
pub fn script_session_transform_lines(
    id: i64,
    lines: Vec<String>,
    first_line_no: i64,
) -> JsTransformOut {
    let Some(tx) = session_sender(id) else {
        return JsTransformOut::err("script session is closed".to_string());
    };
    let (rtx, rrx) = channel();
    if tx.send(Req::Lines(lines, first_line_no, rtx)).is_err() {
        return JsTransformOut::err("script session is gone".to_string());
    }
    rrx.recv()
        .unwrap_or_else(|_| JsTransformOut::err("script session died".to_string()))
}

/// Run the whole-text contract on session [id] (the Dart side caps the size).
pub fn script_session_transform_text(id: i64, text: String) -> ScriptTextOut {
    let Some(tx) = session_sender(id) else {
        return ScriptTextOut {
            text: None,
            error: Some("script session is closed".to_string()),
        };
    };
    let (rtx, rrx) = channel();
    if tx.send(Req::Text(text, rtx)).is_err() {
        return ScriptTextOut {
            text: None,
            error: Some("script session is gone".to_string()),
        };
    }
    rrx.recv().unwrap_or_else(|_| ScriptTextOut {
        text: None,
        error: Some("script session died".to_string()),
    })
}

/// End session [id]: the end hook runs and the engine thread exits.
#[frb(sync)]
pub fn script_session_close(id: i64) {
    let tx = sessions().lock().ok().and_then(|mut s| s.remove(&id));
    if let Some(tx) = tx {
        let _ = tx.send(Req::Close);
    }
}

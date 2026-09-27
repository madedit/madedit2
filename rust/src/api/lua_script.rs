// Lua backend for user text-transform scripts (mlua / vendored Lua 5.4).
//
// Same host contract as the QuickJS backend (script.rs), Lua-flavored:
// a script (settings/scripts/*.lua) defines one or both of
//   transform_line(line, line_no) -> string | nil | false
//   transform_text(text)          -> string | nil
// plus optional begin_transform() / end_transform() hooks. nil leaves the
// line unchanged and false deletes it. Runs go through the engine-agnostic
// sessions in script.rs (a dedicated thread per run owning this VM, so
// script globals persist across chunks); this file only builds the VM and
// implements [Runner] for it. Sandbox: only the pure stdlib subset is loaded
// (no io/os/debug/package); an instruction-count hook enforces the wall-clock
// deadline and the VM has a memory limit — both scaled up for a whole-text call.

use std::cell::RefCell;
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Instant;

use flutter_rust_bridge::frb;
use mlua::{Function, Lua, LuaOptions, StdLib, Value, VmState};

use super::script::{
    text_budget_ms, text_memory_limit, JsTransformOut, Runner, ScriptTextOut, CALL_BUDGET_MS,
    MEMORY_LIMIT,
};

fn lua_sources() -> &'static Mutex<HashMap<String, Arc<String>>> {
    static SRC: OnceLock<Mutex<HashMap<String, Arc<String>>>> = OnceLock::new();
    SRC.get_or_init(|| Mutex::new(HashMap::new()))
}

#[frb(ignore)]
struct LuaCtx {
    lua: Lua,
    source: Arc<String>,
    // Deadline for the timeout hook, in ms since `epoch` (0 = no deadline).
    deadline_ms: Arc<AtomicU64>,
    epoch: Instant,
}

thread_local! {
    static LUA_CACHE: RefCell<HashMap<String, LuaCtx>> = RefCell::new(HashMap::new());
}

fn build_ctx(source: Arc<String>) -> Result<LuaCtx, String> {
    // Pure-computation stdlib only: no io/os/package/debug (sandbox).
    let libs = StdLib::STRING | StdLib::TABLE | StdLib::MATH | StdLib::UTF8;
    let lua = Lua::new_with(libs, LuaOptions::default()).map_err(|e| e.to_string())?;
    lua.set_memory_limit(MEMORY_LIMIT).map_err(|e| e.to_string())?;
    let epoch = Instant::now();
    let deadline_ms = Arc::new(AtomicU64::new(0));
    {
        let deadline = Arc::clone(&deadline_ms);
        // Check the deadline every N VM instructions; erroring from the hook
        // aborts the running script with a catchable error.
        // No hook = no timeout guard, so failing to install it fails the build.
        lua.set_hook(
            mlua::HookTriggers::new().every_nth_instruction(100_000),
            move |_lua, _debug| {
                let d = deadline.load(Ordering::Relaxed);
                if d != 0 && epoch.elapsed().as_millis() as u64 > d {
                    Err(mlua::Error::RuntimeError("script interrupted (timeout)".into()))
                } else {
                    Ok(VmState::Continue)
                }
            },
        )
        .map_err(|e| e.to_string())?;
    }
    lua.load(source.as_str())
        .exec()
        .map_err(|e| e.to_string())?;
    let line: Result<Function, _> = lua.globals().get("transform_line");
    let text: Result<Function, _> = lua.globals().get("transform_text");
    if line.is_err() && text.is_err() {
        return Err(
            "script defines neither transform_line(line, line_no) nor transform_text(text)"
                .to_string(),
        );
    }
    Ok(LuaCtx {
        lua,
        source,
        deadline_ms,
        epoch,
    })
}

#[frb(ignore)]
impl LuaCtx {
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

fn lua_string(v: &mlua::LuaString, what: &str) -> Result<String, String> {
    v.to_str()
        .map(|s| s.to_owned())
        .map_err(|_| format!("{what}: returned string is not valid UTF-8"))
}

#[frb(ignore)]
impl Runner for LuaCtx {
    fn has(&self, func: &str) -> bool {
        self.lua.globals().get::<Function>(func).is_ok()
    }

    fn call_hook(&self, func: &str) -> Result<(), String> {
        self.arm(CALL_BUDGET_MS);
        let r = (|| -> Result<(), String> {
            let f: Function = self.lua.globals().get(func).map_err(|e| e.to_string())?;
            f.call::<Value>(()).map(|_| ()).map_err(|e| format!("{func}: {e}"))
        })();
        self.disarm();
        r
    }

    fn transform_lines(&self, lines: &[String], first_line_no: i64) -> JsTransformOut {
        self.arm(CALL_BUDGET_MS);
        let out = (|| -> Result<(Vec<String>, Vec<bool>), String> {
            let f: Function = self
                .lua
                .globals()
                .get("transform_line")
                .map_err(|_| "script does not define transform_line(line, line_no)".to_string())?;
            let mut out = Vec::with_capacity(lines.len());
            let mut deleted = Vec::with_capacity(lines.len());
            for (i, line) in lines.iter().enumerate() {
                let line_no = first_line_no + i as i64;
                let r: Result<Value, _> = f.call((line.as_str(), line_no));
                match r {
                    Ok(Value::Nil) => {
                        out.push(line.clone()); // nil = unchanged
                        deleted.push(false);
                    }
                    Ok(Value::String(s)) => {
                        out.push(lua_string(&s, &format!("line {line_no}"))?);
                        deleted.push(false);
                    }
                    Ok(Value::Boolean(false)) => {
                        out.push(String::new());
                        deleted.push(true);
                    }
                    Ok(v) => {
                        return Err(format!(
                            "line {line_no}: transform_line returned {} (want string, nil or false)",
                            v.type_name()
                        ))
                    }
                    Err(e) => return Err(format!("line {line_no}: {e}")),
                }
            }
            Ok((out, deleted))
        })();
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
        let _ = self.lua.set_memory_limit(text_memory_limit(text.len()));
        self.arm(text_budget_ms(text.len()));
        let out = (|| -> Result<Option<String>, String> {
            let f: Function = self
                .lua
                .globals()
                .get("transform_text")
                .map_err(|_| "script does not define transform_text(text)".to_string())?;
            match f.call::<Value>((text,)).map_err(|e| e.to_string())? {
                Value::Nil => Ok(None),
                Value::String(s) => Ok(Some(lua_string(&s, "transform_text")?)),
                v => Err(format!(
                    "transform_text returned {} (want string or nil)",
                    v.type_name()
                )),
            }
        })();
        self.disarm();
        let _ = self.lua.set_memory_limit(MEMORY_LIMIT);
        match out {
            Ok(text) => ScriptTextOut { text, error: None },
            Err(e) => ScriptTextOut {
                text: None,
                error: Some(e),
            },
        }
    }
}

/// Build a fresh VM for the registered script [name] (called on the session
/// thread that will own it).
#[frb(ignore)]
pub(crate) fn build_runner(name: &str) -> Result<Box<dyn Runner>, String> {
    let src = lua_sources()
        .lock()
        .ok()
        .and_then(|m| m.get(name).cloned())
        .ok_or_else(|| format!("script not registered: {name}"))?;
    build_ctx(src).map(|c| Box::new(c) as Box<dyn Runner>)
}

// Compile check for registration on the calling thread (cached per thread,
// rebuilt when the registered source changed).
fn with_script<R>(name: &str, f: impl FnOnce(Result<&LuaCtx, String>) -> R) -> R {
    let src = lua_sources()
        .lock()
        .ok()
        .and_then(|m| m.get(name).cloned());
    let Some(src) = src else {
        return f(Err(format!("script not registered: {name}")));
    };
    LUA_CACHE.with(|cache| {
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

/// Register (or re-register) a Lua user script under [name]; compiles right
/// here so syntax errors / a missing contract function surface immediately.
/// Returns the error message, or `None` on success.
#[frb(sync)]
pub fn lua_register_script(name: String, source: String) -> Option<String> {
    if let Ok(mut m) = lua_sources().lock() {
        m.insert(name.clone(), Arc::new(source));
    }
    with_script(&name, |c| c.err())
}

/// Drop Lua scripts that are no longer installed (called after a rescan).
#[frb(sync)]
pub fn lua_retain_scripts(names: Vec<String>) {
    if let Ok(mut m) = lua_sources().lock() {
        m.retain(|k, _| names.iter().any(|n| n == k));
    }
    LUA_CACHE.with(|cache| {
        cache.borrow_mut().retain(|k, _| names.iter().any(|n| n == k));
    });
}

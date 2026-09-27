#[flutter_rust_bridge::frb(sync)] // Synchronous mode for simplicity of the demo
pub fn greet(name: String) -> String {
    format!("Hello, {name}!")
}

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    // Default utilities - feel free to customize
    flutter_rust_bridge::setup_default_user_utils();
    // ...but NOT at its Trace level. On macOS `setup_default_user_utils` installs an
    // `oslog` logger with max_level = Trace, which makes every `log::trace!` in our
    // dependencies actually format and emit a record. Cranelift traces every machine
    // instruction it emits, so compiling one tree-sitter wasm grammar went from ~0.14 s
    // to ~18.6 s (measured: markdown, 411 KB wasm) — the whole app froze on opening a
    // .md file. Warn keeps real problems visible and costs one atomic load per trace!.
    log::set_max_level(log::LevelFilter::Warn);
}

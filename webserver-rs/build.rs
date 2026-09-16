// Captures the actual rustc version used to compile this crate (there's
// no runtime API for that -- unlike Python's platform.python_version(),
// which asks the interpreter running *now*, this target is compiled
// ahead of time). Runs on the host as an ordinary native binary, like
// any build script; RUSTC is the exact compiler cargo is using for this
// build (including the pinned nightly build-rust-app.sh selects via
// `cargo +<toolchain>`), set by cargo itself for every build script.
fn main() {
    let rustc = std::env::var("RUSTC").unwrap_or_else(|_| "rustc".to_string());
    let version = std::process::Command::new(rustc)
        .arg("--version")
        .output()
        .ok()
        .filter(|o| o.status.success())
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .unwrap_or_else(|| "unknown".to_string());
    println!("cargo:rustc-env=RUSTC_VERSION={}", version.trim());
}

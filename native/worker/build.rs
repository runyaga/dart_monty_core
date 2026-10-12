//! Link arguments for the two cdylib forms.
use std::env;

fn main() {
    let os = env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    if os == "macos" {
        // Loadable from beside the relaunched executable.
        println!("cargo:rustc-cdylib-link-arg=-Wl,-install_name,@rpath/libdart_monty_worker.dylib");
        println!("cargo:rustc-cdylib-link-arg=-Wl,-headerpad_max_install_names");
    }
    if env::var("CARGO_CFG_TARGET_ARCH").as_deref() == Ok("wasm32") {
        // 2 MiB shadow stack: the interpreter's recursive `==`/`repr` need it.
        println!("cargo:rustc-cdylib-link-arg=-zstack-size={}", 2 * 1024 * 1024);
    }
}

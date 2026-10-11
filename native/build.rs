fn main() {
    // Ensure macOS dylibs use @rpath instead of absolute build paths.
    // Without this, cargo emits install_name = /full/build/path/libdart_monty_core_native.dylib
    // which causes dyld failures on consumer machines. See #47.
    let target_os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    if target_os == "macos" {
        println!(
            "cargo:rustc-cdylib-link-arg=-Wl,-install_name,@rpath/libdart_monty_core_native.dylib"
        );
        // Ensure enough header space for Dart's install_name_tool to rewrite paths.
        println!("cargo:rustc-cdylib-link-arg=-Wl,-headerpad_max_install_names");
    }

    // The wasm32 stack is a linker setting, 1 MiB by default, and it lives in
    // linear memory: run past it and the module traps with "memory access out
    // of bounds", which also poisons the instance for every later call. rustc
    // 1.99 codegen spends more stack per level than 1.98 did, and on 1 MiB the
    // output-depth case `nesting 400 deep is not truncated on any backend`
    // started trapping. 2 MiB is the size already chosen for the web build.
    // The native counterpart is `error::interpreter_stack`.
    if std::env::var("CARGO_CFG_TARGET_ARCH").as_deref() == Ok("wasm32") {
        println!(
            "cargo:rustc-cdylib-link-arg=-zstack-size={}",
            2 * 1024 * 1024
        );
    }
}

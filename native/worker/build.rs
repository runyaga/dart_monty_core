//! Link arguments for the two cdylib forms.
use std::{env, fs, path::PathBuf};

fn main() {
    let os = env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    if os == "macos" {
        // Loadable from beside the relaunched executable.
        println!("cargo:rustc-cdylib-link-arg=-Wl,-install_name,@rpath/libdart_monty_worker.dylib");
        println!("cargo:rustc-cdylib-link-arg=-Wl,-headerpad_max_install_names");
    }
    if os == "linux" && env::var("CARGO_CFG_TARGET_ENV").as_deref() == Ok("gnu") {
        // Links the unwinder statically: images built on Dart's /runtime/ have no libgcc_s.so.1.
        // rustc passes -lgcc_s itself, so a libgcc_s.a linker script redirects it to libgcc_eh.
        let shim = PathBuf::from(env::var("OUT_DIR").unwrap()).join("static-libgcc");
        fs::create_dir_all(&shim).unwrap();
        fs::write(shim.join("libgcc_s.a"), "INPUT(-lgcc_eh)\n").unwrap();
        println!("cargo:rustc-link-search=native={}", shim.display());
        println!("cargo:rustc-link-arg=-static-libgcc");
    }
    if env::var("CARGO_CFG_TARGET_ARCH").as_deref() == Ok("wasm32") {
        // 2 MiB shadow stack: the interpreter's recursive `==`/`repr` need it.
        println!("cargo:rustc-cdylib-link-arg=-zstack-size={}", 2 * 1024 * 1024);
    }
}

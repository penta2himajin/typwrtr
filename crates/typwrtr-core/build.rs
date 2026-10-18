fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        println!("cargo:rustc-cdylib-link-arg=-Wl,-install_name,@rpath/libtypwrtr_core.dylib");
        // euhadra `fluidaudio` links FluidAudio's Swift concurrency runtime via
        // @rpath. Every artifact here (dylib, tests, uniffi-bindgen) needs the OS copy.
        println!("cargo:rustc-link-arg=-Wl,-rpath,/usr/lib/swift");
    }
}

//! Measure FluidAudio Parakeet-ja load time (first load compiles for the ANE).
//! Usage: cargo run --release -p typwrtr-core --example fluidaudio_load -- <pack dir>
fn main() {
    let dir = std::env::args().nth(1).expect("pack dir");
    for attempt in 1..=2 {
        let started = std::time::Instant::now();
        let engine = typwrtr_core::DictationEngine::with_fluidaudio_ja(
            typwrtr_core::Language::Japanese,
            &dir,
        );
        println!(
            "load {attempt}: {} ms ok={}",
            started.elapsed().as_millis(),
            engine.is_ok()
        );
        if let Err(e) = engine {
            println!("  error: {}", e.message());
        }
    }
}

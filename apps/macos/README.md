# macOS shell (Swift)

Menu-bar app: hotkeys, Accessibility / clipboard insertion, wizard (later).

## Bindings

`typwrtr-core` exposes UniFFI (`PttSession`, etc.). After:

```bash
cargo build -p typwrtr-core
```

generate Swift with library-mode bindgen against the built `libtypwrtr_core.dylib` / `.a` (see [UniFFI foreign bindings](https://mozilla.github.io/uniffi-rs/latest/tutorial/foreign_language_bindings.html)).

Dogfood without models: `PttSession.with_fixed_transcript(language:fixedTranscript:)`.

See `docs/architecture.md`.

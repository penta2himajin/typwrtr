# Typwrtr

[日本語](./README.ja.md)

Local-first voice dictation for macOS. Hold a hotkey, speak, release — cleaned text goes into the focused field.

Named by dropping the vowels from “typewriter”.

## Status

Early product definition + PTT architecture. Decisions: [`docs/product.md`](./docs/product.md). UX: [`docs/ux-decisions.md`](./docs/ux-decisions.md). Architecture: [`docs/architecture.md`](./docs/architecture.md). Use cases: [`docs/use-cases.md`](./docs/use-cases.md).

Speech recognition and text cleanup are provided by **[euhadra](https://github.com/penta2himajin/euhadra)** (programmable ASR framework). This repository is the end-user application (Swift shell + Rust/UniFFI core).

## Principles (short)

- **Local by default** — no cloud account required for the main path  
- **Source free** — MIT / Apache-2.0 (aligned with euhadra)  
- **Official build $5** — notarised `.dmg` via Gumroad; unlimited re-downloads; no in-app accounts or license checks  
- **Native shell** — Swift on macOS (WinUI later on Windows)

## Layout

```
docs/                  # Product, UX, architecture
crates/typwrtr-core/   # Rust session core (euhadra)
apps/macos/            # Swift menu-bar shell (forthcoming Xcode project)
scripts/fetch-models.sh
AGENTS.md
```

## License

MIT. See `LICENSE`. SPDX may gain Apache-2.0 dual-licensing to match published [euhadra](https://crates.io/crates/euhadra).

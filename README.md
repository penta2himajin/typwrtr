# Typwrtr

[日本語](./README.ja.md)

Local-first voice dictation for macOS. Hold a hotkey, speak, release — cleaned text goes into the focused field.

Named by dropping the vowels from “typewriter”.

## Status

Early product definition. Decisions: [`docs/product.md`](./docs/product.md). UX: [`docs/ux-decisions.md`](./docs/ux-decisions.md). Use cases: [`docs/use-cases.md`](./docs/use-cases.md).

Speech recognition and text cleanup are provided by **[euhadra](https://github.com/penta2himajin/euhadra)** (programmable ASR framework). This repository is the end-user application (Swift shell + Rust/UniFFI core).

## Principles (short)

- **Local by default** — no cloud account required for the main path  
- **Source free** — MIT / Apache-2.0 (aligned with euhadra)  
- **Official build $5** — notarised `.dmg` via Gumroad; unlimited re-downloads; no in-app accounts or license checks  
- **Native shell** — Swift on macOS (WinUI later on Windows)

## Layout

```
docs/           # Product decisions, use cases, handoff / i18n policy
git-hooks/      # Optional pre-push format / lint hooks
AGENTS.md       # Agent / contributor working rules
```

Application sources (Rust core, Swift macOS target) will land as implementation starts.

## License

MIT. See `LICENSE`. SPDX may gain Apache-2.0 dual-licensing to match published [euhadra](https://crates.io/crates/euhadra).

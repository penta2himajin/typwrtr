# macOS shell (Swift)

Menu-bar dogfood app: `⌥V` PTT → FixedAsr + euhadra Tier 1+2 → clipboard paste.

## Prerequisites

- Xcode 15+
- Rust toolchain
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Setup

```bash
# From repo root
cargo build -p typwrtr-core          # writes target/debug/libtypwrtr_core.*
./scripts/generate-swift.sh          # refreshes apps/macos/Generated
cd apps/macos
xcodegen generate
open Typwrtr.xcodeproj
```

Or build from CLI:

```bash
cd apps/macos && xcodegen generate
xcodebuild -scheme Typwrtr -configuration Debug build
```

## Dogfood notes

- Uses `PttSession.withFixedTranscript` (no on-disk ASR model yet).
- **Microphone is real:** hold **Left Option + V** to record; release → samples (16 kHz mono) are pushed into core, cleaned text is pasted.
- Menu shows **Last capture: N samples** so you can verify the mic path before real ASR.
- Grant **Microphone** and **Accessibility** when prompted.
- Menu bar title: `Tw` idle / `●Tw` recording / `…Tw` processing / `!Tw` error.

See `docs/architecture.md` and `docs/ux-decisions.md`.

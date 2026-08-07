# macOS shell (Swift)

Menu-bar dogfood app: `⌃⇧D` PTT → Parakeet-ja (or WhisperLocal / FixedAsr) + euhadra Tier 1+2 → insert.


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

- **ASR:** Parakeet-ja ONNX first (`TYPWRTR_PARAKEET_JA_DIR` / `models/parakeet-tdt_ctc-0.6b-ja`), then WhisperLocal, then FixedAsr.
- Setup from repo root:

```bash
./scripts/fetch-models.sh parakeet-ja   # ~2.4 GB; prints TYPWRTR_PARAKEET_JA_DIR
# optional Whisper fallback:
./scripts/fetch-models.sh whisper-tiny
export TYPWRTR_ROOT="$PWD"
```

- **Microphone is real:** hold **Control + Shift + D**; release → 16 kHz mono PCM → ASR → insert (AX / unicode / ⌘V).
- Chord is swallowed. Needs **Accessibility** for the event tap + paste.
- Menu shows ASR backend and **Last capture** sample counts.
- Grant **Microphone** and **Accessibility** when prompted. Prefer signing with `Typwrtr Dogfood` (`scripts/create-dogfood-cert.sh`) so TCC survives rebuilds.

## Launch (CLI dogfood)

```bash
# From repo root
cd apps/macos
xcodegen generate
xcodebuild -scheme Typwrtr -configuration Release -derivedDataPath ./DerivedData build
mkdir -p ~/Applications
rm -rf ~/Applications/Typwrtr.app
cp -R DerivedData/Build/Products/Release/Typwrtr.app ~/Applications/
mkdir -p ~/Applications/Typwrtr.app/Contents/Frameworks
cp -f ../../target/debug/libtypwrtr_core.dylib ~/Applications/Typwrtr.app/Contents/Frameworks/
codesign --force --deep --sign - ~/Applications/Typwrtr.app
open ~/Applications/Typwrtr.app
```

**Expected UI:** a **mic icon on the right** of the menu bar (near Wi‑Fi / clock), not the left-side app name. That icon stays while you work in Notes/Slack/etc. Hold **⌃⇧D** to dictate.

Also grant **Microphone**, **Input Monitoring** (for ⌃⇧D), and **Accessibility** (paste / swallow). After each ad-hoc rebuild, re-check those toggles — macOS treats a re-signed binary as a new app.


See `docs/architecture.md` and `docs/ux-decisions.md`.

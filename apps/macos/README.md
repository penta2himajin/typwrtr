# macOS shell (Swift)

Menu-bar dogfood app: `⌃⇧D` PTT → WhisperLocal (or FixedAsr) + euhadra Tier 1+2 → clipboard paste.

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

- **ASR:** uses WhisperLocal when `TYPWRTR_WHISPER_CLI` + model files exist; otherwise FixedAsr fallback.
- Setup once from repo root:

```bash
./scripts/fetch-models.sh whisper-tiny
# exports printed — or:
export TYPWRTR_ROOT="$PWD"
export TYPWRTR_WHISPER_CLI="$PWD/vendor/whisper.cpp/build/bin/whisper-cli"
export TYPWRTR_WHISPER_MODEL_DIR="$PWD/models/whisper"
```

- **Microphone is real:** hold **Control + Shift + D**; release → 16 kHz mono PCM → ASR → clipboard paste.
- Chord is swallowed. Needs **Accessibility** for the event tap + paste.
- Menu shows ASR backend and **Last capture** sample counts.
- Grant **Microphone** and **Accessibility** when prompted.

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

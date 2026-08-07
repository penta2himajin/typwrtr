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

- **ASR:** euhadra L1 packs — **ja** Parakeet-ja, **en/es** Canary-180M-Flash, **zh** Paraformer, **ko** SenseVoice. Choose Language in Setup; models are selected automatically.
- Model discovery (no `open --env` required): UserDefaults → env → `~/Library/Application Support/Typwrtr/models/<pack>` → `~/repos/typwrtr/models/...`.
- Setup from repo root:

```bash
./scripts/fetch-models.sh parakeet-ja   # Japanese (~2.4 GB)
./scripts/fetch-models.sh canary        # English + Spanish (~213 MB INT8)
./scripts/fetch-models.sh paraformer-zh # Chinese (~238 MB)
./scripts/fetch-models.sh sensevoice-ko # Korean (needs EUHADRA_ROOT + Python)
```

- **Onboarding (dogfood):** shared **Setup** dialog on first incomplete launch and from menu **Setup…** (language, permissions, language-pack install, launch-at-login). Users choose **Language**; models are selected automatically. **Debug** submenu has Last capture / backend / model folder.
- **Microphone is real:** hold **Control + Shift + D**; release → 16 kHz mono PCM → ASR → insert (AX / unicode / ⌘V).
- Chord is swallowed. Needs **Accessibility** for the event tap + paste.
- Menu shows ASR backend and **Last capture** sample counts.
- Grant **Microphone** and **Accessibility** when prompted. Prefer signing with `Typwrtr Dogfood` (`scripts/create-dogfood-cert.sh`) so TCC survives rebuilds.

## Launch (CLI dogfood)

```bash
# From repo root
./scripts/create-dogfood-cert.sh   # once
cd apps/macos
xcodegen generate
xcodebuild -scheme Typwrtr -configuration Release -derivedDataPath ./DerivedData \
  CODE_SIGN_IDENTITY="Typwrtr Dogfood" CODE_SIGNING_REQUIRED=YES build
mkdir -p ~/Applications
rm -rf ~/Applications/Typwrtr.app
cp -R DerivedData/Build/Products/Release/Typwrtr.app ~/Applications/
mkdir -p ~/Applications/Typwrtr.app/Contents/Frameworks
cp -f ../../target/debug/libtypwrtr_core.dylib ~/Applications/Typwrtr.app/Contents/Frameworks/
codesign --force --deep --sign "Typwrtr Dogfood" ~/Applications/Typwrtr.app
open ~/Applications/Typwrtr.app
```

**Expected UI:** a **mic icon on the right** of the menu bar (near Wi‑Fi / clock), not the left-side app name. That icon stays while you work in Notes/Slack/etc. Hold **⌃⇧D** to dictate.

Also grant **Microphone**, **Input Monitoring** (for ⌃⇧D), and **Accessibility** (paste / swallow). With the Dogfood identity, rebuilds usually keep TCC grants; after switching identities, re-check those toggles.


See `docs/architecture.md` and `docs/ux-decisions.md`.

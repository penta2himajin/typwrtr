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

- **ASR:** euhadra L1 packs — **ja** Parakeet-ja, **en/es** Canary-180M-Flash, **zh** Paraformer, **ko** Dolphin small CTC. Choose Language in Setup; models are selected automatically.
- Model discovery (no `open --env` required): UserDefaults → env → `~/Library/Application Support/Typwrtr/models/<pack>` → `~/repos/typwrtr/models/...`.
- Setup from repo root:

```bash
./scripts/fetch-models.sh parakeet-ja   # Japanese (~2.4 GB)
./scripts/fetch-models.sh canary        # English + Spanish (~213 MB INT8)
./scripts/fetch-models.sh paraformer-zh # Chinese (~238 MB)
./scripts/fetch-models.sh dolphin-ko     # Korean (curl-only INT8 CTC)
```

- **Onboarding (dogfood):** shared **Setup** dialog on first incomplete launch and from menu **Setup…** (language, permissions, language-pack install, launch-at-login). Users choose **Language**; models are selected automatically. **Debug** submenu has Last capture / backend / model folder.
- **Microphone is real:** hold **Control + Shift + D**; release → 16 kHz mono PCM → ASR → insert (AX / unicode / ⌘V).
- Chord is swallowed. Needs **Accessibility** for the event tap + paste.
- Menu shows ASR backend and **Last capture** sample counts.
- Grant **Microphone** and **Accessibility** when prompted. Install with `scripts/install-dogfood.sh` so the `Typwrtr Dogfood` signature — and with it the TCC grants — survives rebuilds ([why](#why-signing-decides-whether-permissions-stick)).

## Launch (CLI dogfood)

```bash
# From repo root
./scripts/create-dogfood-cert.sh   # once
./scripts/install-dogfood.sh       # build, install to ~/Applications, launch
```

Pass `--reset-permissions` to clear this app's TCC grants and be prompted again.
Only needed when the designated requirement changed — a new cert, or recovering
from an ad-hoc install — not on an ordinary rebuild.

**Expected UI:** a **mic icon on the right** of the menu bar (near Wi‑Fi / clock), not the left-side app name. That icon stays while you work in Notes/Slack/etc. Hold **⌃⇧D** to dictate.

Also grant **Microphone**, **Input Monitoring** (for ⌃⇧D), and **Accessibility** (paste / swallow).

### Why signing decides whether permissions stick

macOS records approval against the app's **designated requirement**, so how the
bundle is signed determines whether a rebuild keeps its grants:

| Signature | Designated requirement | Survives a rebuild |
|---|---|---|
| `Typwrtr Dogfood` | `identifier` + certificate leaf | **Yes** |
| ad-hoc (`--sign -`) | `cdhash` of that exact binary | No — changes every build |

An ad-hoc install therefore loses Accessibility on the next build, and System
Settings still lists a toggle that looks enabled while the tap does nothing. Never
re-sign the installed copy with `--sign -`; `install-dogfood.sh` copies with
`ditto` to keep the real signature and refuses to install an ad-hoc bundle. To
check by hand:

```bash
codesign -d --requirements - ~/Applications/Typwrtr.app   # expect identifier + certificate leaf
```


See `docs/architecture.md` and `docs/ux-decisions.md`.

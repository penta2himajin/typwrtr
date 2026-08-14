# Typwrtr — Architecture (PTT dogfood slice)

Status: **agreed** (2026-08-07).  
Product: [`product.md`](./product.md). UX: [`ux-decisions.md`](./ux-decisions.md). Use cases: [`use-cases.md`](./use-cases.md).

## 1. Goal of the first slice

Ship a **dogfoodable PTT path** on macOS Apple Silicon:

1. Hold default hotkey (`Control+Shift+D`) → record  
2. Release → euhadra cleanup → insert into focused field (AX, else clipboard+paste)  
3. Menu-bar icon shows idle / recording / processing / error  
4. Undo last (buffer-backed)  
5. Failure recovery per [`ux-decisions.md`](./ux-decisions.md) §7  

**Out of this slice:** Free/VAD (F3), first-run wizard UI (until step 6 below), Gumroad packaging, Windows.

Return to grilling when a product ambiguity blocks an API choice.

## 2. Repository layout

```
typwrtr/
  Cargo.toml                 # workspace
  crates/
    typwrtr-core/            # Rust library (+ UniFFI later)
  apps/
    macos/                   # Swift menu-bar app (Xcode project)
  scripts/
    fetch-models.sh          # Download curated ASR/cleanup models for dogfood
  docs/                      # Product + architecture SSOT
  tests/                     # Optional workspace-level fixtures later
```

- No IME target. Insertion lives in `apps/macos`.  
- `typwrtr-core` depends on crates.io **`euhadra` 0.3.x** with `default-features = false` and features **`onnx`** (ASR adapters) + **`vad`** (`EarshotVad`). `mic` stays off while capture lives in Swift.

## 3. Layer responsibilities

| Layer | Owns | Must not own |
|---|---|---|
| **apps/macos (Swift)** | Hotkeys, menu bar, permissions UX, AX insert, clipboard paste/restore, failure preview UI, Quit confirm, **dictionary Settings CRUD** | ASR models, filler/self-repair logic, match-policy folding |
| **typwrtr-core (Rust)** | Session state machine, calling euhadra, language + model paths, last-text buffer, undo payload, UniFFI API, **dictionary load / validate / engine rebuild** | AppKit / AX / NSStatusItem |
| **euhadra** | ASR + Tier 1/2 processors, **`TermDictionary` match behaviour** | Product UX, hotkeys, dictionary file format or bundled terms |

### Audio capture placement (dogfood)

**Decision for dogfood:** prefer capturing audio in **Swift** (or a thin macOS API) and passing PCM/WAV bytes into `typwrtr-core` for transcription, **or** using euhadra `mic` from Rust if that proves simpler in practice.  
First implementation should pick one path and document the choice in this file’s decision log when measured—not both.

Initial bias: **Swift records → core transcribes** so Accessibility / hotkey / mic permission stay in one process story. Revisit if euhadra `mic` + UniFFI streaming is cleaner.

### Voice activity detection placement (2026-08-09)

Detection is **listening accuracy**, so it belongs to euhadra. The Swift
`SilenceVad` (RMS threshold, wall-clock silence timer) was a local
reimplementation of that, and euhadra 0.3.0 replaced the reason it existed.
Adoption is two stages.

**Stage 1 — trimming, no FFI change.** `.vad(EarshotVad::new())` on the pipeline
built in `DictationEngine`. This covers **both** paths for free: Free finalises a
segment by calling `start_ptt` / `push_pcm_f32` / `stop_ptt`, so it funnels
through the same `dictate` as PTT. Free in fact carried the larger problem — its
mic opens on focus, so everything from mic-open to speech was reaching the
adapter.

- `FinalPass::SpeechOnly` (the default). `WholeUtterance` would leave the final
  text unchanged and defeat the purpose; `JoinSegments` measured worst.
- `SegmenterConfig::threshold` stays `None` so the backend calibrates it.
  `EarshotVad` wants 0.2; euhadra measured `EnergyVad`'s 0.5 applied to it as
  **worse than no detector at all**. Do not hardcode a threshold here.
- `min_silence` = 1500ms for Focus Dictation / Free pipeline dictate to match today's behaviour ([`ux-decisions.md`](./ux-decisions.md) Q25). Streaming PTT live endpointing uses euhadra `SegmenterConfig::default()` (700ms) via `StreamListen`, not the shell energy timer.
- A capture with no speech now yields `PipelineError::NoSpeech` where an ASR
  hallucination used to be returned. The core turns that into an **empty
  successful result** — `stop_ptt` returns `""`, status goes to idle, and the text
  buffer stays empty because there is nothing for Undo to reverse. No new FFI
  error variant: Swift's existing empty-text branch already covers Q24 for both
  paths, and euhadra makes no distinction between "detector found no speech" and
  "adapter returned nothing" anyway (both are `NoSpeech`).
- A dead microphone would therefore also be silent. That is what the Q27
  measurement is for: pushed samples against detected speech duration shows it.
- `Dictated::speech_samples` **clamps segment bounds to the buffer and merges
  overlaps**. Bounds carry `speech_pad` either side, so on a capture that is
  speech end to end they extend past the audio; summing lengths reported 1.15×
  the recording in the first dogfood run. `speech_coverage` in `engine.rs` owns
  this, and `speech_never_exceeds_the_audio_handed_in` pins it.
- Measured on PTT (2026-08-09): 0.00–0.07s trimmed from captures of 1.19–2.09s.
  Trimming on this path is bounded by the 200ms `speech_pad` — silence inside the
  pad is kept on purpose — so it is negligible whatever the speaker does. Stage
  1's value is concentrated in Free, as expected above, and Free is unmeasured
  until stage 2.

**Stage 2 — endpointing moves into the core.** `Segmenter` + `VadStream` + the
rolling buffer live on `PttSession`, which already owns the engine and the Tokio
runtime; `FreeController` stays pure policy with no audio. The UniFFI addition is
a **synchronous** Free lifecycle (see §4) — deliberately no callback interface and
no async, because incremental output is deferred, and `Segmenter::push` is itself
synchronous. Swift becomes a pump: hand over samples, act on the returned event.

**Streaming PTT + Focus Dictation (2026-08-11):** Stage 2 surface is live for
**Push to talk (streaming)** and **Focus Dictation** (`start_stream_listen` /
`start_focus_listen` / `push_stream_pcm_f32` / `take_stream_segment` /
`stop_stream_listen`). Live endpointing is **`EarshotVad` + `Segmenter`** with
threshold **0.42** (measured −45 dBFS room tone peaked ~0.37, which reset the
rlx-vad 0.35 silence run; euhadra’s 0.2 WER calibration under-closed on laptop
room tone in dogfood). Dictate trim still uses backend
default 0.2. Silence budgets: streaming ≈ **700 ms**, Focus Dictation **1500 ms**
(Q25). CaptureLog: `earshot-silence` / `earshot-release`. `SilenceVad.swift` is
deleted. Do not replace live Earshot with EnergyVad without an explicit product
decision.

The segmenter is used for **endpointing only**. A closed segment still hands the
accumulated buffer to `dictate` and lets the pipeline's own detector trim it,
rather than slicing on `SpeechSegment` bounds — one pipeline configuration serves
both paths, and running the 40 KiB network twice is not worth a second code path.

Deleting the old shell energy detector also removed two latent bugs it had: the
silence clock ran on wall time rather than sample count, and a segment could only
close when a non-empty low-level chunk arrived, so a mic that stopped delivering
never ended one.

**Rate constraint.** `EarshotVad` is 16 kHz only. `MicCapture` converts to 16 kHz
mono f32 and reports the rate as a hardcoded constant, so the constraint holds
today. Note the failure mode if capture ever becomes rate-flexible: euhadra
**degrades silently**, transcribing unsegmented audio and reporting it only as a
`Stage::Vad` entry in `diagnostics.failures`, which `dictate` currently discards.

### User term dictionary (2026-08-10)

Listening accuracy stops at the transcript euhadra’s ASR emits. Turning that
string into the speaker’s preferred spelling is **terminology substitution**,
and euhadra 0.3.0 exposes it as `TermDictionary` — a `TextProcessor`, not a
file format and not a shipped word list ([`ux-decisions.md`](./ux-decisions.md) §9a).

**Ownership split**

| Piece | Owner |
|---|---|
| Match policy, folding, leftmost-longest, validation errors | euhadra |
| JSON on disk, Settings CRUD, when to rebuild | Typwrtr |
| PhonemeCorrector / contextual rewrite | Out of Typwrtr; euhadra’s problem if pursued |

**Pipeline.** Always mount a `TermDictionary` (empty counts) **after**
`BasicPunctuationRestorer`. Position is revisitable without a product re-grill.
Entries come from Application Support — one JSON file per active language
(`TermEntry { term, aliases }`). Language switch loads that language’s file;
ASR backend switch does **not** change which table is used.

**Reload.** Successful Settings CUD writes the file, then rebuilds
`DictationEngine` so the next utterance sees the change. Corrupt JSON on
launch or language switch: skip the load (mount empty), leave the file on
disk, and surface the failure in Settings — never silently “fix” by
overwriting.

**Not in this slice:** import/export UI, bundled or Typwrtr-published terms,
per-backend tables.

## 4. UniFFI surface (PTT slice)

Minimal, sync-friendly where possible; long work may use callbacks or async bridges later.

| API (names indicative) | Role |
|---|---|
| `CoreConfig` | language, model directory, feature flags |
| `Session::new(config)` | construct pipeline |
| `start_ptt()` | begin accepting audio / mark recording |
| `append_audio(pcm)` **or** `stop_ptt_with_wav(path/bytes)` | feed audio (exact shape TBD at impl) |
| `cancel()` | abort; discard buffer |
| `status()` | idle / recording / processing / error |
| `last_text()` | last success or failure text |
| `take_undo_payload()` | data Swift needs to reverse last insert |
| `clear_buffer()` | after successful undo / user dismiss |

Swift owns **emit** (AX/clipboard). Core returns text + metadata; it does not call macOS pasteboard itself in the dogfood slice (keeps UniFFI free of AppKit). Clipboard emitters inside euhadra remain available for Rust CLI tests only.

### Free lifecycle (stage 2, synchronous)

Focus Dictation reuses the stream-listen surface with a longer silence budget:

| API | Role |
|---|---|
| `start_focus_listen()` | Open a listening period: Earshot `VadStream` + `Segmenter` (1500 ms silence) |
| `push_stream_pcm_f32(samples, sample_rate) -> StreamVadEvent` | Accumulate, frame, score, segment. Returns `None` / `SpeechStarted` / `SegmentEnded` |
| `take_stream_segment() -> Result<String, FfiError>` | Transcribe the closed segment and return cleaned text. Blocking — Swift calls it off the main queue |
| `stop_stream_listen()` / `finish_stream_listen()` | Close or drop the listening period |

Streaming PTT uses `start_stream_listen()` (700 ms silence) with the same push /
take / stop methods. Names `start_free` / `push_free_pcm` from earlier drafts are
folded into this shared surface.

## 5. Model acquisition

| Phase | How models appear on disk |
|---|---|
| **Dogfood / steps 1–5** | **`scripts/fetch-models.sh`** (or equivalent) downloads curated files into a known local dir (e.g. `~/.cache/typwrtr/models` or repo-local `models/` gitignored). Developers point config at that path. |
| **Step 6 (wizard)** | Same fetch logic reused from the app: language choice triggers download + progress; block ready-state until required files exist ([`ux-decisions.md`](./ux-decisions.md) §4). |

Do **not** block PTT engineering on in-app download UI.

Default dogfood languages: **`ja` recommended path first**, `en` second; experimental langs follow euhadra when script supports them.

## 6. Implementation sequence (TDD)

1. **Workspace + `typwrtr-core`** — depend on `euhadra`; failing test: fixture audio or stub → cleaned text string (Red → Green).  
2. **Session API in Rust** — start/stop/cancel/status/last_text without UniFFI.  
3. **UniFFI bindgen** — expose the session API to Swift.  
4. **`apps/macos` skeleton** — menu bar + icon states + `⌥V` PTT wiring (may stub core).  
5. **Insert adapters** — AX then clipboard; failure preview; clipboard restore policy.  
6. **Undo last** — wire buffer to menu/hotkey.  
7. **Wizard** — mode, permissions, language+**in-app model fetch**, launch-at-login (reuses `scripts/` logic).  
8. Free/VAD (F3) — after PTT dogfood is usable (may pull earlier per product owner). **Shipped 2026-08-08** as the Focus Dictation toggle, with a Swift-side energy detector.
9. **VAD stage 1** — failing test first: with `RecordingAsr` (euhadra `testing` feature), assert the adapter is handed materially fewer samples than were pushed when the recording is mostly silence. Then `.vad(EarshotVad::new())`, the `vad` feature, and the `NoSpeech` FFI error.
10. **VAD stage 2** — move endpointing into the core per §3, delete `SilenceVad.swift`. **Done 2026-08-11** (streaming + Focus Dictation share Earshot live listen).
11. **User term dictionary** — failing test: alias in mock transcript becomes the preferred term after punctuation. Then load JSON per language, mount `TermDictionary` after punctuation, Settings CRUD → rebuild on CUD ([`ux-decisions.md`](./ux-decisions.md) §9a).

## 7. Build & test (target commands)

```bash
cargo fmt --all -- --check
cargo build --workspace --all-targets --locked
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo test  --workspace --all-targets --locked
```

GitHub Actions (`.github/workflows/ci.yml`) runs these on `main` and pull requests.

Pre-push hook (fmt/clippy) when Rust is present: `git config core.hooksPath git-hooks`.

## 8. License

Dual-licensed **`MIT OR Apache-2.0`**, matching euhadra. Root texts:
[`LICENSE-MIT`](../LICENSE-MIT) and [`LICENSE-APACHE`](../LICENSE-APACHE).
Workspace `Cargo.toml` already declares `license = "MIT OR Apache-2.0"`.

## 9. Decision log

| Date | Decision |
|---|---|
| 2026-08-07 | Layout: `crates/typwrtr-core` + `apps/macos` + `scripts/fetch-models.sh`. |
| 2026-08-07 | Models: script fetch for dogfood; wizard integrates fetch at step 6. |
| 2026-08-07 | Emit (AX/clipboard) stays in Swift; core returns text. |
| 2026-08-07 | Audio capture placement: bias Swift→core; confirm at impl time. |
| 2026-08-07 | Scaffold: workspace + `typwrtr-core` PTT state machine tests; `fetch-models.sh` stub. |
| 2026-08-07 | `DictationEngine` + MockAsr tests (en/ja Tier1+2); `Session::stop_ptt` runs pipeline. `fetch-models.sh whisper-tiny` downloads ggml tiny weights. |
| 2026-08-07 | UniFFI `PttSession` + `FixedAsr` for shell dogfood without models (`uniffi` 0.29). |
| 2026-08-07 | macOS menu-bar dogfood: XcodeGen project, ⌥V PTT, clipboard paste, FixedAsr path. Audio capture deferred (silence placeholder). |
| 2026-08-07 | **Swift mic capture locked in:** `MicCapture` (AVAudioEngine → 16 kHz mono f32) → `pushPcmF32`. Still FixedAsr until real ASR lands. |
| 2026-08-07 | **WhisperLocal wired:** `DictationEngine::with_whisper_local` / `with_whisper_from_env`; FFI constructors; `fetch-models.sh` builds whisper-cli + ggml-tiny; Swift prefers Whisper when present. |
| 2026-08-07 | **Default PTT hotkey → `⌃⇧D`** (was `⌃⌥V`; D = Dictate). |
| 2026-08-08 | **Undo last (U9):** `take_undo_payload` + menu / `⌃⇧Z`; Swift AX→Backspace→⌘Z reverse. |
| 2026-08-08 | **Dogfood setup checklist:** menu Setup + one-shot alert; model path via UserDefaults/App Support; launch-at-login via `SMAppService`. Full wizard (mode + in-app fetch) still step 7. |
| 2026-08-08 | **Menu reorg:** Setup dialog (shared first-run/menu) with Language; Debug holds capture/backend/model path. |
| 2026-08-08 | **Languages = euhadra 5:** ja Parakeet / en+es Canary / zh Paraformer / ko SenseVoice. |
| 2026-08-11 | **Korean path → Dolphin:** Typwrtr selects `DolphinAdapter` + in-app `dolphin-ko` pack (euhadra §I). SenseVoice FFI kept as legacy. |
| 2026-08-11 | Root dual-license files: `LICENSE-MIT` + `LICENSE-APACHE` (matches Cargo.toml `MIT OR Apache-2.0`). |
| 2026-08-09 | **euhadra 0.3.0** adopted (additive; no source change required to bump). |
| 2026-08-14 | Live endpoint threshold **0.42**: −45 dBFS room tone peaked ~0.37 under Earshot, so 0.35 never accumulated 700 ms of sub-threshold frames. Dictate trim stays 0.2. |
| 2026-08-11 | **VAD stage 2 complete:** Focus Dictation uses `start_focus_listen` (same Earshot live path, 1500 ms silence). `SilenceVad.swift` deleted. |
| 2026-08-09 | Endpointing reads the segmenter **synchronously**; `Session::partials` and callback interfaces deferred. |
| 2026-08-09 | Segmenter used for endpointing only; the pipeline's own detector does the trimming (one pipeline config for both paths). |
| 2026-08-10 | **User term dictionary:** `TermDictionary` only; speaker-owned JSON per language; Settings CRUD rebuilds the engine; after punctuation; no import UI; phoneme/contextual rewrite deferred to euhadra. |

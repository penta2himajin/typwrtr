# Typwrtr — UX & Interaction Decisions

Status: **agreed** (grilling sessions, 2026-08-07, 2026-08-09, and 2026-08-10).  
SSOT for activation, feedback, insertion, privacy UI, and onboarding behaviour.  
Product positioning / licensing: [`product.md`](./product.md). Use cases: [`use-cases.md`](./use-cases.md).

## 0. Insertion architecture (pre-grill)

**Not a dedicated IME.** Menu-bar agent with global hotkey.

Insertion order:

1. Accessibility insert at caret when possible  
2. Else clipboard write + paste (save/restore when possible)  
3. On total failure → see §7  

Do **not** synthesise keystrokes character-by-character (breaks Japanese IME).  
Windows later: same idea (UI Automation + clipboard), not a TSF IME-first design.

---

## 1. State feedback (Q1–Q2)

- Some **state change is required** so the user can tell idle / recording / processing / error.  
- Ideal presentation varies by user type; **do not auto-detect user type**.  
- **PTT default feedback: menu bar icon only** (idle / recording / processing / error).  
- No partial-transcript HUD in MVP (see §11).  
- Richer HUD / partial display may be added later as options.

## 2. Activation modes (Q3, Q5, Q12, Q13, Q19)

### PTT (push-to-talk)

- Hold hotkey to record; release to finalise → cleanup → insert.  
- Feedback: menu bar icon states only.

### Free / VAD (armed)

- **F3:** User must explicitly arm Free mode. Then it runs **only while a text field is focused**.  
- Mic: not open merely because a field is focused; armed + focused + VAD policy.  
- Segment end: **1.5s silence** → **immediate insert** (Q12 = immediate; no cooldown). See Q25 for where 1.5s came from.  
- Spoken commit phrases (“エンター” etc.) and “wait for sentence end” modes: **deferred**.  
- Shipping cut (Q19): **Dogfood / early builds = PTT first**; Free before Gumroad public if ready; **may pull Free earlier if desired**.

### Free focus gate (Q4)

- **Strict** role detection via Accessibility (clear text-field roles only).  
- Secure fields: see §6.  
- On false negative (focus exists but not classified as text field): Free stays off, and the UI **explains** that Free is unavailable here (menu bar). Silent failure is unacceptable.  
- PTT remains available regardless of this gate (subject to §6).

### PTT vs Free interaction (Q13)

- **3b — temporary override:** PTT on the focused field cancels/suspends Free listening for that capture and runs one PTT session.  
- Does **not** permanently disarm Free. Arming state stays as the user set it.

### Silence handling & segment end (Q23–Q26)

Decided 2026-08-09, once euhadra 0.3.0 made voice activity detection available.
Applies to **both** PTT and Free: the two paths share one pipeline.

- **Q23 — Silence must not reach the ASR adapter.** A recogniser handed silence
  invents fluent text (「ご視聴ありがとうございました」, runaway repetition).
  Detection sits ahead of the adapter, and only the detected speech is
  transcribed. Users see fewer invented sentences, especially on short captures.
- **Q24 — A capture with no speech in it is not an error the user must read.**
  **PTT: return to idle silently** — no alert. The user knows they said nothing,
  and the previous wording ("Speak longer, or check that ASR is …") wrongly sent
  them to inspect their model setup. **Free: ignore entirely** — while armed,
  stretches of silence are the normal case, not a failure.
- **Q25 — Segment end stays 1.5s for Focus Dictation, but the value is not UX-derived.**
  It was a margin for the old energy detector: its threshold had been lowered to
  catch quiet speakers, which made it read mid-utterance dips as silence, so a
  long grace period was needed to avoid cutting people off mid-sentence. A real
  detector removes that constraint, and there is room to move toward euhadra's
  700ms default. **Measure first, then adjust** — shortening it is a latency win
  and must not be bundled with the detector swap, or a regression cannot be
  attributed to one or the other.
  - First measurement (dogfood, 2026-08-09, PTT): captures of 1.19–2.09s, of
    which **0.00–0.07s was trimmed**, one utterance each. Read that as an upper
    bound rather than proof of clean captures: segment bounds carry 200ms of
    `speech_pad` either side, so any silence inside that margin is deliberately
    kept and reports as 0. Trimming on **batch** PTT is therefore bounded by the
    pad width and is negligible either way — the key release already ends the
    capture, so **the 1.5s value never applies to batch PTT**.
  - **Streaming PTT** uses **~0.7s** silence (core `STREAMING_PTT_SILENCE_MS`) —
    the hold is already an explicit consent gate, so euhadra's default is enough
    and mid-hold inserts should not wait for Focus Dictation's 1.5s margin.
  - **Focus Dictation / Free** still uses 1.5s until measured on real audio after
    VAD stage 2; do not shorten that path in the same change as the detector swap.
- **Q26 — A long unbroken utterance may insert in more than one piece.** Speech
  is force-segmented after 30s with no pause. Previously such an utterance
  produced a single insert, and the buffer grew without bound. The cap is
  accepted; the granularity change is the visible cost.

## 3. Hotkey (Q15)

- Default: **`Control + Shift + D`** (hold for PTT; D = Dictate).  
  - Rationale: `Option+letter` inserts macOS special characters (e.g. `⌥V` → √); `Ctrl+V` / `Ctrl+Option+V` can leak control characters when the event tap is unavailable; `⌘⇧D` collides with Finder → Desktop.  
  - Chord is **swallowed** system-wide via CGEvent tap (needs Accessibility).  
- Changeable from the **menu bar** (presets may include Right Command alone with “no other key” rules; not the default).  
- No dedicated “switch mode” hotkey in MVP.

## 4. Onboarding wizard (Q9–Q10, Q16, Q21–Q22)

**Required in first-run wizard:**

1. Mode choice (PTT-only vs Free armed)  
2. Permissions explanation + guided enable (mic, Accessibility)  
3. Language (+ model download bound to that language)  
4. **Launch at login** — user chooses (Q16 = wizard)

**Language default (Q21):** follow OS locale if it is one of `en` / `ja` / `zh` / `es` / `ko`; otherwise default to **`en`**.

**Language catalogue (Q22):**

- **Recommended:** `ja`, `en`  
- **Experimental:** `zh`, `es`, `ko` (selectable, labelled experimental)

**Model download:** tied to language choice; start in-wizard with progress; do not pretend ready until required model is present (disable or block start).

**Dogfood (2026-08-08 / 2026-08-10):** shared **Typwrtr Settings** dialog covers permissions, **mode**, language + in-app pack download, and launch-at-login. Modes:

- **Push to talk (batch)** — hold ⌃⇧D; release inserts the whole capture once.
- **Push to talk (streaming)** — hold ⌃⇧D; **Earshot live endpointing** in core (`EarshotVad` + `Segmenter`). Live score cutoff is **0.35** (rlx-vad `SegmentParams::earshot` preset for Earshot segmentation); dictate trim keeps euhadra’s calibrated **0.2**. `min_silence` ≈ 0.7s (euhadra default). Release flushes **only if an utterance is still open**. Focus Dictation still uses the Swift energy detector. Mid-stream failures are logged, never modal. **Mid-hold insert** must not wait for the PTT chord to release; use AX / unicode / synthetic modifier-ups + ⌘V while the key is down. Do not swap live Earshot for EnergyVad without an explicit decision.
- **Focus Dictation** — armed + text-field focus; silence ends each phrase (F3). Menu toggle matches this mode only.

Settings radios use these three titles (no more “Arm Free”). Free/VAD status is a secondary line under the Focus Dictation menu toggle while that mode is on. AX focus gate uses **Accessibility**, not VoiceOver; PTT temporarily suspends Focus Dictation. Korean remains WIP.

**Settings window:** not required while the surface stays small; menu bar is the primary control surface. Add a settings window when complexity demands it.

## 5. Recognition display (Q11)

- MVP: **do not show** interim/final text before insert.  
- Menu bar state only during recording/processing.  
- Failure/undo paths may show text in a small preview (§7–§8).  
- Optional “show text while processing” / partial HUD: later, separate decision.

## 6. Secure fields (Q6)

- **Free: always blocked** on secure fields.  
- **PTT: allowed but discouraged** — show an explicit non-recommended notice when used.  
- User may still choose PTT (selective use).

## 7. Insert failure (Q7)

| Situation | Behaviour |
|---|---|
| Insert failed, clipboard writable | Leave result on clipboard; tell user they can paste manually |
| Clipboard also unavailable | In-app buffer + preview (retry / copy from UI) |

Never drop the recognised text on failure without a recovery path. Prefer restoring prior clipboard when Typwrtr overwrote it, or disclose the overwrite.

## 8. Undo (Q8)

- MVP includes **Undo last** (hotkey and/or menu).  
- Backed by the last-success / failure text buffer.  
- Best-effort removal from the field; if reverse insert is impossible, say so and keep buffer / clipboard restore behaviour clear.  
- Do not rely only on system Cmd+Z.
- **Dogfood (2026-08-08):** menu **Undo last insert** + hotkey **⌃⇧Z**; core `take_undo_payload()`; Swift reverses via AX select+delete → Backspace N → ⌘Z.

## 9. Language runtime (Q14)

- **Single active language** at a time (menu bar switch).  
- Remember last choice across launches (still “single language”, not bilingual auto).  
- Per-utterance auto LID (U12): not in this phase.  
- User term dictionary: see §9a (not required to switch language).

### 9a. User term dictionary (Q28–Q39)

**What it is.** An **ASR output transform**, not acoustic error correction.
ASR tends to emit a stable string for a spoken form; the speaker wants a
different spelling (product names, coinages, house terms). That substitution
is `euhadra::dictionary::TermDictionary`. Typwrtr owns the entries and the UX;
euhadra owns match policy and pipeline ordering.

**What it is not.** `PhonemeCorrector`, contextual model rewrite (DeBERTa-class),
or any bundled/community term list shipped by Typwrtr. Those belong to euhadra
(or nowhere) as separate stages if pursued later. Typwrtr does not reimplement
them.

- **Q28 — Dictionary = terminology substitution only.** Alias → preferred term.
- **Q29 — Speaker-owned entries only.** No Typwrtr- or euhadra-published
  dictionary. The product is the input mechanism, not a correction lexicon.
  Community-published lists may appear later; they are outside this phase.
- **Q30 / Q31 — One table per active language**, not per ASR backend. Output
  tendencies are language- (and model-) dependent, but forcing re-registration
  when the backend changes is a worse experience than sharing one table per
  language. Backend tags on individual rows are deferred.
- **Q32 — Storage:** Application Support, one JSON file per language. Hand-edit
  allowed. Format is Typwrtr’s (euhadra supplies no file format).
- **Q33 — UI:** Settings list with add / edit / delete (term + aliases). Dogfood.
- **Q34 — Reload on CUD:** each successful create/update/delete rebuilds the
  engine so the next utterance sees the change. Not a per-utterance file read.
- **Q35 — Pipeline position:** after `BasicPunctuationRestorer` for now.
  Movable later without a product re-grill.
- **Q36 — Validation:**
  - In Settings: reject the save if `TermDictionary::new` reports problems;
    highlight the offending rows; leave the on-disk file unchanged (atomic).
  - On launch (or language switch) if the JSON is corrupt: **do not load it into
    the pipeline** (behave as empty) and **do not overwrite** the broken file.
    Settings must show that this language’s dictionary failed to load so the
    silence is not mistaken for “terms are active.”
- **Q37 — Empty dictionary still mounts** as a pipeline stage (no-op match).
  Keeps the reload path one shape; cost is negligible next to ASR.
- **Q38 — Ship in dogfood** with Settings CRUD in the same effort as wiring.
- **Q39 — No import/export UI** this phase. Replacing the JSON by hand is fine.

## 10. Network & privacy (Q17–Q18)

**Network**

- No telemetry, no automatic crash upload, no usage analytics leaving the device.  
- **Update check only** (pull appcast / equivalent): **default ON**, toggle OFF in menu bar.  
- Model download only on explicit user action (wizard or menu).

**Data retention**

- **Audio waveforms:** process in memory only; **do not write to disk**.  
- **Text:** keep the minimum needed for failure preview, retry, and Undo; discard after success path is done and Undo is no longer applicable (or after explicit dismiss).  
- No “save last N recordings” debug store in MVP.
- **Capture measurements (Q27):** debug builds only, via `os_log` under subsystem
  `app.typwrtr.macos.menuextra`. Counts and durations only — capture duration,
  detected speech duration, how much was trimmed, and the utterance count. No
  audio, no transcribed text. This exists because Q25 defers the segment-end
  value to measurement, and because `NSLog` output has been confirmed
  unrecoverable after the fact.
  - Report **trimmed duration, not speech-as-a-fraction**. Segment bounds carry
    `speech_pad` either side and can overlap or run past the buffer, so summing
    them overcounts; the first dogfood run reported a "ratio" of 1.15. The core
    now clamps and merges the ranges, and a test pins speech ≤ audio handed in.

## 11. Quit while busy (Q20)

- If recording or processing: **confirm** (“Discard and quit?”) before exit.

## 12. Decision log (grilling)

| ID | Decision |
|---|---|
| Q1–Q2 | State feedback required; PTT → menu bar icon only |
| Q3 | PTT + Free (Free = focus-gated); PTT feedback minimal |
| Q4 | Strict focus gate + visible “Free unavailable” |
| Q5 | Free = F3 (explicit arm) |
| Q6 | Secure: Free off, PTT allowed + discouraged |
| Q7 | Clipboard-ok → leave on clipboard; else in-app preview buffer |
| Q8 | First-party Undo last |
| Q9 | Wizard picks mode; menu bar is primary UI; settings window optional/later |
| Q10 | Wizard: mode, permissions, language(+model) |
| Q11 | No pre-insert text UI in MVP |
| Q12 | Free: 1.5s silence → immediate insert |
| Q13 | 3b temporary PTT override; Free arming unchanged |
| Q14 | Single language (dictionary is §9a, not required to switch) |
| Q15 | Default hotkey Control+Shift+D; changeable in menu bar |
| Q16 | Launch-at-login chosen in wizard |
| Q17 | Offline-first + update check pull (default on, togglable) |
| Q18 | Text buffer for fail/undo; no audio on disk |
| Q19 | Ship cut: PTT dogfood first; Free before public or earlier if wanted |
| Q20 | Confirm on quit while recording/processing |
| Q21 | Locale → language; else en |
| Q22 | ja/en recommended; zh/es/ko experimental |
| Q23 | Silence never reaches the ASR adapter (detection ahead of it, both paths) |
| Q24 | No-speech capture: PTT returns to idle silently; Free ignores it |
| Q25 | Focus Dictation segment end 1.5s; streaming PTT uses ~0.7s (core SSOT) |
| Q26 | 30s cap on unbroken speech; a long utterance may insert in pieces |
| Q27 | Capture measurements: debug builds, `os_log`, trimmed duration + count |
| Q28 | Dictionary = `TermDictionary` substitution only |
| Q29 | Speaker-owned entries; Typwrtr ships no lexicon |
| Q30–Q31 | One table per language; not per ASR backend |
| Q32 | App Support JSON, one file per language |
| Q33 | Settings CRUD (list + add/edit/delete) |
| Q34 | Rebuild engine on each successful CUD |
| Q35 | After punctuation restore; position revisitable |
| Q36 | Settings: atomic reject; corrupt file: skip load, keep file, surface in UI |
| Q37 | Empty dictionary still on the pipeline |
| Q38 | Dogfood ships Settings CRUD with the wiring |
| Q39 | No import/export UI this phase |

## 13. Deferred (explicit non-decisions)

- Sentence-final wait / spoken “Enter” commit  
- Partial or processing text HUD options  
- Mode-switch hotkey  
- Phoneme / contextual (DeBERTa-class) correction as product features  
- Dictionary import/export UI; Typwrtr-published or bundled term lists  
- Per-backend dictionary tables or per-row backend tags  
- Quiet/whisper mode (U10), structured notes (U8), true bilingual auto (U12)  
- Cooldown between Free segments  
- Permanent “PTT disables Free arming” behaviour  
- Incremental per-utterance output while the speaker is still talking. Not needed:
  endpointing reads the segmenter synchronously instead (see
  [`architecture.md`](./architecture.md)). Revisit only if a feature wants text
  before the utterance closes — which Q11 currently forbids anyway.  

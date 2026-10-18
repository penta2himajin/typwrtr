# Typwrtr — UX & Interaction Decisions

Status: **agreed** (grilling sessions, 2026-08-07, 2026-08-09, 2026-08-10, and 2026-10-18).  
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
- **PTT feedback: menu bar icon** (idle / recording / processing / error) **plus the Q40 level bar while the key is held**, which stays through processing (Q41).  
- No partial-transcript HUD in MVP (see §11).  
- **While the mic is open (Q40):** a non-activating bar at the bottom center of the dictated-into app’s screen, in **all three modes** — PTT batch and streaming while the key is held, Focus Dictation while its mic is open. Level bars only — no transcript and no controls. After release it stays up through processing with a wave (Q41) and disappears on insert. Hidden while Focus Dictation is armed but waiting for a field. The menu-bar icon still changes. (2026-10-18: extended from Focus Dictation only to PTT, matching Aqua Voice / Typeless-style hold feedback.)  
- Richer HUD / partial display may be added later as options.

## 2. Activation modes (Q3, Q5, Q12, Q13, Q19)

### PTT (push-to-talk)

- Hold hotkey to record; release to finalise → cleanup → insert.  
- Feedback: menu bar icon states, plus the Q40 level bar while held.

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

### Silence handling & segment end (Q23–Q26, Q49)

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
  - **Streaming PTT** (~0.7s, core `STREAMING_PTT_SILENCE_MS`) was removed by Q44
    (2026-10-18). The core constant and listen mode stay, unused, until removal
    is decided separately.
  - **Focus Dictation / Free and hands-free (Q45)** use 1.5s via `start_focus_listen` (sample-clock
    Earshot segmenter), not wall-time energy VAD.
- **Q26 — A long unbroken utterance may insert in more than one piece.** Speech
  is force-segmented after 30s with no pause. Previously such an utterance
  produced a single insert, and the buffer grew without bound. The cap is
  accepted; the granularity change is the visible cost.

- **Q49 — Batch PTT needs the same evidence of speech as streaming.** Decided
  2026-10-18 after a silent ⌃⇧D hold inserted 「うん。」: the dictate trim's
  0.2 cutoff opened on room tone, so Q23/Q24 did not hold on batch PTT.
  Batch PTT now checks for the live endpointer's speech start (Earshot 0.42
  for 120 ms) before ASR, and a hold without it returns to idle silently per
  Q24. **Visible cost:** a very quiet single vowel can now be dropped without a
  message (synthetic replies: 146/148 kept; the two misses were 「あ」 at
  −40 dBFS). Numbers: [`architecture.md`](./architecture.md) §3.

## 3. Hotkey (Q15)

- Default: **`Control + Shift + D`** (hold for PTT; D = Dictate).  
  - Rationale: `Option+letter` inserts macOS special characters (e.g. `⌥V` → √); `Ctrl+V` / `Ctrl+Option+V` can leak control characters when the event tap is unavailable; `⌘⇧D` collides with Finder → Desktop.  
  - Chord is **swallowed** system-wide via CGEvent tap (needs Accessibility).  
- Changeable from **Settings → Mode → Hotkey** (preset popup; persists in UserDefaults). MVP presets: **`⌃⇧D`** (default), **`⌃⇧Space`**. Undo stays **`⌃⇧Z`**.  
  - Right Command alone / freeform recorder remain deferred (modifier-only chords need different event handling).  
- No dedicated “switch mode” hotkey in MVP.

## 4. Onboarding wizard (Q9–Q10, Q16, Q21–Q22)

**Required in first-run wizard:**

1. How to dictate — one screen: hold to talk / double-tap for hands-free / ⌃⇧Z undo / Esc cancel (Q48; replaces the mode choice)  
2. Permissions explanation + guided enable (mic, Accessibility)  
3. Language (+ model download bound to that language)  
4. **Launch at login** — user chooses (Q16 = wizard)

**Language default (Q21):** follow OS locale if it is one of `en` / `ja` / `zh` / `es` / `ko`; otherwise default to **`en`**.

**Language catalogue (Q22):**

- **Recommended:** `ja`, `en`  
- **Experimental:** `zh`, `es`, `ko` (selectable, labelled experimental)

**Model download:** tied to language choice; start in-wizard with progress; do not pretend ready until required model is present (disable or block start).

**Dogfood (2026-08-08 / 2026-08-10 / 2026-08-11; modes replaced 2026-10-18 by Q44):** shared **Typwrtr Settings** dialog covers permissions, a **How to dictate** block (the Q48 gesture text plus the Hotkey popup), language + in-app pack download, dictionary CRUD, **Licenses…** (attribution dialog for Typwrtr / euhadra / model weights), and launch-at-login. Ways to dictate:

- **Push to talk** — hold the PTT hotkey (default ⌃⇧D; Settings → Hotkey); release inserts the whole capture once (batch).
- **Hands-free** — double-tap the PTT hotkey (Q44–Q45). **Earshot live endpointing** in core (`EarshotVad` + `Segmenter`, live cutoff **0.42**: measured −45 dBFS room tone peaked ~0.37, above rlx-vad’s 0.35 preset), **1.5s** segment end, insert per segment. Mid-stream failures are logged, never modal. Do not swap live Earshot for EnergyVad without an explicit decision.
- **Focus Dictation** — the menu-bar toggle; armed + text-field focus; same Earshot live endpointing with **1.5s** silence (Q25); one listening period spans many segments. While the mic is open, a bottom-center level bar shows that input is active (no transcript; Q40).

Free/VAD status is a secondary line under the Focus Dictation menu toggle while it is on. AX focus gate uses **Accessibility**, not VoiceOver; PTT and hands-free temporarily suspend Focus Dictation. Japanese uses **Parakeet-ja on CoreML / the Neural Engine** (euhadra `FluidAudioAdapter`, CC BY 4.0 weights, ~625 MB in-app pack; the first install shows "Optimizing… (~1 min)" while it compiles once); an older ONNX pack is still used if present. Korean uses **Dolphin small CTC** (euhadra `DolphinAdapter`, Apache-2.0) with in-app pack download. **Hotkey** popup selects PTT presets (`⌃⇧D`, `⌃⇧Space`); Undo stays `⌃⇧Z`.

**Settings window:** not required while the surface stays small; menu bar is the primary control surface. Add a settings window when complexity demands it.

## 5. Recognition display (Q11)

- MVP: **do not show** interim/final text before insert.  
- Menu bar state during recording/processing, plus the Q40 level bar (no text) while recording.  
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
- **Capture measurements (Q27):** debug builds only by default, via `os_log` under subsystem
  `app.typwrtr.macos.menuextra`. Counts and durations only — capture duration,
  detected speech duration, how much was trimmed, and the utterance count. No
  audio, no transcribed text. This exists because Q25 defers the segment-end
  value to measurement, and because `NSLog` output has been confirmed
  unrecoverable after the fact.
  - **Latency logs (dogfood):** optional toggle in menu **Debug → Latency logs**
    (UserDefaults, default off). When on, also works in Release dogfood builds:
    end-to-end ms from PTT release / segment end through ASR finalize and insert,
    plus insert path (`ax`, `cmdv`, `unicode`, etc.). Category `latency`; same
    subsystem. Still numbers only — no audio, no transcript.
  - Report **trimmed duration, not speech-as-a-fraction**. Segment bounds carry
    `speech_pad` either side and can overlap or run past the buffer, so summing
    them overcounts; the first dogfood run reported a "ratio" of 1.15. The core
    now clamps and merges the ranges, and a test pins speech ≤ audio handed in.

## 11. Quit while busy (Q20)

- If recording or processing: **confirm** (“Discard and quit?”) before exit.

## 11a. Recording → insert behaviour (Q41–Q48)

Decided 2026-10-18 from [`research/dictation-ui-competitors.md`](./research/dictation-ui-competitors.md)
against the goal "the simplest UI and flow, the highest-quality experience". Ships in
three PRs tracked by [#6](https://github.com/penta2himajin/typwrtr/issues/6).

- **Q41 — Processing lives in the bar.** After release the bar stays and its bars give
  way to a slow left-to-right wave, with no text (nothing to localise; same size). It
  hides on insert. The bar is already up while recording, so a short processing time
  moves the hide from release to insert rather than causing a flash. In hands-free the
  bar shows levels for as long as the mic is open; the wave appears only for the last
  segment after the mic closes.
- **Q42 — No idle bar, no controls.** The menu-bar icon shows idle; the key and Esc
  are the controls. Keeps Q40's click-through bar.
- **Q43 — Dead mic is not silence.** Q24 still holds for a capture with no speech.
  When the *input level* stays near zero, the bar shows "No microphone input" for
  about 2 s instead:
  - PTT: judged over the whole capture.
  - Hands-free / Focus Dictation: judged over the first ~2 s after the mic opens, then
    the listening ends (Focus Dictation disarms, so it does not reopen on the next focus).
  - "Near zero" is **−80 dBFS** RMS (core `DEAD_INPUT_RMS`, pinned by tests). Measured
    2026-10-18 on the built-in mic: live silence −44 to −50.5 dBFS, input volume 0 →
    −120 dBFS. The cutoff keeps 30 dB above it for mics that gate to a low floor.
- **Q44 — One key.** Hold = PTT, which inserts once on release (batch; streaming PTT is
  removed). Double-tap within 0.4 s = hands-free. A press shorter than 0.3 s waits up to
  0.4 s for a second press; longer presses start PTT immediately. A lone short tap
  toggles Focus listening when Focus Dictation is armed on a text field (Q46), and
  is batch PTT otherwise. The Settings mode
  radios go; Settings → Mode keeps only the hotkey. Focus Dictation stays an armed
  toggle in the menu bar (Q4–Q5, Q13 unchanged). Its shortcut is
  [#4](https://github.com/penta2himajin/typwrtr/issues/4), and a single key such as Fn is
  [#3](https://github.com/penta2himajin/typwrtr/issues/3).
- **Q45 — Hands-free.** No focus gate: the double-tap is explicit consent, as with PTT,
  including the Q6 secure-field notice. Inserts at each 1.5 s pause (the Focus Dictation
  path). Ends on: the key (insert the open segment), Esc (discard it), the frontmost app
  changing (revised 2026-10-18: the open segment and anything still being transcribed
  are **dropped** — inserting would re-activate the app the user just left), or 20 s of silence (one core
  constant, tuned on dogfood; VAP candidate in [#5](https://github.com/penta2himajin/typwrtr/issues/5)).
- **Q46 — Esc cancels.** Esc is swallowed only while the mic is open or processing, and
  discards what is in flight. Hands-free: drop the open segment and end.
  Already-inserted text stays; ⌃⇧Z removes it.
  - **Focus Dictation (revised again 2026-10-18):** Esc is swallowed while the mic is
    open (bar visible). Passing it through stopped the conversation in apps such as
    Claude, which use Esc for more than leaving a field. Typwrtr ends the listen, drops
    the open segment, hides the bar, and stays armed. It never moves or clears the
    field's focus. Once the bar is hidden, Esc reaches the app again, so a second Esc
    does what the app expects. The same field does not reopen the mic on its own.
    Listening resumes on a single tap of the PTT key, on a click (back into the field,
    or into another one), or once focus leaves text fields and lands on one again
    (checked every 100 ms).
  - **Single tap toggles Focus listening.** While Focus Dictation is armed on a text
    field, a lone short tap of the PTT key stops listening (as Esc does) when the bar
    is up, and resumes it when Esc or a tap stopped it. The tap's own audio is
    discarded. It counts as a lone tap only after the 400 ms double-tap window (Q44),
    so the toggle lands ~0.4 s after the tap. With nothing to toggle (Focus disarmed,
    or no field focused), the tap is batch PTT as before. Esc that cancels a press
    begun over a listening field (in that window, or while holding or processing
    PTT) leaves Focus stopped, as Esc on the bar would.
- **Q47 — Not added:** start/stop sounds, ducking other audio, history, and a
  paste-last hotkey. The bar carries state, §7 plus ⌃⇧Z cover recovery, and §10 keeps
  retention minimal. Revisit on dogfood evidence.
- **Q48 — Onboarding teaches the gestures,** not a mode: one wizard screen with hold to
  talk, double-tap for hands-free, ⌃⇧Z to undo (a strength no competitor has), and Esc to
  cancel. Nothing extra in everyday UI.
- **Kept:** Q11, no pre-insert text. Transcript-in-bar and learning from corrections are
  [#2](https://github.com/penta2himajin/typwrtr/issues/2).

## 12. Decision log (grilling)

| ID | Decision |
|---|---|
| Q1–Q2 | State feedback required; PTT → menu bar icon (+ Q40 level bar while held) |
| Q3 | PTT + Free (Free = focus-gated); PTT feedback minimal |
| Q4 | Strict focus gate + visible “Free unavailable” |
| Q5 | Free = F3 (explicit arm) |
| Q6 | Secure: Free off, PTT allowed + discouraged |
| Q7 | Clipboard-ok → leave on clipboard; else in-app preview buffer |
| Q8 | First-party Undo last |
| Q9 | Menu bar is primary UI; settings window optional/later (wizard mode pick superseded by Q48) |
| Q10 | Wizard: how to dictate (Q48), permissions, language(+model) |
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
| Q25 | Focus Dictation / hands-free segment end 1.5s (streaming PTT ~0.7s removed by Q44) |
| Q26 | 30s cap on unbroken speech; a long utterance may insert in pieces |
| Q27 | Capture measurements: `os_log`, trimmed duration + count; optional latency logs in Release |
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
| Q40 | Mic open (PTT hold or Focus Dictation): bottom level bar, no transcript |
| Q41 | Bar stays through processing as a text-free wave; hidden on insert |
| Q42 | No idle bar; no controls on the bar |
| Q43 | Dead mic → "No microphone input" in the bar (PTT: whole capture; hands-free/Focus: first ~2s, then end) |
| Q44 | One key: hold = PTT (batch only), double-tap = hands-free; mode radios removed |
| Q45 | Hands-free: no focus gate; inserts per 1.5s pause; ends on key / Esc / app switch (drops open segment) / 20s silence |
| Q46 | Esc cancels while mic open or processing; inserted text stays (⌃⇧Z). Focus: Esc swallowed while the bar is up, ends the listen; a lone tap of the key toggles listening |
| Q47 | No sounds, no audio ducking, no history, no paste-last |
| Q48 | Wizard teaches hold / double-tap / ⌃⇧Z / Esc on one screen |
| Q49 | Batch PTT requires the live speech-start criterion before ASR; quiet single vowels may drop silently |

## 13. Deferred (explicit non-decisions)

- Sentence-final wait / spoken “Enter” commit  
- Partial or processing text HUD options  
- Mode-switch hotkey (Focus Dictation toggle shortcut: [#4](https://github.com/penta2himajin/typwrtr/issues/4))  
- Transcript in the bar; learning from corrections ([#2](https://github.com/penta2himajin/typwrtr/issues/2))  
- Single-key PTT hotkey such as Fn ([#3](https://github.com/penta2himajin/typwrtr/issues/3))  
- VAP for segment end / hands-free auto-end ([#5](https://github.com/penta2himajin/typwrtr/issues/5))  
- Start/stop sounds, audio ducking, history, paste-last hotkey (Q47; revisit on dogfood evidence)  
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

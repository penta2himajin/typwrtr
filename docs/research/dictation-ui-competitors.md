# Dictation UI — competitor behaviour (macOS)

- **Date:** 2026-10-18. All pages fetched on this date unless another date is given.
- **Scope:** macOS desktop apps only. One dictation cycle: key down → recording →
  processing → insert → failure / no speech. Typeless and Aqua Voice are primary;
  Wispr Flow and superwhisper are secondary comparisons.
- **Purpose:** input to a Typwrtr product-design grilling session. Not a decision record;
  decisions stay in [`ux-decisions.md`](../ux-decisions.md).
- **Source quality:** first-party sources only: help centres, changelogs and release
  notes, official `llms.txt`, and official demo media. No third-party review is used as a
  source. Tags such as `[T1]` point to the Sources list at the end. "Unconfirmed" means no
  first-party source was found. Nothing was installed and no account was created. These
  products ship every few weeks, so treat anything older than a release or two as
  perishable.
- **Video evidence:** the Typeless help-centre clip `[T9]` (6.5 s, viewed frame by frame
  in a browser) is the only motion source. Frame times are cited where used.

## 1. Typeless (typeless.com)

Typeless macOS is at v2.8.0 or later (2026-09-22) `[T10]` and needs sign-in `[T15]`.

1. **Activation.**
   - *Current docs (Oct 2026):* press the Dictate shortcut **once** to start, and **once
     again** to finish; the text appears where you began `[T1]`. Default **Fn** (Right Alt on
     Windows) `[T1]`. Translate is Fn + Left Shift `[T8]`. Ask anything is **Fn + Space**,
     finished with a single press of Fn `[T10][T11]`.
   - *Earlier docs (Wayback, 2026-05-14):* **hold** Fn, release to paste. **Fn + Space**
     entered Hands-free mode, and a press of the shortcut stopped it `[T2]`. v0.9.0
     (2025-12-24) also says "Hold your Hotkey (e.g., Fn)" `[T16]`.
   - Fn + Space now means Ask anything, so the old hands-free chord appears to have been
     repurposed. Whether hold-to-talk still works alongside tap-to-toggle is **unconfirmed**.
   - Shortcuts can be changed, and extra shortcuts can be added for external keyboards
     `[T3]`. A help page covers Fn conflicts with macOS keyboard shortcuts `[T13]`.
2. **Floating indicator ("Voice bar").**
   - The docs say to start speaking once "you hear the interaction sound or see the Voice
     bar" `[T1]`. The archived wording was "the white bars start moving" `[T2]`.
   - In the demo clip `[T9]` the bar is a small black capsule at the bottom centre of the
     mocked screen. Left to right it holds an **✕** button, white level bars, and a **✓**
     button. At ~1.6 s the bars are a flat dotted line (no speech yet). At ~2.3–3.6 s they
     are a moving waveform.
   - The bar is interactive. During Translate you hover the current language on it to
     change the target `[T8]`. At 8 minutes it shows a 60-second countdown, and a dictation
     is capped at 9 minutes `[T6]`.
   - Whether a resting bar shows while idle, and whether its position follows the active
     screen: **unconfirmed**. No bar is visible before Fn in the clip (~1.0 s).
3. **Text preview.**
   - No doc mentions live or partial text.
   - The demo clip `[T9]` shows a large blue card of raw spoken words (fillers included)
     above the pill while recording (~2.3–3.6 s). It may be an editorial caption rather than
     app UI: **unconfirmed as in-app UI**.
   - The final text is not shown anywhere before it is inserted.
4. **Processing.** The pill's controls give way to the word "**Thinking**" with a shimmer
   (~4.6–5.6 s) `[T9]`. At ~6.3 s the formatted list has been inserted and the pill is gone
   `[T9]`. How long processing shows in practice: unconfirmed.
5. **Insert and no text field.**
   - Text is **pasted** into the active field. Accessibility is needed "so Typeless can
     paste text into any text field" `[T15]`, and the archived docs say release "to paste"
     `[T2]`.
   - The archived docs say the cursor "must be in a textbox" `[T2]`.
   - Every transcript also goes to a local **History** with Copy, Retry ("If what you said
     didn't go through"), and Download audio. Retention runs from Forever to Never `[T4]`.
   - A troubleshooting page mentions "closed the card by accident", which implies a
     transcript card in some failure case `[T5]`. What triggers that card: **unconfirmed**.
   - Clipboard restore: **unconfirmed**.
6. **Cancel / undo.**
   - The pill has an ✕ `[T9]`. The archived docs say **Esc** cancels and the transcript stays
     in History `[T2]`.
   - No first-party undo of an insert. Personalization learns from words you correct
     after dictating `[T4]`.
7. **Sounds.** An "**Interaction sounds**" toggle plays a sound on start and on finish.
   "**Mute when dictating**" pauses other audio `[T3]`. The defaults for both are
   unconfirmed.
8. **Menu bar / Dock.**
   - There is a menu-bar icon with a menu that includes Check for updates `[T12]`.
   - "**Show app in dock**" is a toggle `[T3]`. The main window has Home, History,
     Dictionary, and Settings `[T3][T4]`.
   - Clicking the pill: the ✕ and ✓ buttons are visible `[T9]`. What a click elsewhere on
     the pill does: unconfirmed.
9. **Errors.**
   - "**Microphone unavailable**" error `[T7]`. Permission guidance asks the user to
     re-toggle Accessibility and Microphone `[T15]`.
   - What is shown when no speech is detected: **unconfirmed**.
10. **Settings surface.** Shortcuts, microphone (blue level bars while testing),
    interface language, appearance, interaction sounds, mute when dictating, launch at
    login, and Show app in dock `[T3]`. No documented pill visibility setting.

## 2. Aqua Voice (aquavoice.com)

The desktop app is at v0.20.0 (2026-09-22), and Aqua Pet shipped 2026-10-13 `[A3]`.
Processing is cloud-only `[A1]`.

1. **Activation.**
   - **Hold Fn** (Alt on Windows) to talk. "Release the key (or tap again) to commit" `[A1]`.
   - **Double-press** the key, or hold it and tap Space, to go hands-free. Hands-free runs
     in Realtime Mode by default; press once to finish `[A1]`.
   - Up to 5 bindings per action, and mouse buttons can be bound (v0.18.6, 2026-07-30)
     `[A3][A5]`.
   - Keys are global and "will NOT bubble down to your active application" (that is,
     swallowed). They take priority over system shortcuts `[A5]`.
   - The same key with text selected starts Edit Mode `[A8]`.
2. **Floating indicator ("Floating Bar").**
   - The FAQ calls it "the black floating bar at the bottom" `[A2]`. It is hidden via
     Settings → System → **Show Floating Bar** `[A2]`. Its existence as a separate toggle
     suggests the bar persists while idle: likely, **unconfirmed**.
   - v0.20.0 added a Liquid Glass bar on macOS 26: "The Aqua orb and audio waveform show
     when Aqua is listening, with a compact design" `[A3]`. The changelog illustration
     `[A11]` is a translucent capsule with a blue orb on the left and five rounded white
     level bars. It is a render, not a screenshot.
   - The pill carries short messages: a chip above it reads "12 words selected" in Edit Mode
     `[A8]`, and the pill itself shows "Try rephrasing" `[A9]`.
   - Optional **Aqua Pet** takes the bar's place. It can be dragged anywhere, naps after 2
     minutes of quiet, and "makes no sound of its own" `[A4]`.
   - Follows the active screen: **unconfirmed**. A fullscreen positioning fix shipped in
     v0.11.9 `[A3]`.
3. **Text preview.**
   - Default **Instant Mode**: "Press key → talk → release → see text", with no live text
     `[A1]`.
   - **Realtime Mode** (Max plan): "words appear in the Aqua toolbar as you speak and land in
     the app when you finish" `[A1][A10]`.
4. **Processing.** Aqua claims results in about 450 ms `[A1]`. What the bar shows while
   processing: **unconfirmed**.
5. **Insert and no text field.**
   - Text is pasted at the cursor `[A2]`. The clipboard is restored after the paste
     (v0.2.0) `[A3]`.
   - "Avoid Clipboard History": when this is off, the last transcript is left on the
     clipboard `[A3]`.
   - **Paste Last Transcript**, ⌃⌘V, is customizable (v0.9.5/v0.9.10) `[A3]`.
   - History keeps audio for 3 days, with replay, re-run, and copy `[A6]`.
   - What happens with no focused field on desktop: **unconfirmed**. On iOS, Aqua copies
     the transcript instead `[A3]`.
6. **Cancel / undo.**
   - Esc or click to cancel: **unconfirmed**.
   - "Undo AI Edit" in History restores the raw transcript (v0.3.0) `[A3]`. An Edit Mode
     change is reversed with the host app's Undo `[A8]`. No first-party undo of an insert.
7. **Sounds.**
   - A sounds setting exists: notification sounds play "only if you have sounds on" `[A4]`.
   - Start/stop chimes: **unconfirmed**.
   - "Mute Background Audio" on macOS is on, and can be disabled (v0.7.0) `[A3]`.
8. **Menu bar / Dock.**
   - Menu-bar icon (with "Quit Aqua Completely") and a Dock icon. "Quit Aqua Voice (UI)"
     closes the window but keeps the hotkeys live `[A7]`.
   - Pet right-click → Hide Pet `[A4]`. What clicking the bar does: **unconfirmed**.
9. **Errors.**
   - Setup checks that the microphone and shortcut work before the first dictation
     (v0.19.3) `[A3]`.
   - A mic-delay guide covers AirPods wake-up lag `[A2]`.
   - What is shown when no speech is detected: **unconfirmed**.
10. **Settings surface.**
    - Show Floating Bar, Keybindings (+ Reset to Defaults), microphone picker with a
      blacklist, Transcription Model, Send Command, "Realtime always", Mute background
      audio, and Avoid Clipboard History `[A1][A2][A3]`.

## 3. Wispr Flow (secondary comparison)

1. **Activation.** **Hold Fn** for PTT `[W2]`. Hands-free is **Fn + Space** or a
   **double-press of Fn within 0.5 s**; press again to stop, and a third quick press
   cancels. A tap under 0.5 s does not paste `[W1][W2]`. Rebindable in Settings → General
   → Shortcuts `[W1]`.
2. **Flow Bar.** "A small floating bubble showing your dictation status: **resting,
   recording, or processing**". It is shown at rest once setup finishes. It sits at the
   bottom of the screen, above the Dock, and **follows the cursor's display**, not the
   focused window `[W3]`. It can be dragged to the left or right edge (2026-07-09) `[W6]`.
   Hovering shows a language picker and a Transforms wand. A mic switcher is "on the Flow
   bar" `[W6]`. Hands-free recording shows stop (■) and cancel (✕) `[W2]`. The colour and
   the level-meter style are **unconfirmed**.
3. **Text preview.** None is documented. Text appears after release `[W1]`.
4. **Processing.** The bar has a processing state `[W3]`; its visual is **unconfirmed**.
   Shortcuts are ignored while processing `[W2]`.
5. **Insert and no text field.** Clipboard + paste, with the old clipboard restored about
   0.5 s after the target app reads it. A failed insert shows a notice with the
   transcript, copies it, and offers **Copy** `[W1]`. **Paste Last Transcript** is ⌃⌘V,
   and History holds transcripts `[W1][W2]`.
6. **Cancel / undo.** **Esc** (remappable) or the bar's ✕. The cancellation notice offers
   **Undo**, which re-runs the transcript and pastes it `[W2]`. "Undo AI edit" in History
   shows the raw text `[W6]`. No undo of an insert.
7. **Sounds.** "Speak after the ping" `[W2]`. One desktop toggle silences the start, stop,
   paste, lock, and achievement sounds `[W5]`.
8. **Menu bar / Dock.** Menu-bar icon → Open Wispr Flow / Help / Support. "Show app in
   dock" is optional `[W7]`. **Clicking the bar starts recording**, and clicking again
   stops; a click within 0.5 s cancels `[W1]`.
9. **Errors.** With no audio or too-faint input, nothing is inserted and Flow shows
   warnings such as "Is your microphone muted?" `[W1]`. A silent mic is flagged as soon as
   recording starts (2026-10-09) `[W6]`. The 20-minute cap warns at 19 `[W2]`.
10. **Settings.** "Show Flow Bar at all times" (Settings → System), and a right-click "Hide
    for 1 hour" on the resting bar `[W3][W4]`.

## 4. superwhisper (secondary comparison)

1. **Activation.** **Toggle Recording**, default ⌥Space: press to start and again to stop
   `[S1][S7]`. A separate **Push to Talk** shortcut: hold to record, and "a quick tap acts
   as toggle". A mouse click toggles and a hold is PTT `[S1]`.
2. **Indicator.** The recording window has a live waveform, the mode, **Stop**, and
   **Cancel**, and it can shrink to a **mini window**. The mini window can stay on screen
   as an idle indicator: hover to start, change mode, or expand. While recording it shows
   the waveform, and hovering reveals Stop `[S2]`. Position: **unconfirmed**.
3. **Text preview.** Only with realtime-capable models, in the window `[S2]`.
4. **Processing.** The menu-bar dot is **yellow** while loading, **red** while recording,
   **blue** while processing, and **green** when done (then reverts) `[S4]`. No window
   processing visual is documented.
5. **Insert and no text field.** Paste at the cursor. If nothing pastes, the text is in
   History and on the clipboard `[S6]`. The window closes only after a successful paste
   unless "Always close" is on `[S3]`. The docs **contradict** each other on the
   clipboard default: "replaces" `[S3]` versus "Keep what I have copied" (restore) `[S6]`.
   "Simulate keypresses" is experimental `[S3]`.
6. **Cancel / undo.** **Esc** or Cancel. Recordings under 30 s cancel at once; longer ones
   ask first `[S2]`. No undo of an insert is documented.
7. **Sounds.** Start/stop **Sound Effects** with separate volumes, or off. "Sound while
   recording" defaults to **Pause** for other audio `[S1]`.
8. **Menu bar / Dock.** A menu-bar icon with the status dot. "Start Recording on Menubar
   Click" and "Show in Dock" are optional `[S3][S4]`. Right-clicking the mini window
   opens Expand / Settings / History `[S2]`.
9. **Errors.** "**No voice found in recording**" is shown in History and is almost always
   an input problem `[S5]`. "Silence Removal" (recommended) guards against hallucinated
   text `[S1]`.
10. **Settings.** Sound effects, Silence Removal, Sound while recording, Always close,
    Paste result text, clipboard behaviour, and Show in Dock `[S1][S3]`.

## 5. Comparison table

"?" means unconfirmed. Typwrtr today is the column on the right.

| Point | Typeless | Aqua Voice | Wispr Flow | superwhisper | Typwrtr today |
|---|---|---|---|---|---|
| Default key | Fn | Fn | Fn | ⌥Space (toggle) | ⌃⇧D |
| Hold / toggle | Toggle now; hold in May 2026 docs | Hold; release or tap commits | Hold | Separate toggle and PTT keys | Hold |
| Hands-free | Was Fn+Space (now Ask anything) | Double-press, or hold + Space | Double-press, or Fn+Space | Toggle key, or PTT quick tap | Focus Dictation (armed mode) |
| Pill exists | Yes, "Voice bar" | Yes, "Floating Bar" (or Pet) | Yes, "Flow Bar" | Window or mini window | Yes, 132×28 |
| Pill at idle | ? | Likely (has hide toggle) | Yes (after setup) | Optional | No |
| Position | Bottom centre (demo) | Bottom | Bottom, above Dock; cursor's display; left/right dock | ? | Bottom centre, target app's screen |
| Level meter | White bars, flat dots at silence | Orb + white bars | ? | Waveform | 9 white bars |
| Controls on pill | ✕ / ✓ | ? | Mic switcher; hover: language, wand; ■ / ✕ hands-free | Stop / Cancel | None |
| Live text | Not documented (demo card ambiguous) | Realtime Mode only (Max) | No | Realtime models only | No (Q11) |
| Processing visual | "Thinking" shimmer in pill | ? | Bar "processing" state | Blue menu-bar dot | Menu-bar icon only |
| Insert | Paste (needs AX); restore ? | Paste + clipboard restore | Paste + clipboard restore | Paste; restore default disputed | AX → paste (§0) |
| Paste-last hotkey | ? | ⌃⌘V | ⌃⌘V | ? | None |
| Insert failed | History; a "card" (trigger ?) | ? | Notice + Copy; clipboard | History + clipboard; window stays | Clipboard, then buffer preview (§7) |
| History | Local, Forever…Never | Local, audio 3 days | Yes, with retry | Yes | None (§10) |
| Cancel | ✕; Esc (May 2026 docs) | ? | Esc, ✕, click bar <0.5 s | Esc; confirm if >30 s | None (no Esc handler) |
| Undo insert | No | No (host ⌘Z) | No ("Undo" = retry) | No | **Yes, ⌃⇧Z** |
| Start/stop sound | Yes, toggle | ? (sounds setting exists) | Yes ("ping"), toggle | Yes, volume or off | None |
| Duck other audio | Mute when dictating | Mute background (default on) | ? | Pause (default) | No |
| No speech | ? | ? | "Is your microphone muted?" | "No voice found" in History | Silent idle (Q24) |
| Menu bar / Dock | Both; Dock optional | Both; Dock hideable | Both; Dock optional | Both; Dock optional | Menu bar |
| Click pill | ✕ / ✓ buttons | Pet: right-click Hide | Click = start/stop | Hover: start / stop | Not interactive |

## 6. Patterns

### What all or most do (the convention a switcher expects)

1. **Fn is the default key** in three of the four apps (Typeless, Aqua, Wispr).
   superwhisper uses ⌥Space.
2. **One key does two jobs.** Hold means push-to-talk, and a double-press or a quick tap
   means hands-free or toggle: Wispr (double-press within 0.5 s), Aqua (double-press),
   and superwhisper (a quick tap on the PTT key toggles). Nobody needs a mode setting to
   go hands-free.
3. **A small capsule near the bottom of the screen** while recording: Typeless (black,
   with level bars), Aqua (black, or glass with orb and bars), and Wispr (a "small
   floating bubble"; colour and meter undocumented). superwhisper uses a window that can
   shrink to a mini indicator.
4. **The pill carries the processing state** in two of the four: Typeless ("Thinking")
   and Wispr (a documented processing state). Aqua is unconfirmed. superwhisper documents
   only a blue menu-bar dot, the same approach Typwrtr takes.
5. **A resting idle pill** that can be hidden: Wispr (shown by default), Aqua (likely),
   and superwhisper (optional). Typeless is unknown.
6. **Esc cancels a recording**: Wispr, superwhisper, and Typeless (May 2026 docs). For
   Aqua it is unconfirmed. Several also put a ✕ on the pill.
7. **Start/stop sounds with an off switch**: Typeless, Wispr, and superwhisper. Aqua has a
   sounds setting, but its start/stop cues are unconfirmed.
8. **Other audio is muted or paused while dictating**: Typeless, Aqua (on by default), and
   superwhisper (Pause by default).
9. **A local history with copy and retry** is the safety net for failed inserts: all four.
10. **Clipboard paste, with the clipboard restored** (Aqua and Wispr confirmed;
    superwhisper's docs disagree; Typeless unconfirmed), plus a **Paste Last Transcript**
    hotkey. Aqua and Wispr both use **⌃⌘V**, so that is a de facto binding.
11. **No live text by default.** Live words appear only behind a paid or model-specific
    "Realtime" option (Aqua Max, superwhisper realtime models). This matches Typwrtr Q11.

### Where they differ

- **Hold vs toggle as the documented first-run flow.** Aqua and Wispr teach hold.
  Typeless's current docs teach tap–speak–tap, and superwhisper's quickstart teaches the
  ⌥Space toggle.
- **Pill controls.** Typeless shows ✕ and ✓ on the recording pill, and Wispr reveals
  controls on hover. Aqua's documented controls are status chips only ("Try rephrasing").
- **Position.** Wispr follows the *cursor's* display and can dock left or right. The others
  are not documented beyond "bottom".
- **No-speech feedback.** Wispr warns explicitly ("Is your microphone muted?") and now
  flags a silent mic at start. superwhisper logs "No voice found" to History. Typeless and
  Aqua: unknown.
- **Personality.** Aqua Pet (gamified, opt-in) versus everyone else's neutral capsule.
- **Undo.** No competitor reverses an insert. "Undo" means *restore the raw transcript*
  (Aqua, Wispr) or *re-run a cancelled one* (Wispr). Typwrtr's ⌃⇧Z is ahead of the
  convention here.

## 7. Implications for Typwrtr (grilling input)

Typwrtr today is the right-hand column of §5. Each item below is a question for the
grilling session, not a decision. "Fit" is a first read against the goal "simplest UI,
highest quality".

**Already aligned (no gap):** no live text (Q11) matches every default flow. The
bottom-centre capsule with a level meter matches the convention. The pill lives on the
target app's screen, which is close to Wispr's cursor-display rule. Undo of the insert is
*ahead of* every competitor.

1. **Processing state in the pill (Q1–Q2, Q40).** Typeless ("Thinking") and Wispr
   keep the pill through processing; Aqua is unconfirmed. Typwrtr hides the pill on
   release, as superwhisper does, and the only signal is the menu-bar icon, far from where
   the user is looking.
   - Option: keep the same pill after release with a "working" treatment, such as bars
     collapsing into a shimmer or pulse, and hide it on insert.
   - Fit: **high**. It adds no new surface, and the existing pill simply lives a little
     longer.
   - Open question: how long does release → insert take today? Measure it per mode before
     deciding. If it is mostly short, a pill that flashes for a moment could be noise.
2. **Esc to cancel while recording.** This is the convention in Wispr, superwhisper and
   Typeless (May 2026 docs). Typwrtr has no cancel gesture beyond releasing the key and then
   undoing.
   - Fit: **high**. It is invisible until needed.
   - Questions: should Esc be swallowed only while the mic is open? Should it also abort
     processing? Should Focus Dictation get the same binding?
3. **Start/stop sounds.** Three of the four have them, all with an off switch.
   - Fit: **mixed**. Sounds add a setting, but they help when the user's eyes are not on
     the pill.
   - Options: keep none; on by default; or only for Focus Dictation, where no key press
     confirms that the mic opened or closed.
4. **Default key / one key for hold and hands-free (Q15).** The convention is Fn, with
   hold for PTT and a double-press for hands-free.
   - Options: add **Fn** as a hotkey preset (Typeless needs a help page for Fn conflicts
     `[T13]`); and/or treat a **double-tap of the PTT chord** as a hands-free toggle.
   - Fit: **medium**. A double-tap could make the PTT/Focus choice less of a settings
     decision. But Focus Dictation is focus-gated and armed (Q4–Q5), which is not the same
     thing as competitors' hands-free toggle, so it would not replace it one for one.
5. **Resting idle pill.** Wispr shows one by default, Aqua likely does, and superwhisper
   offers one.
   - Fit: **low**. The menu-bar icon already shows idle, and a permanent overlay works
     against "simplest". Note that Wispr's resting bar doubles as a click-to-start target,
     which is useful only if clicking is wanted at all.
6. **Paste Last Transcript (§7, §10).** Aqua and Wispr both bind ⌃⌘V. Typwrtr already
   keeps a last-text buffer for Undo and failure recovery.
   - Option: a hotkey that re-pastes that buffer.
   - Fit: **medium**. It needs no visible UI, but it stretches §10's "discard once Undo no
     longer applies".
7. **History (§10).** All four keep one, and it is their universal safety net.
   - Fit: **conflicts** with Typwrtr's minimum-retention stance.
   - Question: is §7's clipboard/buffer path enough, or is an in-memory, session-only list
     acceptable?
8. **No-speech vs dead mic (Q24, Q27).** Typwrtr returns to idle silently. Wispr
   separates "no audio / too faint" ("Is your microphone muted?") from ordinary silence.
   `architecture.md` already notes that a dead microphone looks the same as silence.
   - Option: stay silent for "no speech", but surface "no input signal" (input level near
     zero across the whole capture).
   - Fit: **high quality, small UI**: one pill or menu-bar message, and only on a real
     fault.
9. **Controls on the pill.** Typeless shows ✕ and ✓, and Wispr reveals controls on hover.
   Typwrtr has none.
   - Fit: for PTT, **low**: the key is the control. For Focus Dictation, a ✕ (stop
     listening) might be the one click worth adding. Q40 currently says no controls.
10. **Ducking other audio.** Three of the four mute or pause media while dictating.
    - This is behaviour, not UI. Fit depends on whether it measurably helps recognition on
      euhadra/Earshot.
    - Question: default on, or off?
11. **Undo discoverability.** ⌃⇧Z is a differentiator nobody else has.
    - Question: is a hint needed (onboarding only?), or does adding one cost more
      simplicity than it buys?

## Sources

All first-party. Fetched 2026-10-18; a page or release date is given where the source
states one.

**Typeless**
- `[T1]` Dictate — https://www.typeless.com/help/quickstart/dictate
- `[T2]` Your first dictation (archived 2026-05-14; the live URL now returns 404) —
  https://web.archive.org/web/20260514105140/https://www.typeless.com/help/quickstart/first-dictation
- `[T3]` Settings — https://www.typeless.com/help/quickstart/settings
- `[T4]` History & Dictionary — https://www.typeless.com/help/quickstart/history-and-dictionary
- `[T5]` Where did my transcript go? — https://www.typeless.com/help/troubleshooting/missing-transcript
- `[T6]` Dictation limit — https://www.typeless.com/help/troubleshooting/dictation-limit
- `[T7]` Microphone unavailable — https://www.typeless.com/help/troubleshooting/microphone-unavailable
- `[T8]` Translate — https://www.typeless.com/help/quickstart/translate
- `[T9]` Help-centre demo video (embedded in `[T1]`; viewed frame by frame) —
  https://typeless-static.com/webpage/assets/help-center/quickstart/desktop-dictate-polished-writing.mp4
- `[T10]` Help me write, macOS v2.8.0 (2026-09-22) — https://www.typeless.com/help/release-notes/macos/use-help-me-write-desktop
- `[T11]` Ask anything — https://www.typeless.com/help/quickstart/ask-anything
- `[T12]` Check for updates (menu-bar icon) — https://www.typeless.com/help/troubleshooting/check-for-updates
- `[T13]` Keyboard conflicts — https://www.typeless.com/help/troubleshooting/system-setting-conflicts
- `[T14]` FAQs — https://www.typeless.com/help/faqs
- `[T15]` Installation and setup — https://www.typeless.com/help/installation-and-setup
- `[T16]` v0.9.0 release notes (2025-12-24) — https://www.typeless.com/help/release-notes/macos/personalized-smarter

**Aqua Voice**
- `[A1]` llms.txt — https://aquavoice.com/llms.txt
- `[A2]` FAQ — https://aquavoice.com/info/faq
- `[A3]` Changelog (entries 2025-03-27 to 2026-10-13) — https://aquavoice.com/changelog
- `[A4]` Aqua Pet — https://aquavoice.com/pet
- `[A5]` Multiple activation keys — https://aquavoice.com/guide/how-to-add-multiple-activation-keys
- `[A6]` History — https://aquavoice.com/guide/history
- `[A7]` Hide dock icon — https://aquavoice.com/guide/how-to-hide-dock-icon
- `[A8]` Edit Mode guide — https://aquavoice.com/guide/edit-mode
- `[A9]` Edit Mode page — https://aquavoice.com/edit-mode
- `[A10]` Introducing Send It — https://aquavoice.com/blog/introducing-send-it
- `[A11]` Liquid Glass changelog image — https://aquavoice.com/images/changelog/liquid-glass.png

**Wispr Flow**
- `[W1]` Starting your first dictation — https://docs.wisprflow.ai/articles/6409258247-starting-your-first-dictation
- `[W2]` Use Flow hands-free — https://docs.wisprflow.ai/articles/6391241694-Use-Flow-hands-free
- `[W3]` Move and dock the Flow Bar — https://docs.wisprflow.ai/articles/1790396454-move-and-dock-the-flow-bar-on-desktop
- `[W4]` Flow Bar troubleshooting — https://docs.wisprflow.ai/articles/5002934560-why-is-the-wispr-bar-is-not-appearing-or-disappearing
- `[W5]` Using Flow discreetly (sounds) — https://docs.wisprflow.ai/articles/9192039587-using-wispr-flow-discreetly-microphone-guide
- `[W6]` What's new (entries 2026-03-31 to 2026-10-09) — https://wisprflow.ai/whats-new
- `[W7]` Navigating the app — https://docs.wisprflow.ai/articles/5096240724-navigating-the-wispr-flow-app-desktop-ios-and-android

**superwhisper**
- `[S1]` Essential settings — https://superwhisper.com/docs/get-started/essential-settings
- `[S2]` Recording window — https://superwhisper.com/docs/get-started/interface-rec-window
- `[S3]` Advanced settings — https://superwhisper.com/docs/get-started/settings-advanced
- `[S4]` Menu bar icon — https://superwhisper.com/docs/get-started/interface-menu-bar
- `[S5]` No voice found — https://superwhisper.com/docs/common-issues/no-voice-found
- `[S6]` Pasting issues — https://superwhisper.com/docs/common-issues/pasting-issues
- `[S7]` Quickstart — https://superwhisper.com/docs/get-started/quickstart

# Typwrtr — Use Cases

Status: **prioritisation in progress**. Product constraints: [`product.md`](./product.md).

Goal: pick a **wedge** for MVP (one primary job), then a short ordered backlog. Everything else stays explicit non-goals until promoted.

## How to prioritise

Score each case lightly (1–3) on:

- **Local-fit** — works fully on-device without apology  
- **Non-dev UX** — clear without terminal knowledge  
- **Differentiator** — euhadra cleanup / JA quality / price matters  
- **Shell cost** — needs only hotkey + insert vs deep Accessibility / IME / IDE hooks  

MVP wedge ≈ high local-fit + non-dev UX, moderate shell cost.

## Candidate catalogue

| ID | Use case | User job | Notes / deps |
|---|---|---|---|
| U1 | **Anywhere dictation** | Speak into whatever has focus (Slack, Mail, Notes, browser) | Core Aqua/TYPELESS loop. Hotkey + clipboard/paste or key insert. |
| U2 | **Chat / short reply** | Fast casual messages; tolerate imperfect punctuation | Short utterances; latency sensitive; light cleanup. |
| U3 | **Email / long prose** | Paragraphs with punctuation and filler removal | Tier 1+2 matter; optional later tone pass. |
| U4 | **Notes / brain dump** | Capture then lightly structure (paragraphs, lists) | ParagraphSplitter; avoid over-formatting. |
| U5 | **Search bar / URL bar** | Short queries, minimal punctuation | Field-type awareness (Accessibility). |
| U6 | **Code comments / commit messages** | Technical vocabulary, English or JA | Custom dictionary / phoneme corrector; IDE focus. |
| U7 | **Terminal commands** | Spoken shell lines (dangerous) | High risk; probably post-MVP / opt-in only. |
| U8 | **Voice → structured note** | Meeting-ish dump → bullets / title | See § Realization notes. |
| U9 | **Correct last insertion** | “Undo” or re-speak replacement | Emitter undo + UX affordance. |
| U10 | **Whisper / quiet speech** | Dictate without disturbing others | See § Realization notes. |
| U11 | **Offline travel / air-gap** | No network ever after model install | Packaging + no telemetry; trust story. |
| U12 | **Bilingual JA↔EN day** | Mix languages in one session | See § Realization notes. |

## Working hypothesis (not locked)

**MVP wedge: U1** (anywhere dictation). Keep the pipeline generic enough that chat/mail improve “for free,” but **do not tune or market U2/U3 as early milestones**.

| Tier | IDs | Intent |
|---|---|---|
| MVP | **U1**, then **U9** | Dictate anywhere; undo last insert |
| Soon after | U4, U5, light U6 | Notes / search-field awareness / dictionary — only if cheap |
| Later | **U2, U3, U11** | Chat/mail polish and hard offline packaging — after the wedge is real |
| Research / post | **U8, U10, U12**, U7 | Need design choices below; not MVP |

## Realization notes (U8 / U10 / U12)

### U8 — Voice → structured note

**User job:** dump speech (meeting-ish / brain dump) and get title + bullets / sections, not a flat paragraph.

**Layers:**

1. **Capture** — same mic session as U1 (possibly longer; VAD end or explicit stop).
2. **Clean** — euhadra Tier 1+2 (fillers, self-repair, punctuation). Optional `ParagraphSplitter` for topic breaks (euhadra already has this; it detects *topic shifts*, not authorial paragraph taste).
3. **Structure** — needs a **structuring step** euhadra does not fully own today:
   - **Light (local, no LLM):** heuristics — split on paragraph markers / depth valleys → markdown bullets; first sentence as title. Good enough for “notes,” weak for “meeting minutes.”
   - **Medium (on-device LLM):** `LlmRefiner` / Apple Foundation Models / llama.cpp with a fixed schema prompt (`title`, `bullets[]`). Matches euhadra Phase-2 “Voice Memo → Structured Notes” direction; Typwrtr owns the UI (preview → insert/copy).
   - **Heavy:** speaker diarization, action-item extraction — out of scope unless we pull new models; do not pretend U8 includes this without a separate decision.

**Product UX:** probably not silent insert into Slack. Better as a **Notes mode** (menu / second hotkey) → preview sheet → Copy / Insert. Emitter may target Notes app or clipboard markdown.

**Dependency risk:** without Tier 3 (or a small structured model), U8 collapses to U4. Ship U4 first if we only want light structure.

### U10 — Whisper / quiet speech

**User job:** dictate at whisper volume without bothering others (Wispr-style).

**This is mostly acoustics + ASR robustness, not a pipeline stage:**

1. **Mic path** — prefer headset/AirPods when present; avoid AGC that boosts room noise into garbage; optional “whisper mode” that raises input gain carefully (measure clipping).
2. **ASR** — some models degrade badly on whispered speech; others cope. Need **measured** WER/CER on whispered JA/EN fixtures before promising. Candidates: keep default model vs a whisper-tuned / more robust runtime from euhadra’s router.
3. **UX** — mode toggle or auto (SNR heuristic). Visual “whisper mode on” so users know why quality changed.
4. **Not** the OpenAI Whisper product name — avoid UI copy collision; call it “Quiet mode” / 「ひそひそモード」 in product text.

**Dependency risk:** cannot schedule from architecture alone — needs a small whispered-speech eval set. Until measured, treat as experimental flag.

### U12 — Bilingual JA↔EN day

**User job:** one workday mixing Japanese and English without manually switching language every utterance.

**Approaches (increasing fidelity):**

1. **Manual mode** — menu / hotkey cycles `ja` / `en` / `auto`. Honest MVP; low shell cost. euhadra adapters already take a language hint (`with_language` / router `AdapterRequest.language`).
2. **Session-level auto** — short LID (language ID) on the first 1–2 s or on the full utterance, then dispatch via euhadra `AsrRouter` to ja vs en model (e.g. Parakeet-ja vs Parakeet-en). Typwrtr owns the policy table (which runtime per lang); euhadra owns factories.
3. **Intra-utterance code-switch** — “今日の deadline は Friday” in one breath. Hard: most ASR stacks want one language per pass. Options: (a) multilingual model (Whisper-class) with auto LID; (b) dual-pass + merge (expensive, error-prone); (c) accept one dominant language per utterance and document the limit.

**Cleanup:** Tier 1/2 filters are language-specific (JA filler vs EN filler). Wrong language → bad cleanup. So LID must feed **both** ASR and filter/processor selection.

**Dependency risk:** euhadra router is “language already chosen upstream” today — Typwrtr (or a thin policy crate) must own LID + mapping. True mid-sentence code-switch is a research-ish goal; product promise should start as **per-utterance** language.

## Decision log

| Date | Decision |
|---|---|
| 2026-08-06 | Catalogue created; prioritisation pending with product owner. |
| 2026-08-07 | Push **U2 / U3 / U11** later; keep MVP = **U1** (+ **U9**). Document realization paths for **U8 / U10 / U12**. |

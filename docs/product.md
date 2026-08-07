# Typwrtr — Product Decisions

Status: **agreed** (consultation 2026-08-06; UX grilling 2026-08-07).  
Update this file when a decision changes; do not leave divergent copies in chat-only notes.

UX / interaction details: **[`ux-decisions.md`](./ux-decisions.md)** (SSOT for hotkeys, Free/PTT, insertion failure, privacy UI).

## 1. What it is

**Typwrtr** (vowels dropped from “typewriter”) is a local-first voice dictation **product**: hold a hotkey, speak, release, and cleaned text lands in the focused field.

It is the end-user app in the same space as Aqua Voice / TYPELESS / Wispr Flow. The transcription and text-cleanup engine is **[euhadra](https://github.com/penta2himajin/euhadra)** (programmable ASR framework, crates.io `euhadra` **0.2.0**). Typwrtr owns activation, permissions UX, insertion, settings, model packaging, and distribution.

| Layer | Responsibility |
|---|---|
| **euhadra** | Accurate listening: ASR adapters, Tier 1 filters, Tier 2 processors, optional refinement traits |
| **Typwrtr** | Product experience: menu bar, hotkeys, Accessibility, paste/inject, onboarding, curated models |

OS-specific code lives in Typwrtr. Useful pieces may later be upstreamed to euhadra as reference shell implementations—not the other way around for product UX.

**Not an IME.** Text insertion is Accessibility and/or clipboard+paste (see [`ux-decisions.md`](./ux-decisions.md) §0).

## 2. Audience

Primary: **local-first users in general** (privacy / offline / on-device preference), including non-developers.

- Do not require building from source, locating `whisper-cli`, or editing config files for the happy path.
- Multiple use cases are expected; prioritisation lives in [`use-cases.md`](./use-cases.md).

## 3. Platforms & shell

| Priority | Platform | UI shell |
|---|---|---|
| 1 (MVP) | macOS, Apple Silicon | **Swift** native (menu bar) + Rust core via **UniFFI** |
| Later | Windows | **WinUI** native + same UniFFI core |
| Non-goal (MVP) | Linux desktop app, iOS/Android | — |

Rationale: best-in-class permissions, hotkeys, and Accessibility per OS. Shared logic stays in Rust (Typwrtr core crate calling euhadra).

**Signing:** Apple Developer Program may be absent early. Notarised builds are the paid-distribution path. Until then, an installer that clears quarantine (or documented Gatekeeper steps) is acceptable for dogfood. Prefer joining the Program before marketing to non-developers.

## 4. Licensing & money (Option A)

| Artifact | License / terms |
|---|---|
| Source (core + app sources intended public) | **MIT** and/or **Apache-2.0**, aligned with euhadra (`MIT OR Apache-2.0`) |
| Notarised `.dmg` from the marketing page | **$5 one-time** purchase |

- No “Plus” tier. No feature paywall inside the app.
- No in-app license checks, accounts, or device binding.
- $5 buys **convenient access** to the notarised binary (and re-download), not exclusive rights to the software. Source remains free to build.
- Payment / delivery: **Gumroad** first (library access, **unlimited re-downloads** for a purchase). **Booth** optional later for Japan.
- App updates (e.g. Sparkle) may stay public; do not gate updates behind identity just to fight sharing.
- Update **check** may run (pull); no telemetry — see [`ux-decisions.md`](./ux-decisions.md) §10.

Rejected alternatives (kept for history): AGPL/GPL dual-license + proprietary app; source-available “org use forbidden”; $1 price (fees + support math are poor).

## 5. Competitive stance

Win on: local-by-default, Japanese (and CJK) cleanup quality via euhadra, simple activation, and price of the official build—not on closing the source or blocking internal forks.

Commoditise “dictation that just works”; do not chase every cloud SaaS feature in MVP.

## 6. MVP success sketch

Aligned with [`use-cases.md`](./use-cases.md) and [`ux-decisions.md`](./ux-decisions.md):

- **U1** PTT dictation into the focused field; menu-bar state only (no interim text HUD).
- **U9** Undo last (buffer-backed).
- Default path: no cloud account, no LLM, no IME.
- First-run wizard: mode, permissions, language(+model), launch-at-login.
- Free/VAD: after PTT dogfood (or earlier if pulled forward); strict focus gate + visible unavailability.
- Latency targets: measure before claiming.

## 7. Repo hygiene

- Dedicated public GitHub repo: https://github.com/penta2himajin/typwrtr (`origin`). Former `templates` remote kept as `templates` for history only.
- Implementation layout: [`architecture.md`](./architecture.md).

## 8. Open follow-ups

1. Exact SPDX dual files at repo root if adopting `MIT OR Apache-2.0` everywhere.
2. Landing-page copy and Gumroad product setup (post-dogfood).
3. Confirm audio-capture placement (Swift vs euhadra `mic`) during PTT impl — see architecture decision log.

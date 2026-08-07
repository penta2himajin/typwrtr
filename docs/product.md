# Typwrtr — Product Decisions

Status: **agreed** (consultation, 2026-08-06).  
Update this file when a decision changes; do not leave divergent copies in chat-only notes.

## 1. What it is

**Typwrtr** (vowels dropped from “typewriter”) is a local-first voice dictation **product**: hold a hotkey, speak, release, and cleaned text lands in the focused field.

It is the end-user app in the same space as Aqua Voice / TYPELESS / Wispr Flow. The transcription and text-cleanup engine is **[euhadra](https://github.com/penta2himajin/euhadra)** (programmable ASR framework). Typwrtr owns activation, permissions UX, insertion, settings, model packaging, and distribution.

| Layer | Responsibility |
|---|---|
| **euhadra** | Accurate listening: ASR adapters, Tier 1 filters, Tier 2 processors, optional refinement traits |
| **Typwrtr** | Product experience: menu bar, hotkeys, Accessibility, paste/inject, onboarding, curated models |

OS-specific code lives in Typwrtr. Useful pieces may later be upstreamed to euhadra as reference shell implementations—not the other way around for product UX.

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
| Source (core + app sources intended public) | **MIT** and/or **Apache-2.0**, aligned with euhadra when published |
| Notarised `.dmg` from the marketing page | **$5 one-time** purchase |

- No “Plus” tier. No feature paywall inside the app.
- No in-app license checks, accounts, or device binding.
- $5 buys **convenient access** to the notarised binary (and re-download), not exclusive rights to the software. Source remains free to build.
- Payment / delivery: **Gumroad** first (library access, **unlimited re-downloads** for a purchase). **Booth** optional later for Japan.
- App updates (e.g. Sparkle) may stay public; do not gate updates behind identity just to fight sharing.

Rejected alternatives (kept for history): AGPL/GPL dual-license + proprietary app; source-available “org use forbidden”; $1 price (fees + support math are poor).

## 5. Competitive stance

Win on: local-by-default, Japanese (and CJK) cleanup quality via euhadra, simple activation, and price of the official build—not on closing the source or blocking internal forks.

Commoditise “dictation that just works”; do not chase every cloud SaaS feature in MVP.

## 6. MVP success sketch (to refine with use cases)

- Hold-to-talk → text in the focused field without opening a special window for the main path.
- Default path needs no cloud account and no LLM.
- Japanese fillers / self-corrections are cleaned enough to paste into chat or mail.
- First-run: mic + Accessibility explained without developer jargon.
- Latency targets: measure before claiming; do not invent SLOs here yet.

## 7. Repo hygiene (pending)

This tree started as a copy of `templates`. Still to do outside this doc:

- Point `origin` at a dedicated Typwrtr GitHub repo (not `templates.git`).
- Replace template README / project `AGENTS.md` placeholders with product text (in progress alongside this file).
- Add real crate / Xcode layout when implementation starts.

## 8. Open follow-ups

1. Prioritise use cases → [`use-cases.md`](./use-cases.md).
2. UniFFI surface for MVP (record / stop / cancel / emit / settings).
3. Exact SPDX choice (MIT vs Apache-2.0 vs dual) to match published euhadra (`euhadra` **0.2.0** on crates.io as of 2026-08-07).
4. Landing-page copy and Gumroad product setup (post-MVP dogfood).

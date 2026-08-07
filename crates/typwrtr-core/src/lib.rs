//! Typwrtr core: PTT session + euhadra dictation pipeline.
//!
//! Emission (Accessibility / clipboard) stays in the Swift shell.
//! See `docs/architecture.md`.

#![deny(missing_docs)]

uniffi::setup_scaffolding!();

mod asr;
mod engine;
mod ffi;
mod session;

pub use asr::FixedAsr;
pub use engine::{DictationEngine, EngineError, SharedEngine};
pub use ffi::{FfiError, FfiLanguage, FfiStatus, PttSession};
pub use session::{Session, SessionError, SessionStatus};

pub use euhadra::types::{AudioChunk, Language};

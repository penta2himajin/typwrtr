//! Typwrtr core: PTT session + euhadra dictation pipeline.
//!
//! Emission (Accessibility / clipboard) stays in the Swift shell.
//! See `docs/architecture.md`.

#![deny(missing_docs)]

uniffi::setup_scaffolding!();

mod asr;
mod engine;
mod ffi;
mod paths;
mod session;

pub use asr::FixedAsr;
pub use engine::{DictationEngine, EngineError, SharedEngine};
pub use ffi::{FfiError, FfiLanguage, FfiStatus, PttSession};
pub use paths::{
    resolve_whisper_from_env, resolve_whisper_paths, whisper_language_tag, whisper_model_path,
};
pub use session::{Session, SessionError, SessionStatus};

pub use euhadra::types::{AudioChunk, Language};

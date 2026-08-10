//! Typwrtr core: PTT session + euhadra dictation pipeline.
//!
//! Emission (Accessibility / clipboard) stays in the Swift shell.
//! See `docs/architecture.md`.

#![deny(missing_docs)]

uniffi::setup_scaffolding!();

mod asr;
mod dictionary;
mod engine;
mod ffi;
mod free_mode;
mod paths;
mod session;
#[cfg(test)]
mod test_audio;

pub use asr::FixedAsr;
pub use dictionary::{dictionaries_dir, dictionary_path, DictionaryLoad, StoredTerm};
pub use engine::{Dictated, DictationEngine, EngineError, SharedEngine};
pub use ffi::{
    load_term_dictionary, save_term_dictionary, term_dictionary_path, FfiCaptureMetrics,
    FfiDictionarySnapshot, FfiError, FfiLanguage, FfiStatus, FfiTermEntry, PttSession,
};
pub use free_mode::{FocusKind, FreeArmState, FreeAvailability, FreeController};
pub use paths::{
    resolve_whisper_from_env, resolve_whisper_paths, whisper_language_tag, whisper_model_path,
};
pub use session::{CaptureMetrics, Session, SessionError, SessionStatus};

pub use euhadra::types::{AudioChunk, Language};

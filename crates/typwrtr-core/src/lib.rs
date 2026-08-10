//! Typwrtr core: PTT session + euhadra dictation pipeline.
//!
//! Emission (Accessibility / clipboard) stays in the Swift shell.
//! See `docs/architecture.md`.

#![deny(missing_docs)]

uniffi::setup_scaffolding!();

mod asr;
mod dictionary;
mod endpoint;
mod engine;
mod ffi;
mod free_mode;
mod paths;
mod session;
mod stream_gate;
#[cfg(test)]
mod test_audio;

pub use asr::FixedAsr;
pub use dictionary::{dictionaries_dir, dictionary_path, DictionaryLoad, StoredTerm};
pub use engine::{Dictated, DictationEngine, EngineError, SharedEngine};
pub use endpoint::{
    speech_start_keep_len, FOCUS_DICTATION_SILENCE_MS, SPEECH_START_PAD_SAMPLES,
    STREAMING_PTT_SILENCE_MS,
};
pub use ffi::{
    focus_dictation_silence_seconds, load_term_dictionary, save_term_dictionary,
    should_accept_stream_result, streaming_ptt_silence_seconds, term_dictionary_path,
    FfiCaptureMetrics, FfiDictionarySnapshot, FfiError, FfiLanguage, FfiStatus, FfiTermEntry,
    PttSession,
};
pub use free_mode::{FocusKind, FreeArmState, FreeAvailability, FreeController};
pub use paths::{
    resolve_whisper_from_env, resolve_whisper_paths, whisper_language_tag, whisper_model_path,
};
pub use session::{CaptureMetrics, Session, SessionError, SessionStatus};

pub use euhadra::types::{AudioChunk, Language};

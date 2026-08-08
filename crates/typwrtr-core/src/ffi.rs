//! UniFFI surface for the macOS shell (PTT dogfood).

use std::sync::Arc;

use euhadra::types::AudioChunk;
use tokio::runtime::Runtime;
use tokio::sync::Mutex;

use crate::asr::FixedAsr;
use crate::engine::DictationEngine;
use crate::session::{CaptureMetrics, Session, SessionError, SessionStatus};
use crate::Language;

/// Languages exposed across the FFI boundary (euhadra `Language` set).
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiLanguage {
    /// English (`en`).
    English,
    /// Japanese (`ja`).
    Japanese,
    /// Chinese (`zh`).
    Chinese,
    /// Korean (`ko`).
    Korean,
    /// Spanish (`es`).
    Spanish,
}

impl From<FfiLanguage> for Language {
    fn from(value: FfiLanguage) -> Self {
        match value {
            FfiLanguage::English => Language::English,
            FfiLanguage::Japanese => Language::Japanese,
            FfiLanguage::Chinese => Language::Chinese,
            FfiLanguage::Korean => Language::Korean,
            FfiLanguage::Spanish => Language::Spanish,
        }
    }
}

/// Menu-bar icon states.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiStatus {
    /// Idle.
    Idle,
    /// Recording.
    Recording,
    /// Processing.
    Processing,
    /// Error.
    Error,
}

impl From<SessionStatus> for FfiStatus {
    fn from(value: SessionStatus) -> Self {
        match value {
            SessionStatus::Idle => Self::Idle,
            SessionStatus::Recording => Self::Recording,
            SessionStatus::Processing => Self::Processing,
            SessionStatus::Error => Self::Error,
        }
    }
}

/// How much of the last capture was speech (debug measurement, Q27).
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct FfiCaptureMetrics {
    /// Samples the shell pushed.
    pub pushed_samples: u64,
    /// Of those, samples the detector classified as speech.
    pub speech_samples: u64,
    /// Rate the chunks declared.
    pub sample_rate: u32,
}

impl From<CaptureMetrics> for FfiCaptureMetrics {
    fn from(value: CaptureMetrics) -> Self {
        Self {
            pushed_samples: value.pushed_samples,
            speech_samples: value.speech_samples,
            sample_rate: value.sample_rate,
        }
    }
}

/// FFI-visible error.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Error, thiserror::Error)]
pub enum FfiError {
    /// Session or engine failure.
    #[error("{msg}")]
    Message {
        /// Detail.
        msg: String,
    },
}

impl From<SessionError> for FfiError {
    fn from(value: SessionError) -> Self {
        Self::Message {
            msg: value.message().to_string(),
        }
    }
}

/// Thread-safe PTT handle for Swift.
#[derive(uniffi::Object)]
pub struct PttSession {
    runtime: Runtime,
    inner: Mutex<Session>,
}

#[uniffi::export]
impl PttSession {
    /// Build a session whose ASR always returns `fixed_transcript` (then Tier 1+2 run).
    ///
    /// Dogfood / UI development without on-disk models.
    #[uniffi::constructor]
    pub fn with_fixed_transcript(
        language: FfiLanguage,
        fixed_transcript: String,
    ) -> Result<Arc<Self>, FfiError> {
        let engine = DictationEngine::new(language.into(), FixedAsr::new(fixed_transcript))
            .map_err(|e| FfiError::Message {
                msg: e.message().to_string(),
            })?;
        ptt_session_from_engine(engine)
    }

    /// Build a session using whisper.cpp via euhadra `WhisperLocal`.
    #[uniffi::constructor]
    pub fn with_whisper_local(
        language: FfiLanguage,
        cli_path: String,
        model_path: String,
    ) -> Result<Arc<Self>, FfiError> {
        let engine = DictationEngine::with_whisper_local(language.into(), cli_path, model_path)
            .map_err(|e| FfiError::Message {
                msg: e.message().to_string(),
            })?;
        ptt_session_from_engine(engine)
    }

    /// Build WhisperLocal from `TYPWRTR_WHISPER_CLI` / `WHISPER_CLI` and model dir env vars.
    #[uniffi::constructor]
    pub fn with_whisper_from_env(language: FfiLanguage) -> Result<Arc<Self>, FfiError> {
        let engine = DictationEngine::with_whisper_from_env(language.into()).map_err(|e| {
            FfiError::Message {
                msg: e.message().to_string(),
            }
        })?;
        ptt_session_from_engine(engine)
    }

    /// Build a session using euhadra `ParakeetAdapter` (ONNX).
    #[uniffi::constructor]
    pub fn with_parakeet(language: FfiLanguage, model_dir: String) -> Result<Arc<Self>, FfiError> {
        let engine = DictationEngine::with_parakeet(language.into(), model_dir).map_err(|e| {
            FfiError::Message {
                msg: e.message().to_string(),
            }
        })?;
        ptt_session_from_engine(engine)
    }

    /// Build Parakeet-ja from `TYPWRTR_PARAKEET_JA_DIR` / conventional paths.
    #[uniffi::constructor]
    pub fn with_parakeet_ja_from_env(language: FfiLanguage) -> Result<Arc<Self>, FfiError> {
        let engine = DictationEngine::with_parakeet_ja_from_env(language.into()).map_err(|e| {
            FfiError::Message {
                msg: e.message().to_string(),
            }
        })?;
        ptt_session_from_engine(engine)
    }

    /// Build using euhadra `CanaryAdapter` (en / es).
    #[uniffi::constructor]
    pub fn with_canary(language: FfiLanguage, model_dir: String) -> Result<Arc<Self>, FfiError> {
        let engine = DictationEngine::with_canary(language.into(), model_dir).map_err(|e| {
            FfiError::Message {
                msg: e.message().to_string(),
            }
        })?;
        ptt_session_from_engine(engine)
    }

    /// Build using euhadra `ParaformerAdapter` (zh).
    #[uniffi::constructor]
    pub fn with_paraformer_zh(
        language: FfiLanguage,
        model_dir: String,
    ) -> Result<Arc<Self>, FfiError> {
        let engine =
            DictationEngine::with_paraformer_zh(language.into(), model_dir).map_err(|e| {
                FfiError::Message {
                    msg: e.message().to_string(),
                }
            })?;
        ptt_session_from_engine(engine)
    }

    /// Build using euhadra `SenseVoiceAdapter` (ko).
    #[uniffi::constructor]
    pub fn with_sensevoice(
        language: FfiLanguage,
        model_dir: String,
    ) -> Result<Arc<Self>, FfiError> {
        let engine = DictationEngine::with_sensevoice(language.into(), model_dir).map_err(|e| {
            FfiError::Message {
                msg: e.message().to_string(),
            }
        })?;
        ptt_session_from_engine(engine)
    }

    /// Current status.
    pub fn status(&self) -> FfiStatus {
        self.runtime
            .block_on(async { self.inner.lock().await.status().into() })
    }

    /// Last retained text (success or failure preview).
    pub fn last_text(&self) -> Option<String> {
        self.runtime
            .block_on(async { self.inner.lock().await.last_text().map(str::to_string) })
    }

    /// What the detector made of the last capture. Debug measurement only.
    pub fn last_capture_metrics(&self) -> Option<FfiCaptureMetrics> {
        self.runtime
            .block_on(async { self.inner.lock().await.last_metrics().map(Into::into) })
    }

    /// Start PTT.
    pub fn start_ptt(&self) -> Result<(), FfiError> {
        self.runtime
            .block_on(async { self.inner.lock().await.start_ptt().map_err(Into::into) })
    }

    /// Push mono PCM f32 samples captured by the shell.
    pub fn push_pcm_f32(&self, samples: Vec<f32>, sample_rate: u32) -> Result<(), FfiError> {
        let chunk = AudioChunk {
            samples,
            sample_rate,
            channels: 1,
        };
        self.runtime.block_on(async {
            self.inner
                .lock()
                .await
                .push_audio(chunk)
                .map_err(Into::into)
        })
    }

    /// Stop PTT and return cleaned text.
    pub fn stop_ptt(&self) -> Result<String, FfiError> {
        self.runtime
            .block_on(async { self.inner.lock().await.stop_ptt().await.map_err(Into::into) })
    }

    /// Cancel in-flight capture/processing.
    pub fn cancel(&self) -> Result<(), FfiError> {
        self.runtime
            .block_on(async { self.inner.lock().await.cancel().map_err(Into::into) })
    }

    /// Clear undo / preview buffer.
    pub fn clear_buffer(&self) {
        self.runtime
            .block_on(async { self.inner.lock().await.clear_buffer() })
    }

    /// Take the undo payload (clears the text buffer).
    pub fn take_undo_payload(&self) -> Option<String> {
        self.runtime
            .block_on(async { self.inner.lock().await.take_undo_payload() })
    }
}

fn ptt_session_from_engine(engine: DictationEngine) -> Result<Arc<PttSession>, FfiError> {
    let runtime = Runtime::new().map_err(|e| FfiError::Message {
        msg: format!("tokio runtime: {e}"),
    })?;
    Ok(Arc::new(PttSession {
        runtime,
        inner: Mutex::new(Session::with_engine(Arc::new(engine))),
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    use crate::test_audio::voiced_samples;

    #[test]
    fn ffi_fixed_transcript_ptt_roundtrip() {
        let session =
            PttSession::with_fixed_transcript(FfiLanguage::English, "um hello from ffi".into())
                .unwrap();
        session.start_ptt().unwrap();
        session.push_pcm_f32(voiced_samples(1.0), 16_000).unwrap();
        let text = session.stop_ptt().unwrap();
        assert!(!text.to_lowercase().contains("um"), "{text}");
        assert!(text.to_lowercase().contains("hello"), "{text}");
        assert_eq!(session.status(), FfiStatus::Idle);
    }
}

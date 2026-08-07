//! UniFFI surface for the macOS shell (PTT dogfood).

use std::sync::Arc;

use euhadra::types::AudioChunk;
use tokio::runtime::Runtime;
use tokio::sync::Mutex;

use crate::asr::FixedAsr;
use crate::engine::DictationEngine;
use crate::session::{Session, SessionError, SessionStatus};
use crate::Language;

/// Languages exposed across the FFI boundary.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiLanguage {
    /// English (`en`).
    English,
    /// Japanese (`ja`).
    Japanese,
}

impl From<FfiLanguage> for Language {
    fn from(value: FfiLanguage) -> Self {
        match value {
            FfiLanguage::English => Language::English,
            FfiLanguage::Japanese => Language::Japanese,
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
        let runtime = Runtime::new().map_err(|e| FfiError::Message {
            msg: format!("tokio runtime: {e}"),
        })?;
        Ok(Arc::new(Self {
            runtime,
            inner: Mutex::new(Session::with_engine(Arc::new(engine))),
        }))
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
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ffi_fixed_transcript_ptt_roundtrip() {
        let session =
            PttSession::with_fixed_transcript(FfiLanguage::English, "um hello from ffi".into())
                .unwrap();
        session.start_ptt().unwrap();
        session.push_pcm_f32(vec![0.0; 1600], 16_000).unwrap();
        let text = session.stop_ptt().unwrap();
        assert!(!text.to_lowercase().contains("um"), "{text}");
        assert!(text.to_lowercase().contains("hello"), "{text}");
        assert_eq!(session.status(), FfiStatus::Idle);
    }
}

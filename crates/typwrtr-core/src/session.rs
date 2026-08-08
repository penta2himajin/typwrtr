//! PTT session state machine (dogfood slice).

use std::fmt;

use euhadra::types::AudioChunk;

use crate::engine::{EngineError, SharedEngine};

/// Coarse status exposed to the menu-bar shell.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum SessionStatus {
    /// Waiting for PTT.
    #[default]
    Idle,
    /// Hotkey held; accepting audio (or about to).
    Recording,
    /// Hotkey released; ASR / cleanup in progress.
    Processing,
    /// Last operation failed; see [`Session::last_error`].
    Error,
}

/// Errors from session transitions or transcription.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionError {
    message: String,
}

impl SessionError {
    /// Create an error with a human-readable message.
    pub fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
        }
    }

    /// Borrow the message.
    pub fn message(&self) -> &str {
        &self.message
    }
}

impl fmt::Display for SessionError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for SessionError {}

impl From<EngineError> for SessionError {
    fn from(value: EngineError) -> Self {
        Self::new(value.message().to_string())
    }
}

/// How much of the last capture was speech.
///
/// Debug-only measurement (ux-decisions Q27). `speech_samples` is 0 when the
/// detector found nothing, which is also what a dead microphone looks like.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CaptureMetrics {
    /// Samples the shell pushed.
    pub pushed_samples: u64,
    /// Of those, samples the detector classified as speech.
    pub speech_samples: u64,
    /// Rate the chunks declared.
    pub sample_rate: u32,
}

/// In-process PTT session.
pub struct Session {
    status: SessionStatus,
    last_text: Option<String>,
    last_error: Option<SessionError>,
    last_metrics: Option<CaptureMetrics>,
    chunks: Vec<AudioChunk>,
    engine: Option<SharedEngine>,
}

impl Default for Session {
    fn default() -> Self {
        Self::new()
    }
}

impl Session {
    /// Create an idle session without an engine (state-machine tests).
    pub fn new() -> Self {
        Self {
            status: SessionStatus::Idle,
            last_text: None,
            last_error: None,
            last_metrics: None,
            chunks: Vec::new(),
            engine: None,
        }
    }

    /// Create a session bound to a [`DictationEngine`].
    pub fn with_engine(engine: SharedEngine) -> Self {
        Self {
            engine: Some(engine),
            ..Self::new()
        }
    }

    /// Current status for menu-bar icon mapping.
    pub fn status(&self) -> SessionStatus {
        self.status
    }

    /// Last successful or failure-retained text (undo / preview buffer).
    pub fn last_text(&self) -> Option<&str> {
        self.last_text.as_deref()
    }

    /// Last error message when [`SessionStatus::Error`].
    pub fn last_error(&self) -> Option<&SessionError> {
        self.last_error.as_ref()
    }

    /// What the detector made of the last capture (debug measurement).
    pub fn last_metrics(&self) -> Option<CaptureMetrics> {
        self.last_metrics
    }

    /// Begin PTT recording.
    pub fn start_ptt(&mut self) -> Result<(), SessionError> {
        match self.status {
            SessionStatus::Idle | SessionStatus::Error => {
                self.status = SessionStatus::Recording;
                self.last_error = None;
                self.chunks.clear();
                Ok(())
            }
            other => Err(SessionError::new(format!(
                "cannot start PTT from {other:?}"
            ))),
        }
    }

    /// Append a captured audio chunk while recording.
    pub fn push_audio(&mut self, chunk: AudioChunk) -> Result<(), SessionError> {
        match self.status {
            SessionStatus::Recording => {
                self.chunks.push(chunk);
                Ok(())
            }
            other => Err(SessionError::new(format!(
                "cannot push audio from {other:?}"
            ))),
        }
    }

    /// Cancel recording or processing; discard in-flight audio (text buffer kept).
    pub fn cancel(&mut self) -> Result<(), SessionError> {
        match self.status {
            SessionStatus::Recording | SessionStatus::Processing => {
                self.status = SessionStatus::Idle;
                self.last_error = None;
                self.chunks.clear();
                Ok(())
            }
            SessionStatus::Idle | SessionStatus::Error => Ok(()),
        }
    }

    /// Mark processing after PTT release (without running the engine).
    ///
    /// Prefer [`stop_ptt`](Self::stop_ptt) when an engine is attached.
    pub fn stop_ptt_begin_processing(&mut self) -> Result<(), SessionError> {
        match self.status {
            SessionStatus::Recording => {
                self.status = SessionStatus::Processing;
                Ok(())
            }
            other => Err(SessionError::new(format!("cannot stop PTT from {other:?}"))),
        }
    }

    /// Release PTT: run the dictation engine on buffered audio.
    pub async fn stop_ptt(&mut self) -> Result<String, SessionError> {
        self.stop_ptt_begin_processing()?;
        let engine = self.engine.clone().ok_or_else(|| {
            SessionError::new("no dictation engine configured; use Session::with_engine")
        })?;
        let chunks = std::mem::take(&mut self.chunks);
        let pushed_samples = chunks.iter().map(|c| c.samples.len() as u64).sum();
        let sample_rate = chunks.first().map(|c| c.sample_rate).unwrap_or(0);
        match engine.dictate(&chunks).await {
            Ok(dictated) => {
                self.last_metrics = Some(CaptureMetrics {
                    pushed_samples,
                    speech_samples: dictated.speech_samples,
                    sample_rate,
                });
                self.complete_with_text(dictated.text.clone())?;
                Ok(dictated.text)
            }
            // Nothing was said. Not a failure the user has to read
            // (ux-decisions Q24), so return to idle with an empty result.
            Err(err) if err.is_no_speech() => {
                self.last_metrics = Some(CaptureMetrics {
                    pushed_samples,
                    speech_samples: 0,
                    sample_rate,
                });
                self.complete_with_text(String::new())?;
                Ok(String::new())
            }
            Err(err) => {
                let session_err = SessionError::from(err);
                self.fail(session_err.clone(), None)?;
                Err(session_err)
            }
        }
    }

    /// Record a successful transcript and return to idle.
    ///
    /// Empty text leaves the buffer untouched: nothing was inserted, so there is
    /// nothing for Undo to reverse.
    pub fn complete_with_text(&mut self, text: impl Into<String>) -> Result<(), SessionError> {
        match self.status {
            SessionStatus::Processing => {
                let text = text.into();
                self.last_text = (!text.is_empty()).then_some(text);
                self.last_error = None;
                self.chunks.clear();
                self.status = SessionStatus::Idle;
                Ok(())
            }
            other => Err(SessionError::new(format!("cannot complete from {other:?}"))),
        }
    }

    /// Record a failure; keep optional text for preview (ux-decisions Q7).
    pub fn fail(
        &mut self,
        error: SessionError,
        retained_text: Option<String>,
    ) -> Result<(), SessionError> {
        match self.status {
            SessionStatus::Recording | SessionStatus::Processing => {
                if let Some(text) = retained_text {
                    self.last_text = Some(text);
                }
                self.last_error = Some(error);
                self.chunks.clear();
                self.status = SessionStatus::Error;
                Ok(())
            }
            other => Err(SessionError::new(format!("cannot fail from {other:?}"))),
        }
    }

    /// Clear the text buffer after undo or user dismiss.
    pub fn clear_buffer(&mut self) {
        self.last_text = None;
        if self.status == SessionStatus::Error {
            self.status = SessionStatus::Idle;
            self.last_error = None;
        }
    }

    /// Take the undo / preview text buffer (one-shot).
    ///
    /// Returns the retained text and clears it. When status was [`SessionStatus::Error`],
    /// also returns to idle (same cleanup as [`clear_buffer`]).
    pub fn take_undo_payload(&mut self) -> Option<String> {
        let text = self.last_text.take()?;
        if self.status == SessionStatus::Error {
            self.status = SessionStatus::Idle;
            self.last_error = None;
        }
        Some(text)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    use euhadra::mock::MockAsr;
    use euhadra::types::Language;

    use crate::engine::DictationEngine;
    use crate::test_audio::{chunk, voiced_chunk};

    #[test]
    fn ptt_happy_path_status_transitions() {
        let mut s = Session::new();
        assert_eq!(s.status(), SessionStatus::Idle);

        s.start_ptt().unwrap();
        assert_eq!(s.status(), SessionStatus::Recording);

        s.stop_ptt_begin_processing().unwrap();
        assert_eq!(s.status(), SessionStatus::Processing);

        s.complete_with_text("hello").unwrap();
        assert_eq!(s.status(), SessionStatus::Idle);
        assert_eq!(s.last_text(), Some("hello"));
    }

    #[test]
    fn cancel_from_recording_returns_idle() {
        let mut s = Session::new();
        s.start_ptt().unwrap();
        s.cancel().unwrap();
        assert_eq!(s.status(), SessionStatus::Idle);
    }

    #[test]
    fn fail_retains_text_for_preview() {
        let mut s = Session::new();
        s.start_ptt().unwrap();
        s.stop_ptt_begin_processing().unwrap();
        s.fail(SessionError::new("insert failed"), Some("retained".into()))
            .unwrap();
        assert_eq!(s.status(), SessionStatus::Error);
        assert_eq!(s.last_text(), Some("retained"));
        assert_eq!(s.last_error().unwrap().message(), "insert failed");
    }

    #[test]
    fn cannot_start_while_recording() {
        let mut s = Session::new();
        s.start_ptt().unwrap();
        assert!(s.start_ptt().is_err());
    }

    #[tokio::test]
    async fn stop_ptt_runs_engine_and_returns_cleaned_text() {
        let engine = Arc::new(
            DictationEngine::new(Language::English, MockAsr::new("um hello world")).unwrap(),
        );
        let mut s = Session::with_engine(engine);
        s.start_ptt().unwrap();
        s.push_audio(voiced_chunk(1.0)).unwrap();
        let text = s.stop_ptt().await.unwrap();
        assert!(!text.to_lowercase().contains("um"), "got: {text}");
        assert!(text.to_lowercase().contains("hello"), "got: {text}");
        assert_eq!(s.status(), SessionStatus::Idle);
        assert_eq!(s.last_text(), Some(text.as_str()));
    }

    /// ux-decisions Q24: a capture with no speech returns to idle quietly,
    /// leaving nothing behind for Undo. The shell must not show an error.
    #[tokio::test]
    async fn stop_ptt_on_silence_returns_empty_and_stays_idle() {
        let engine =
            Arc::new(DictationEngine::new(Language::English, MockAsr::new("unused")).unwrap());
        let mut s = Session::with_engine(engine);
        s.start_ptt().unwrap();
        s.push_audio(chunk(vec![0.0; 16_000 * 3])).unwrap();

        assert_eq!(s.stop_ptt().await.unwrap(), "");
        assert_eq!(s.status(), SessionStatus::Idle);
        assert_eq!(s.last_text(), None);
        assert!(s.last_error().is_none());
    }

    #[test]
    fn take_undo_payload_is_one_shot() {
        let mut s = Session::new();
        s.start_ptt().unwrap();
        s.stop_ptt_begin_processing().unwrap();
        s.complete_with_text("dictated phrase").unwrap();
        assert_eq!(s.take_undo_payload().as_deref(), Some("dictated phrase"));
        assert_eq!(s.last_text(), None);
        assert_eq!(s.take_undo_payload(), None);
    }

    #[test]
    fn take_undo_payload_clears_error_status() {
        let mut s = Session::new();
        s.start_ptt().unwrap();
        s.stop_ptt_begin_processing().unwrap();
        s.fail(SessionError::new("x"), Some("kept".into())).unwrap();
        assert_eq!(s.status(), SessionStatus::Error);
        assert_eq!(s.take_undo_payload().as_deref(), Some("kept"));
        assert_eq!(s.status(), SessionStatus::Idle);
        assert!(s.last_error().is_none());
    }
}

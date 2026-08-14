//! UniFFI surface for the macOS shell (PTT dogfood).

use std::sync::Arc;

use euhadra::types::AudioChunk;
use tokio::runtime::Runtime;
use tokio::sync::Mutex;

use crate::asr::FixedAsr;
use crate::dictionary::{self, StoredTerm};
use crate::engine::DictationEngine;
use crate::session::{CaptureMetrics, Session, SessionError, SessionStatus};
use crate::stream_endpoint::{StreamListen, StreamVadEvent};
use crate::Language;

/// Live Earshot endpointing events for streaming PTT.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiStreamVadEvent {
    /// No boundary this chunk.
    None,
    /// Segmenter opened an utterance.
    SpeechStarted,
    /// Segmenter closed an utterance — call [`PttSession::take_stream_segment`].
    SegmentEnded,
}

impl From<StreamVadEvent> for FfiStreamVadEvent {
    fn from(value: StreamVadEvent) -> Self {
        match value {
            StreamVadEvent::None => Self::None,
            StreamVadEvent::SpeechStarted => Self::SpeechStarted,
            StreamVadEvent::SegmentEnded => Self::SegmentEnded,
        }
    }
}

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
    /// How many utterances the detector found.
    pub speech_segments: u32,
    /// Rate the chunks declared.
    pub sample_rate: u32,
}

impl From<CaptureMetrics> for FfiCaptureMetrics {
    fn from(value: CaptureMetrics) -> Self {
        Self {
            pushed_samples: value.pushed_samples,
            speech_samples: value.speech_samples,
            speech_segments: value.speech_segments,
            sample_rate: value.sample_rate,
        }
    }
}

/// One speaker dictionary entry across the FFI boundary.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiTermEntry {
    /// Preferred spelling.
    pub term: String,
    /// ASR outputs that should become [`term`](Self::term).
    pub aliases: Vec<String>,
}

impl From<StoredTerm> for FfiTermEntry {
    fn from(value: StoredTerm) -> Self {
        Self {
            term: value.term,
            aliases: value.aliases,
        }
    }
}

impl From<FfiTermEntry> for StoredTerm {
    fn from(value: FfiTermEntry) -> Self {
        Self {
            term: value.term,
            aliases: value.aliases,
        }
    }
}

/// What Settings should show for the active language's dictionary.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiDictionarySnapshot {
    /// Entries when the file loaded cleanly; empty when missing or corrupt.
    pub entries: Vec<FfiTermEntry>,
    /// True when the on-disk file was skipped (Q36).
    pub load_failed: bool,
    /// Why the load failed, when [`load_failed`](Self::load_failed).
    pub failure_message: Option<String>,
}

/// Absolute path of the JSON file for `language` (hand-edit / debug).
#[uniffi::export]
pub fn term_dictionary_path(language: FfiLanguage) -> String {
    dictionary::dictionary_path(language.into())
        .to_string_lossy()
        .into_owned()
}

/// Load the speaker dictionary for Settings (does not mutate a live session).
#[uniffi::export]
pub fn load_term_dictionary(language: FfiLanguage) -> FfiDictionarySnapshot {
    let loaded = dictionary::load(language.into());
    match loaded {
        dictionary::DictionaryLoad::Ready(entries) => FfiDictionarySnapshot {
            entries: entries.into_iter().map(Into::into).collect(),
            load_failed: false,
            failure_message: None,
        },
        dictionary::DictionaryLoad::Empty => FfiDictionarySnapshot {
            entries: Vec::new(),
            load_failed: false,
            failure_message: None,
        },
        dictionary::DictionaryLoad::Corrupt { message } => FfiDictionarySnapshot {
            entries: Vec::new(),
            load_failed: true,
            failure_message: Some(message),
        },
    }
}

/// Validate and write the speaker dictionary. Caller must recreate the session
/// so the next utterance picks up the change (Q34).
#[uniffi::export]
pub fn save_term_dictionary(
    language: FfiLanguage,
    entries: Vec<FfiTermEntry>,
) -> Result<(), FfiError> {
    let stored: Vec<StoredTerm> = entries.into_iter().map(Into::into).collect();
    dictionary::save(language.into(), stored).map_err(|msg| FfiError::Message { msg })
}

/// Whether a streamed / Free segment's transcript should be pasted (empty → no, Q24).
#[uniffi::export]
pub fn should_accept_stream_result(text: String) -> bool {
    crate::stream_gate::should_accept_stream_result(&text)
}

/// Whether key-up should ASR the leftover streaming buffer (speech since last endpoint).
#[uniffi::export]
pub fn should_flush_stream_on_release(saw_speech_since_endpoint: bool) -> bool {
    crate::stream_gate::should_flush_stream_on_release(saw_speech_since_endpoint)
}

/// Silence seconds that end a Focus Dictation / Free segment (Q25: 1.5s).
#[uniffi::export]
pub fn focus_dictation_silence_seconds() -> f64 {
    crate::endpoint::focus_dictation_silence_seconds()
}

/// Silence seconds that end a streaming PTT segment (shorter than Focus Dictation).
#[uniffi::export]
pub fn streaming_ptt_silence_seconds() -> f64 {
    crate::endpoint::streaming_ptt_silence_seconds()
}

/// Samples to keep from a rolling buffer once energy VAD reports speech started.
#[uniffi::export]
pub fn speech_start_keep_len(buffer_len: u64, pad_samples: u64) -> u64 {
    crate::endpoint::speech_start_keep_len(buffer_len as usize, pad_samples as usize) as u64
}

/// Default pad samples for [`speech_start_keep_len`] (~200 ms @ 16 kHz).
#[uniffi::export]
pub fn speech_start_pad_samples() -> u64 {
    crate::endpoint::SPEECH_START_PAD_SAMPLES as u64
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
    /// Streaming PTT live endpointing (Earshot + Segmenter). Separate from the
    /// async session mutex so ASR on a closed segment does not block mic pumps.
    stream: std::sync::Mutex<Option<StreamListen>>,
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

    /// Build using euhadra `SenseVoiceAdapter` (legacy ko).
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

    /// Build using euhadra `DolphinAdapter` (Korean path).
    #[uniffi::constructor]
    pub fn with_dolphin(language: FfiLanguage, model_dir: String) -> Result<Arc<Self>, FfiError> {
        let engine = DictationEngine::with_dolphin(language.into(), model_dir).map_err(|e| {
            FfiError::Message {
                msg: e.message().to_string(),
            }
        })?;
        ptt_session_from_engine(engine)
    }

    /// Current status. A live stream listen counts as recording so the shell
    /// cannot paint idle mid-hold (`refreshStatus` reads this).
    pub fn status(&self) -> FfiStatus {
        if self
            .stream
            .lock()
            .map(|slot| slot.is_some())
            .unwrap_or(false)
        {
            return FfiStatus::Recording;
        }
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

    /// Open Earshot live endpointing for streaming PTT (one key-hold).
    pub fn start_stream_listen(&self) -> Result<(), FfiError> {
        install_stream_listen(&self.stream, StreamListen::start())
    }

    /// Open Earshot live endpointing for Focus Dictation (1.5s silence).
    pub fn start_focus_listen(&self) -> Result<(), FfiError> {
        install_stream_listen(&self.stream, StreamListen::start_focus())
    }

    /// Pump mic PCM into the live segmenter.
    pub fn push_stream_pcm_f32(
        &self,
        samples: Vec<f32>,
        sample_rate: u32,
    ) -> Result<FfiStreamVadEvent, FfiError> {
        let mut slot = self.stream.lock().map_err(|_| FfiError::Message {
            msg: "stream listen lock poisoned".into(),
        })?;
        let listen = slot.as_mut().ok_or_else(|| FfiError::Message {
            msg: "stream listen not started".into(),
        })?;
        listen
            .push(&samples, sample_rate)
            .map(Into::into)
            .map_err(|msg| FfiError::Message { msg })
    }

    /// End the listen. Flushes only if an utterance is still open.
    pub fn stop_stream_listen(&self) -> Result<FfiStreamVadEvent, FfiError> {
        let mut slot = self.stream.lock().map_err(|_| FfiError::Message {
            msg: "stream listen lock poisoned".into(),
        })?;
        let Some(listen) = slot.as_mut() else {
            return Ok(FfiStreamVadEvent::None);
        };
        let event = listen.stop();
        if !matches!(event, StreamVadEvent::SegmentEnded) {
            *slot = None;
        }
        Ok(event.into())
    }

    /// Transcribe one closed stream segment (blocking ASR).
    pub fn take_stream_segment(&self) -> Result<String, FfiError> {
        let samples = {
            let mut slot = self.stream.lock().map_err(|_| FfiError::Message {
                msg: "stream listen lock poisoned".into(),
            })?;
            let listen = slot.as_mut().ok_or_else(|| FfiError::Message {
                msg: "stream listen not started".into(),
            })?;
            listen.take_closed().ok_or_else(|| FfiError::Message {
                msg: "no closed stream segment".into(),
            })?
        };
        match self
            .runtime
            .block_on(async { self.inner.lock().await.dictate_pcm(samples, 16_000).await })
        {
            Ok(text) => Ok(text),
            Err(_) => Ok(String::new()),
        }
    }

    /// Drop the stream listen after release handling is done.
    pub fn finish_stream_listen(&self) {
        if let Ok(mut slot) = self.stream.lock() {
            *slot = None;
        }
    }
}

fn ptt_session_from_engine(engine: DictationEngine) -> Result<Arc<PttSession>, FfiError> {
    let runtime = Runtime::new().map_err(|e| FfiError::Message {
        msg: format!("tokio runtime: {e}"),
    })?;
    Ok(Arc::new(PttSession {
        runtime,
        inner: Mutex::new(Session::with_engine(Arc::new(engine))),
        stream: std::sync::Mutex::new(None),
    }))
}

fn install_stream_listen(
    slot: &std::sync::Mutex<Option<StreamListen>>,
    listen: Result<StreamListen, String>,
) -> Result<(), FfiError> {
    let listen = listen.map_err(|msg| FfiError::Message { msg })?;
    let mut guard = slot.lock().map_err(|_| FfiError::Message {
        msg: "stream listen lock poisoned".into(),
    })?;
    *guard = Some(listen);
    Ok(())
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

    #[test]
    fn ffi_focus_listen_uses_longer_silence() {
        let session =
            PttSession::with_fixed_transcript(FfiLanguage::English, "um hello focus".into())
                .unwrap();
        session.start_focus_listen().unwrap();
        let mut pcm = voiced_samples(0.8);
        pcm.extend(std::iter::repeat_n(0.0, 16_000)); // 1.0s — below focus 1.5s
        let chunk = 1_280usize;
        for piece in pcm.chunks(chunk) {
            let ev = session.push_stream_pcm_f32(piece.to_vec(), 16_000).unwrap();
            assert!(
                !matches!(ev, FfiStreamVadEvent::SegmentEnded),
                "focus must not close at 1.0s silence"
            );
        }
        pcm = std::iter::repeat_n(0.0, 16_000).collect(); // +1.0s → past 1.5s
        let mut ended = false;
        for piece in pcm.chunks(chunk) {
            let ev = session.push_stream_pcm_f32(piece.to_vec(), 16_000).unwrap();
            if matches!(ev, FfiStreamVadEvent::SegmentEnded) {
                ended = true;
                break;
            }
        }
        assert!(ended, "focus must close after ~1.5s silence");
        let text = session.take_stream_segment().unwrap();
        assert!(text.to_lowercase().contains("hello"), "{text}");
        session.finish_stream_listen();
    }

    #[test]
    fn ffi_two_stream_segments_are_taken_once_in_order() {
        let session =
            PttSession::with_fixed_transcript(FfiLanguage::English, "hello".into()).unwrap();
        session.start_stream_listen().unwrap();
        let mut pcm = voiced_samples(1.0);
        pcm.extend(std::iter::repeat_n(0.0, 24_000)); // 1.5s
        pcm.extend(voiced_samples(1.0));
        pcm.extend(std::iter::repeat_n(0.0, 24_000));
        let tick = 1_280usize;
        let mut ends = 0u32;
        for piece in pcm.chunks(tick) {
            if matches!(
                session.push_stream_pcm_f32(piece.to_vec(), 16_000).unwrap(),
                FfiStreamVadEvent::SegmentEnded
            ) {
                ends += 1;
            }
        }
        assert!(ends >= 1, "at least one SegmentEnded before take");
        let first = session.take_stream_segment().unwrap();
        assert!(first.to_lowercase().contains("hello"), "{first}");
        let second = session.take_stream_segment().unwrap();
        assert!(second.to_lowercase().contains("hello"), "{second}");
        assert!(
            session.take_stream_segment().is_err(),
            "a third take must not invent a segment"
        );
        session.finish_stream_listen();
    }

    #[test]
    fn ffi_stop_flush_take_finish_then_restart() {
        let session =
            PttSession::with_fixed_transcript(FfiLanguage::English, "hello".into()).unwrap();
        session.start_stream_listen().unwrap();
        session
            .push_stream_pcm_f32(voiced_samples(1.2), 16_000)
            .unwrap();
        assert!(matches!(
            session.stop_stream_listen().unwrap(),
            FfiStreamVadEvent::SegmentEnded
        ));
        let text = session.take_stream_segment().unwrap();
        assert!(text.to_lowercase().contains("hello"), "{text}");
        session.finish_stream_listen();

        session.start_stream_listen().unwrap();
        session
            .push_stream_pcm_f32(voiced_samples(1.2), 16_000)
            .unwrap();
        assert!(matches!(
            session.stop_stream_listen().unwrap(),
            FfiStreamVadEvent::SegmentEnded
        ));
        let again = session.take_stream_segment().unwrap();
        assert!(again.to_lowercase().contains("hello"), "{again}");
        session.finish_stream_listen();
    }

    #[test]
    fn ffi_sequential_live_stream_segments_remain_usable() {
        let session =
            PttSession::with_fixed_transcript(FfiLanguage::English, "hello".into()).unwrap();
        session.start_stream_listen().unwrap();
        for i in 0..3 {
            let mut pcm = voiced_samples(0.8);
            pcm.extend(std::iter::repeat_n(0.0, 16_000)); // 1.0s > 700ms
            let tick = 1_280usize;
            let mut ended = false;
            for piece in pcm.chunks(tick) {
                if matches!(
                    session.push_stream_pcm_f32(piece.to_vec(), 16_000).unwrap(),
                    FfiStreamVadEvent::SegmentEnded
                ) {
                    ended = true;
                    break;
                }
            }
            assert!(ended, "phrase {i} must close on silence");
            let text = session.take_stream_segment().unwrap();
            assert!(
                text.to_lowercase().contains("hello"),
                "phrase {i} got {text}"
            );
        }
        session.finish_stream_listen();
    }

    #[test]
    fn ffi_streaming_listen_reports_recording_status() {
        let session =
            PttSession::with_fixed_transcript(FfiLanguage::English, "hello".into()).unwrap();
        assert_eq!(session.status(), FfiStatus::Idle);
        session.start_stream_listen().unwrap();
        assert_eq!(session.status(), FfiStatus::Recording);
        session.finish_stream_listen();
        assert_eq!(session.status(), FfiStatus::Idle);
    }

    #[test]
    fn ffi_stop_stream_listen_flushes_open_utterance_with_pending_segment() {
        let session =
            PttSession::with_fixed_transcript(FfiLanguage::English, "hello".into()).unwrap();
        session.start_stream_listen().unwrap();
        let mut first = voiced_samples(1.0);
        first.extend(std::iter::repeat_n(0.0, 24_000));
        let tick = 1_280usize;
        let mut ended = false;
        for piece in first.chunks(tick) {
            if matches!(
                session.push_stream_pcm_f32(piece.to_vec(), 16_000).unwrap(),
                FfiStreamVadEvent::SegmentEnded
            ) {
                ended = true;
            }
        }
        assert!(ended);
        session
            .push_stream_pcm_f32(voiced_samples(1.2), 16_000)
            .unwrap();
        assert!(matches!(
            session.stop_stream_listen().unwrap(),
            FfiStreamVadEvent::SegmentEnded
        ));
        let a = session.take_stream_segment().unwrap();
        let b = session.take_stream_segment().unwrap();
        assert!(a.to_lowercase().contains("hello"), "{a}");
        assert!(b.to_lowercase().contains("hello"), "{b}");
        session.finish_stream_listen();
    }
}

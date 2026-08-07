//! Build an euhadra dictation pipeline for Typwrtr.

use std::path::Path;
use std::sync::Arc;

use euhadra::canary::{CanaryAdapter, CanaryConfig};
use euhadra::parakeet::ParakeetAdapter;
use euhadra::paraformer::ParaformerAdapter;
use euhadra::prelude::*;
use euhadra::sensevoice::SenseVoiceAdapter;
use euhadra::traits::AsrAdapter;
use euhadra::whisper_local::WhisperLocal;

use crate::paths::{
    canary_uses_int8, resolve_canary_dir, resolve_canary_from_env, resolve_parakeet_dir,
    resolve_parakeet_ja_from_env, resolve_paraformer_zh_dir, resolve_paraformer_zh_from_env,
    resolve_sensevoice_dir, resolve_sensevoice_from_env, resolve_whisper_from_env,
    resolve_whisper_paths, whisper_language_tag,
};

/// Errors while building or running the dictation pipeline.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EngineError {
    message: String,
}

impl EngineError {
    /// Create an error.
    pub fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
        }
    }

    /// Human-readable message.
    pub fn message(&self) -> &str {
        &self.message
    }
}

impl std::fmt::Display for EngineError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for EngineError {}

impl From<PipelineError> for EngineError {
    fn from(value: PipelineError) -> Self {
        Self::new(value.to_string())
    }
}

/// Configured euhadra pipeline with Tier 1+2 cleanup (no LLM, no emitter).
///
/// Text is returned to the caller; the Swift shell owns insertion.
pub struct DictationEngine {
    pipeline: Pipeline,
    language: Language,
}

impl DictationEngine {
    /// Build a pipeline for `language` using the given ASR adapter.
    pub fn new(language: Language, asr: impl AsrAdapter + 'static) -> Result<Self, EngineError> {
        let pipeline = Pipeline::builder()
            .asr(asr)
            .filter(FillerFilter::for_language(language))
            .processor(SelfCorrectionDetector::new())
            .processor(BasicPunctuationRestorer)
            .build()
            .map_err(EngineError::from)?;
        Ok(Self { pipeline, language })
    }

    /// Build using euhadra [`WhisperLocal`] (whisper.cpp CLI).
    pub fn with_whisper_local(
        language: Language,
        cli_path: impl AsRef<Path>,
        model_path: impl AsRef<Path>,
    ) -> Result<Self, EngineError> {
        let (cli, model) = resolve_whisper_paths(cli_path, model_path)?;
        let asr = WhisperLocal::new(cli, model).with_language(whisper_language_tag(language));
        Self::new(language, asr)
    }

    /// Build WhisperLocal from env / conventional dogfood paths.
    pub fn with_whisper_from_env(language: Language) -> Result<Self, EngineError> {
        let (cli, model) = resolve_whisper_from_env(language)?;
        Self::with_whisper_local(language, cli, model)
    }

    /// Build using euhadra [`ParakeetAdapter`] (ONNX Parakeet TDT / Hybrid TDT-CTC).
    pub fn with_parakeet(
        language: Language,
        model_dir: impl AsRef<Path>,
    ) -> Result<Self, EngineError> {
        let dir = resolve_parakeet_dir(model_dir)?;
        let asr = ParakeetAdapter::load(&dir).map_err(|e| EngineError::new(e.to_string()))?;
        Self::new(language, asr)
    }

    /// Build Parakeet-ja from env / conventional dogfood paths.
    pub fn with_parakeet_ja_from_env(language: Language) -> Result<Self, EngineError> {
        let dir = resolve_parakeet_ja_from_env()?;
        Self::with_parakeet(language, dir)
    }

    /// Build using euhadra [`CanaryAdapter`] (en / es).
    pub fn with_canary(
        language: Language,
        model_dir: impl AsRef<Path>,
    ) -> Result<Self, EngineError> {
        let dir = resolve_canary_dir(model_dir)?;
        let mut cfg = CanaryConfig::default();
        if canary_uses_int8(&dir) {
            cfg = cfg.with_int8_weights();
        }
        cfg.default_language = whisper_language_tag(language).to_string();
        let asr = CanaryAdapter::load_with_config(&dir, cfg)
            .map_err(|e| EngineError::new(e.to_string()))?
            .with_language(whisper_language_tag(language));
        Self::new(language, asr)
    }

    /// Canary from env / conventional dogfood paths.
    pub fn with_canary_from_env(language: Language) -> Result<Self, EngineError> {
        let dir = resolve_canary_from_env()?;
        Self::with_canary(language, dir)
    }

    /// Build using euhadra [`ParaformerAdapter`] (zh).
    pub fn with_paraformer_zh(
        language: Language,
        model_dir: impl AsRef<Path>,
    ) -> Result<Self, EngineError> {
        let dir = resolve_paraformer_zh_dir(model_dir)?;
        let asr =
            ParaformerAdapter::load(&dir).map_err(|e| EngineError::new(e.to_string()))?;
        Self::new(language, asr)
    }

    /// Paraformer-zh from env / conventional dogfood paths.
    pub fn with_paraformer_zh_from_env(language: Language) -> Result<Self, EngineError> {
        let dir = resolve_paraformer_zh_from_env()?;
        Self::with_paraformer_zh(language, dir)
    }

    /// Build using euhadra [`SenseVoiceAdapter`] (ko).
    pub fn with_sensevoice(
        language: Language,
        model_dir: impl AsRef<Path>,
    ) -> Result<Self, EngineError> {
        let dir = resolve_sensevoice_dir(model_dir)?;
        let asr = SenseVoiceAdapter::load(&dir)
            .map_err(|e| EngineError::new(e.to_string()))?
            .with_language(whisper_language_tag(language));
        Self::new(language, asr)
    }

    /// SenseVoice from env / conventional dogfood paths.
    pub fn with_sensevoice_from_env(language: Language) -> Result<Self, EngineError> {
        let dir = resolve_sensevoice_from_env()?;
        Self::with_sensevoice(language, dir)
    }

    /// Active language.
    pub fn language(&self) -> Language {
        self.language
    }

    /// Run a complete utterance through ASR + cleanup.
    pub async fn dictate(&self, audio: &[AudioChunk]) -> Result<String, EngineError> {
        let result = self.pipeline.transcribe(audio).await?;
        Ok(result.text().to_string())
    }
}

/// Shared engine handle for sessions.
pub type SharedEngine = Arc<DictationEngine>;

#[cfg(test)]
mod tests {
    use super::*;
    use euhadra::mock::MockAsr;

    fn silence_chunk() -> AudioChunk {
        AudioChunk {
            samples: vec![0.0; 1600],
            sample_rate: 16_000,
            channels: 1,
        }
    }

    #[tokio::test]
    async fn english_mock_pipeline_removes_filler_and_self_repair() {
        let engine = DictationEngine::new(
            Language::English,
            MockAsr::new("um I want to go to Boston no wait to Denver"),
        )
        .unwrap();

        let text = engine.dictate(&[silence_chunk()]).await.unwrap();
        assert!(!text.to_lowercase().contains("um"), "filler left: {text}");
        assert!(!text.contains("Boston"), "reparandum left: {text}");
        assert!(text.contains("Denver"), "repair missing: {text}");
    }

    #[tokio::test]
    async fn japanese_mock_pipeline_removes_filler() {
        let engine =
            DictationEngine::new(Language::Japanese, MockAsr::new("えーと、今日は天気がいい"))
                .unwrap();

        let text = engine.dictate(&[silence_chunk()]).await.unwrap();
        assert!(!text.contains("えーと"), "filler left: {text}");
        assert!(text.contains("今日は天気がいい"), "content lost: {text}");
    }

    #[tokio::test]
    #[ignore = "requires WHISPER_CLI + models from scripts/fetch-models.sh"]
    async fn whisper_local_from_env_smoke() {
        let engine = DictationEngine::with_whisper_from_env(Language::English)
            .expect("configure WHISPER_CLI and models for this test");
        let chunk = AudioChunk {
            samples: vec![0.0; 16_000],
            sample_rate: 16_000,
            channels: 1,
        };
        // Silence should reach whisper-cli; empty/no-speech is success for wiring.
        match engine.dictate(&[chunk]).await {
            Ok(_) => {}
            Err(e) => {
                let msg = e.message().to_lowercase();
                assert!(
                    msg.contains("no speech") || msg.contains("speech"),
                    "unexpected whisper error: {e}"
                );
            }
        }
    }
}

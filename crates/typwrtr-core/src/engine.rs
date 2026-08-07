//! Build an euhadra dictation pipeline for Typwrtr.

use std::sync::Arc;

use euhadra::prelude::*;
use euhadra::traits::AsrAdapter;

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
}

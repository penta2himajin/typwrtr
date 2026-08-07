//! Simple ASR adapters owned by Typwrtr (not euhadra mocks).

use async_trait::async_trait;
use euhadra::traits::{AsrAdapter, AsrError};
use euhadra::types::{AudioChunk, Transcript};

/// Returns a fixed transcript regardless of audio.
///
/// Used for shell / UniFFI dogfood before real models are wired, and for
/// deterministic tests that must not depend on `euhadra/testing`.
pub struct FixedAsr {
    transcript: String,
}

impl FixedAsr {
    /// Create an adapter that always yields `transcript`.
    pub fn new(transcript: impl Into<String>) -> Self {
        Self {
            transcript: transcript.into(),
        }
    }
}

#[async_trait]
impl AsrAdapter for FixedAsr {
    async fn transcribe(&self, _audio: &[AudioChunk]) -> Result<Transcript, AsrError> {
        Ok(Transcript::new(self.transcript.clone()))
    }
}

//! Decide whether a streamed segment should become an insert.
//!
//! Silence trimming belongs to euhadra's detector on the pipeline, not to a
//! second minimum-duration heuristic in the shell. Empty-text rejection is
//! Q24; the release flush rule stops trailing post-endpoint silence from
//! reaching ASR (dogfood hallucination on key-up).

/// Paste when there is something to paste; otherwise stay quiet (Q24).
pub fn should_accept_stream_result(text: &str) -> bool {
    !text.trim().is_empty()
}

/// Whether key-up should run ASR on the leftover streaming buffer.
///
/// After a silence endpoint the rolling buffer often holds only trailing
/// quiet. The old `saw_speech || !buffer_empty` rule still flushed that tail
/// and invited short hallucinations. Require speech since the last endpoint.
pub fn should_flush_stream_on_release(saw_speech_since_endpoint: bool) -> bool {
    saw_speech_since_endpoint
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_empty_and_whitespace() {
        assert!(!should_accept_stream_result(""));
        assert!(!should_accept_stream_result("  \n"));
    }

    #[test]
    fn accepts_any_non_empty_text() {
        // Short or long — Earshot already decided this was speech.
        assert!(should_accept_stream_result("あ"));
        assert!(should_accept_stream_result("こんにちは"));
    }

    #[test]
    fn release_flush_requires_speech_since_last_endpoint() {
        assert!(should_flush_stream_on_release(true));
        assert!(!should_flush_stream_on_release(false));
    }
}

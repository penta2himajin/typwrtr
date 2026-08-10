//! Decide whether a streamed transcript should be pasted.
//!
//! Silence trimming belongs to euhadra's detector on the pipeline, not to a
//! second minimum-duration heuristic in the shell. This gate only skips empty
//! text (ux-decisions Q24).

/// Paste when there is something to paste; otherwise stay quiet (Q24).
pub fn should_accept_stream_result(text: &str) -> bool {
    !text.trim().is_empty()
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
}

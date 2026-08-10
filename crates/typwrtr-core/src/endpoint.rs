//! Silence duration used to end an utterance (shell energy VAD, until stage 2).
//!
//! Focus Dictation keeps the historical 1.5s margin (ux-decisions Q25).
//! Streaming PTT shortens it: the key hold is already a consent gate, so
//! euhadra's ~700ms default is enough and feels less like batch-on-release.

/// Focus Dictation / Free: 1500 ms of silence ends a segment.
pub const FOCUS_DICTATION_SILENCE_MS: u64 = 1500;

/// Push to talk (streaming): 700 ms of silence ends a segment.
pub const STREAMING_PTT_SILENCE_MS: u64 = 700;

/// Trailing pad kept when speech starts (~200 ms @ 16 kHz; matches Earshot `speech_pad`).
pub const SPEECH_START_PAD_SAMPLES: usize = 3_200;

/// Seconds for Focus Dictation endpointing.
pub fn focus_dictation_silence_seconds() -> f64 {
    FOCUS_DICTATION_SILENCE_MS as f64 / 1000.0
}

/// Seconds for streaming PTT endpointing.
pub fn streaming_ptt_silence_seconds() -> f64 {
    STREAMING_PTT_SILENCE_MS as f64 / 1000.0
}

/// After energy VAD reports speech started, keep only a trailing pad of the
/// rolling buffer — the rest is leading silence the detector already skipped.
pub fn speech_start_keep_len(buffer_len: usize, pad_samples: usize) -> usize {
    buffer_len.min(pad_samples)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn streaming_is_shorter_than_focus_dictation() {
        assert!(streaming_ptt_silence_seconds() < focus_dictation_silence_seconds());
        const _: () = assert!(STREAMING_PTT_SILENCE_MS < FOCUS_DICTATION_SILENCE_MS);
    }

    #[test]
    fn streaming_matches_euhadra_default_ballpark() {
        assert_eq!(STREAMING_PTT_SILENCE_MS, 700);
    }

    #[test]
    fn focus_keeps_q25_margin() {
        assert_eq!(FOCUS_DICTATION_SILENCE_MS, 1500);
    }

    #[test]
    fn speech_start_discards_leading_silence_via_pad() {
        // ~2.8s of pre-roll (as seen in dogfood logs) collapses to 200ms pad.
        assert_eq!(
            speech_start_keep_len(44_895, SPEECH_START_PAD_SAMPLES),
            SPEECH_START_PAD_SAMPLES
        );
        assert_eq!(
            speech_start_keep_len(1_000, SPEECH_START_PAD_SAMPLES),
            1_000
        );
    }
}

//! Live Earshot + Segmenter endpointing (VAD stage 2).
//!
//! The segmenter decides *when* a phrase ends. Closed PCM is the mic window
//! accumulated since the previous close (or listen start) — not a slice on
//! `SpeechSegment` bounds. [`crate::engine::DictationEngine::dictate`] runs
//! pipeline Earshot again for trim / NoSpeech (backend default threshold 0.2).
//!
//! Live endpointing uses a higher score cutoff than dictate trim: see
//! [`live_config`]. Streaming PTT and Focus Dictation share this path; only
//! `min_silence` differs (700 ms vs 1500 ms).

use std::time::Duration;

use euhadra::vad::{EarshotVad, Segmenter, SegmenterConfig, VadBackend, VadStream};

use crate::endpoint::{
    FOCUS_DICTATION_SILENCE_MS, SPEECH_START_PAD_SAMPLES, STREAMING_PTT_SILENCE_MS,
};

/// What the shell should do after pumping PCM into a stream listen.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StreamVadEvent {
    /// No boundary this chunk.
    None,
    /// Segmenter opened an utterance (`min_speech` met).
    SpeechStarted,
    /// Segmenter closed an utterance — call [`StreamListen::take_closed`].
    SegmentEnded,
}

/// Live Earshot score cutoff for *endpointing* (not dictate trim).
///
/// euhadra calibrates `EarshotVad::default_threshold` to **0.2** for offline
/// trim / WER; that value keeps room tone as speech on laptop mics, so
/// mid-hold never closed (dogfood 2026-08-11). rlx-vad's live Earshot
/// preset is **0.35**, but measured −45 dBFS room tone still peaks at
/// ~0.37 (2026-08-14), which resets the 44-frame silence run. **0.42**
/// sits above that peak and below the earshot README's 0.5 (euhadra
/// measured 0.5 as harmful for recall).
pub const STREAMING_EARSHOT_ENDPOINT_THRESHOLD: f32 = 0.42;

/// One key-hold listening period: Earshot stream + Segmenter + PCM window.
pub struct StreamListen {
    stream: Box<dyn VadStream>,
    segmenter: Segmenter,
    frame_size: usize,
    sample_rate: u32,
    /// Incomplete frame carried across pushes.
    pending_frame: Vec<f32>,
    /// Samples since the last closed segment (or listen start).
    utterance: Vec<f32>,
    /// Closed utterances waiting for [`Self::take_closed`].
    closed: Vec<Vec<f32>>,
    was_speaking: bool,
}

/// Which product mode opened this listen (silence budget only).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StreamListenMode {
    /// Push to talk (streaming): ~700 ms silence.
    Streaming,
    /// Focus Dictation / Free: 1500 ms silence (Q25).
    FocusDictation,
}

/// Segmenter policy for live endpointing.
///
/// - `threshold`: [`STREAMING_EARSHOT_ENDPOINT_THRESHOLD`]
/// - `min_silence`: mode-specific ([`STREAMING_PTT_SILENCE_MS`] or
///   [`FOCUS_DICTATION_SILENCE_MS`])
/// - other fields: euhadra `SegmenterConfig::default()`
fn live_config(mode: StreamListenMode) -> SegmenterConfig {
    let mut config = SegmenterConfig::default();
    config.threshold = Some(STREAMING_EARSHOT_ENDPOINT_THRESHOLD);
    config.min_silence = Duration::from_millis(match mode {
        StreamListenMode::Streaming => STREAMING_PTT_SILENCE_MS,
        StreamListenMode::FocusDictation => FOCUS_DICTATION_SILENCE_MS,
    });
    config
}

impl StreamListen {
    /// Open a listening period with Earshot + streaming endpoint config.
    pub fn start() -> Result<Self, String> {
        Self::start_mode(StreamListenMode::Streaming)
    }

    /// Open a listening period with Focus Dictation silence (1500 ms).
    pub fn start_focus() -> Result<Self, String> {
        Self::start_mode(StreamListenMode::FocusDictation)
    }

    fn start_mode(mode: StreamListenMode) -> Result<Self, String> {
        let vad = EarshotVad::new();
        let sample_rate = 16_000;
        let segmenter =
            Segmenter::new(&vad, sample_rate, live_config(mode)).map_err(|e| e.to_string())?;
        let frame_size = vad.frame_size();
        let stream = vad.start();
        Ok(Self {
            stream,
            segmenter,
            frame_size,
            sample_rate,
            pending_frame: Vec::with_capacity(frame_size),
            utterance: Vec::new(),
            closed: Vec::new(),
            was_speaking: false,
        })
    }

    /// Sample rate this listen expects (Earshot is 16 kHz only).
    pub fn sample_rate(&self) -> u32 {
        self.sample_rate
    }

    /// Whether an utterance is open (for release flush / logging).
    pub fn is_speaking(&self) -> bool {
        self.segmenter.is_speaking()
    }

    /// Append PCM and return at most one event for *this* push.
    ///
    /// `SegmentEnded` fires when a boundary happens in this call, not merely
    /// because a closed window is still waiting to be taken.
    ///
    /// Empty `samples` while speaking still advances the silence clock by one
    /// shell tick of digital silence (mic underrun must not freeze endpointing).
    pub fn push(&mut self, samples: &[f32], sample_rate: u32) -> Result<StreamVadEvent, String> {
        if sample_rate != self.sample_rate {
            return Err(format!(
                "stream listen requires {} Hz, got {sample_rate}",
                self.sample_rate
            ));
        }

        if samples.is_empty() {
            if self.segmenter.is_speaking() {
                let tick = ((self.sample_rate as f32) * 0.08).round() as usize;
                let zeros = vec![0.0; tick.max(self.frame_size)];
                return self.push_samples(&zeros);
            }
            return Ok(StreamVadEvent::None);
        }

        self.push_samples(samples)
    }

    fn push_samples(&mut self, samples: &[f32]) -> Result<StreamVadEvent, String> {
        self.pending_frame.extend_from_slice(samples);

        let mut saw_speech_started = false;
        let mut saw_segment_ended = false;

        while self.pending_frame.len() >= self.frame_size {
            let frame: Vec<f32> = self.pending_frame.drain(..self.frame_size).collect();
            // Append only frames the segmenter has seen. Extending `utterance` with
            // the whole push first made onset trim keep the *end* of a delayed chunk.
            self.utterance.extend_from_slice(&frame);
            let probability = self.stream.speech_probability(&frame);
            let closed = self.segmenter.push(probability);
            let speaking = self.segmenter.is_speaking();
            if speaking && !self.was_speaking {
                saw_speech_started = true;
                // Drop inter-phrase silence / prior-window remnant; keep a short
                // onset pad (matches Earshot speech_pad). Without this the next
                // closed buffer carries seconds of leading audio and dictate
                // reports multiple segments (dogfood overlap).
                self.trim_utterance_to_speech_pad();
            }
            self.was_speaking = speaking;

            if closed.is_some() {
                self.seal_utterance_window();
                saw_segment_ended = true;
                self.was_speaking = false;
            }
        }

        if saw_segment_ended {
            return Ok(StreamVadEvent::SegmentEnded);
        }
        if saw_speech_started {
            return Ok(StreamVadEvent::SpeechStarted);
        }
        Ok(StreamVadEvent::None)
    }

    /// End the listen. Flushes an open utterance even if a prior window is
    /// still waiting to be taken (release during in-flight ASR).
    pub fn stop(&mut self) -> StreamVadEvent {
        let mut ended = !self.closed.is_empty();
        if self.segmenter.is_speaking() {
            if self.segmenter.flush().is_some() {
                self.seal_utterance_window();
                self.was_speaking = false;
                ended = true;
            } else {
                self.utterance.clear();
                self.pending_frame.clear();
            }
        } else {
            self.utterance.clear();
            self.pending_frame.clear();
        }
        if ended {
            StreamVadEvent::SegmentEnded
        } else {
            StreamVadEvent::None
        }
    }

    /// Pop one closed utterance's PCM.
    pub fn take_closed(&mut self) -> Option<Vec<f32>> {
        if self.closed.is_empty() {
            return None;
        }
        Some(self.closed.remove(0))
    }

    /// Put a window back at the end of the queue (ASR failed after take).
    /// Append, do not insert at the front: a window that fails again would
    /// otherwise block every later closed utterance.
    pub fn restore_closed(&mut self, samples: Vec<f32>) {
        if !samples.is_empty() {
            self.closed.push(samples);
        }
    }

    /// Seal frames already scored by the segmenter.
    ///
    /// Unframed `pending_frame` remainder is not in `utterance`; it joins the
    /// next window when the next complete frame is assembled.
    fn seal_utterance_window(&mut self) {
        let window = std::mem::take(&mut self.utterance);
        if !window.is_empty() {
            self.closed.push(window);
        }
    }

    fn trim_utterance_to_speech_pad(&mut self) {
        let keep =
            crate::endpoint::speech_start_keep_len(self.utterance.len(), SPEECH_START_PAD_SAMPLES);
        if self.utterance.len() > keep {
            self.utterance = self.utterance[self.utterance.len() - keep..].to_vec();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::endpoint::SPEECH_START_PAD_SAMPLES;
    use crate::test_audio::{room_tone, voiced_samples, RATE};

    fn silence(seconds: f32) -> Vec<f32> {
        vec![0.0; (seconds * RATE as f32) as usize]
    }

    fn push_all(listen: &mut StreamListen, samples: &[f32]) -> Vec<StreamVadEvent> {
        let chunk = (RATE as f32 * 0.08) as usize;
        let mut events = Vec::new();
        for piece in samples.chunks(chunk.max(1)) {
            let ev = listen.push(piece, RATE).unwrap();
            if ev == StreamVadEvent::None {
                continue;
            }
            events.push(ev);
            if ev == StreamVadEvent::SegmentEnded {
                assert!(
                    listen.take_closed().is_some(),
                    "SegmentEnded must leave a closed buffer"
                );
            }
        }
        events
    }

    #[test]
    fn live_endpoint_threshold_sits_above_measured_room_tone() {
        assert!((STREAMING_EARSHOT_ENDPOINT_THRESHOLD - 0.42).abs() < f32::EPSILON);
        const _: () = assert!(STREAMING_EARSHOT_ENDPOINT_THRESHOLD > 0.35);
        const _: () = assert!(STREAMING_EARSHOT_ENDPOINT_THRESHOLD < 0.5);
    }

    #[test]
    fn earshot_scores_room_tone_below_the_live_endpoint_threshold() {
        let vad = EarshotVad::new();
        let mut stream = vad.start();
        let scores: Vec<f32> = room_tone(2.0)
            .chunks(vad.frame_size())
            .map(|f| stream.speech_probability(f))
            .collect();
        let peak = scores.iter().copied().fold(0.0f32, f32::max);
        let above = scores
            .iter()
            .filter(|s| **s >= STREAMING_EARSHOT_ENDPOINT_THRESHOLD)
            .count();
        assert_eq!(
            above, 0,
            "room tone peaks at {peak} ({above} frames ≥ {STREAMING_EARSHOT_ENDPOINT_THRESHOLD}); \
             a single frame at threshold resets the ~700ms silence run so mid-hold never closes"
        );
    }

    #[test]
    fn streaming_closes_over_a_room_tone_floor_not_only_digital_zeros() {
        let mut listen = StreamListen::start().unwrap();
        let mut pcm = voiced_samples(1.0);
        pcm.extend(room_tone(2.0));
        let events = push_all(&mut listen, &pcm);
        assert!(
            events.contains(&StreamVadEvent::SegmentEnded),
            "streaming must close ~0.7s after speech over a −45 dBFS floor: {events:?}"
        );
    }

    #[test]
    fn a_restored_window_does_not_outrank_the_next_one() {
        let mut listen = StreamListen::start().unwrap();
        let mut pcm = voiced_samples(0.8);
        pcm.extend(silence(1.5));
        pcm.extend(voiced_samples(1.4));
        pcm.extend(silence(1.5));
        let tick = (RATE as f32 * 0.08) as usize;
        for piece in pcm.chunks(tick.max(1)) {
            let _ = listen.push(piece, RATE).unwrap();
        }
        let first = listen.take_closed().expect("first window");
        listen.restore_closed(first.clone());
        let next = listen.take_closed().expect("window after restore");
        assert_ne!(
            next, first,
            "a failed window must not be served ahead of the next one forever"
        );
    }

    #[test]
    fn second_phrase_does_not_carry_prior_silence_duration() {
        let mut listen = StreamListen::start().unwrap();
        let mut pcm = voiced_samples(1.0);
        pcm.extend(silence(1.5));
        pcm.extend(voiced_samples(1.0));
        pcm.extend(silence(1.5));

        let mut closed_lens = Vec::new();
        let chunk = (RATE as f32 * 0.08) as usize;
        for piece in pcm.chunks(chunk.max(1)) {
            if listen.push(piece, RATE).unwrap() == StreamVadEvent::SegmentEnded {
                let closed = listen.take_closed().expect("closed");
                closed_lens.push(closed.len());
            }
        }
        assert!(
            closed_lens.len() >= 2,
            "need two closed windows, got {closed_lens:?}"
        );
        let second = closed_lens[1] as f32 / RATE as f32;
        // Prior bug: second window held ~first+gap+second (~3.5s+). After trim,
        // it should be near one phrase + pads/silence margin, not the full gap.
        assert!(
            second < 3.0,
            "second window too long ({second:.2}s) — likely includes prior silence"
        );
    }

    #[test]
    fn two_phrases_yield_two_segment_ends() {
        let mut listen = StreamListen::start().unwrap();
        let mut pcm = voiced_samples(1.0);
        pcm.extend(silence(1.5));
        pcm.extend(voiced_samples(1.0));
        pcm.extend(silence(1.5));

        let events = push_all(&mut listen, &pcm);
        let ends = events
            .iter()
            .filter(|e| **e == StreamVadEvent::SegmentEnded)
            .count();
        assert!(
            ends >= 2,
            "expected >=2 SegmentEnded, got {events:?} (ends={ends})"
        );
    }

    #[test]
    fn stop_on_trailing_silence_does_not_flush() {
        let mut listen = StreamListen::start().unwrap();
        let mut pcm = voiced_samples(0.8);
        pcm.extend(silence(1.5));
        let _ = push_all(&mut listen, &pcm);
        let _ = listen.push(&silence(0.4), RATE).unwrap();
        assert!(
            !listen.is_speaking(),
            "trailing quiet must not leave an open utterance"
        );
        assert_eq!(listen.stop(), StreamVadEvent::None);
        assert!(listen.take_closed().is_none());
    }

    #[test]
    fn stop_while_speaking_flushes() {
        let mut listen = StreamListen::start().unwrap();
        let _ = push_all(&mut listen, &voiced_samples(1.2));
        assert!(listen.is_speaking());
        assert_eq!(listen.stop(), StreamVadEvent::SegmentEnded);
        let closed = listen.take_closed().expect("flushed utterance");
        assert!(!closed.is_empty());
    }

    #[test]
    fn empty_push_while_speaking_advances_silence_clock() {
        let mut listen = StreamListen::start().unwrap();
        let _ = push_all(&mut listen, &voiced_samples(0.5));
        assert!(listen.is_speaking());
        let mut ended = false;
        for _ in 0..20 {
            if listen.push(&[], RATE).unwrap() == StreamVadEvent::SegmentEnded {
                ended = true;
                break;
            }
        }
        assert!(ended, "empty pumps must be able to close on silence");
        assert!(listen.take_closed().is_some());
    }

    fn phrase_then_silence() -> Vec<f32> {
        let mut pcm = voiced_samples(1.0);
        pcm.extend(silence(1.5));
        pcm
    }

    fn drain_closed(listen: &mut StreamListen, samples: &[f32], chunk: usize) -> Vec<Vec<f32>> {
        let mut closed = Vec::new();
        for piece in samples.chunks(chunk.max(1)) {
            let _ = listen.push(piece, RATE).unwrap();
            while let Some(window) = listen.take_closed() {
                closed.push(window);
            }
        }
        closed
    }

    #[test]
    fn large_single_push_matches_chunked_push() {
        let pcm = phrase_then_silence();
        let tick = (RATE as f32 * 0.08) as usize;

        let mut chunked = StreamListen::start().unwrap();
        let chunked_closed = drain_closed(&mut chunked, &pcm, tick);

        let mut whole = StreamListen::start().unwrap();
        let whole_closed = drain_closed(&mut whole, &pcm, pcm.len());

        assert_eq!(
            chunked_closed.len(),
            whole_closed.len(),
            "same PCM must close the same number of times chunked vs one push"
        );
        assert!(
            !whole_closed.is_empty(),
            "a 1s phrase + 1.5s silence must produce a closed window even as one push"
        );
        let chunked_len = chunked_closed[0].len() as f32 / RATE as f32;
        let whole_len = whole_closed[0].len() as f32 / RATE as f32;
        assert!(
            (chunked_len - whole_len).abs() < 0.3,
            "closed window length diverged: chunked={chunked_len:.2}s whole={whole_len:.2}s"
        );
    }

    #[test]
    fn speech_start_in_large_push_preserves_processed_onset() {
        // Delayed timer: one push bigger than SPEECH_START_PAD_SAMPLES that
        // contains onset, speech, and enough silence to close.
        let mut pcm = silence(0.3);
        pcm.extend(voiced_samples(1.0));
        pcm.extend(silence(1.5));
        assert!(pcm.len() > SPEECH_START_PAD_SAMPLES);

        let mut listen = StreamListen::start().unwrap();
        let closed = drain_closed(&mut listen, &pcm, pcm.len());
        assert_eq!(
            closed.len(),
            1,
            "expected one closed window, got {}",
            closed.len()
        );
        let seconds = closed[0].len() as f32 / RATE as f32;
        assert!(
            seconds > 0.6,
            "onset trim on a large push dropped the phrase ({seconds:.2}s)"
        );
    }

    #[test]
    fn segment_ended_always_has_takeable_closed_buffer() {
        let mut listen = StreamListen::start().unwrap();
        let mut pcm = voiced_samples(1.0);
        pcm.extend(silence(1.5));
        let ev = listen.push(&pcm, RATE).unwrap();
        assert_eq!(ev, StreamVadEvent::SegmentEnded);
        let first = listen.take_closed().expect("SegmentEnded without a buffer");
        assert!(!first.is_empty());
        assert!(listen.take_closed().is_none());
        // After take, silence must not re-fire.
        assert_eq!(
            listen.push(&silence(0.08), RATE).unwrap(),
            StreamVadEvent::None
        );
    }

    #[test]
    fn segment_ended_is_reported_once_per_boundary() {
        let mut listen = StreamListen::start().unwrap();
        let mut pcm = voiced_samples(1.0);
        pcm.extend(silence(1.5));
        let tick = (RATE as f32 * 0.08) as usize;
        let mut ends = 0;
        for piece in pcm.chunks(tick.max(1)) {
            if listen.push(piece, RATE).unwrap() == StreamVadEvent::SegmentEnded {
                ends += 1;
            }
        }
        assert_eq!(ends, 1, "sticky SegmentEnded must not re-fire every tick");
        for _ in 0..8 {
            assert_eq!(
                listen.push(&silence(0.08), RATE).unwrap(),
                StreamVadEvent::None
            );
        }
        assert!(listen.take_closed().is_some());
    }

    #[test]
    fn stop_flushes_the_open_utterance_even_with_a_pending_closed_window() {
        let mut listen = StreamListen::start().unwrap();
        let mut first = voiced_samples(1.0);
        first.extend(silence(1.5));
        let tick = (RATE as f32 * 0.08) as usize;
        let mut ended = false;
        for piece in first.chunks(tick.max(1)) {
            if listen.push(piece, RATE).unwrap() == StreamVadEvent::SegmentEnded {
                ended = true;
            }
        }
        assert!(ended, "first phrase must close");
        // Do not take_closed — simulates ASR still running.
        let _ = listen.push(&voiced_samples(1.2), RATE).unwrap();
        assert!(listen.is_speaking());
        assert_eq!(listen.stop(), StreamVadEvent::SegmentEnded);
        let a = listen.take_closed().expect("queued first phrase");
        let b = listen.take_closed().expect("flushed second phrase");
        assert!(
            (a.len() as f32 / RATE as f32) > 0.6,
            "first window too short ({:.2}s)",
            a.len() as f32 / RATE as f32
        );
        assert!(
            (b.len() as f32 / RATE as f32) > 0.6,
            "release flush dropped the open phrase ({:.2}s)",
            b.len() as f32 / RATE as f32
        );
        assert!(listen.take_closed().is_none());
    }

    #[test]
    fn restore_closed_requeues_the_window() {
        let mut listen = StreamListen::start().unwrap();
        let mut pcm = voiced_samples(1.0);
        pcm.extend(silence(1.5));
        assert_eq!(
            listen.push(&pcm, RATE).unwrap(),
            StreamVadEvent::SegmentEnded
        );
        let window = listen.take_closed().unwrap();
        listen.restore_closed(window.clone());
        let again = listen.take_closed().unwrap();
        assert_eq!(again.len(), window.len());
    }

    #[test]
    fn focus_mode_needs_longer_silence_than_streaming() {
        // ~1.0s gap: streaming should close; focus (1.5s) should still be open.
        let mut pcm = voiced_samples(0.8);
        pcm.extend(silence(1.0));

        let mut streaming = StreamListen::start().unwrap();
        let stream_events = push_all(&mut streaming, &pcm);
        assert!(
            stream_events.contains(&StreamVadEvent::SegmentEnded),
            "streaming (~0.7s) must close after 1.0s silence: {stream_events:?}"
        );

        let mut focus = StreamListen::start_focus().unwrap();
        let focus_events = push_all(&mut focus, &pcm);
        assert!(
            !focus_events.contains(&StreamVadEvent::SegmentEnded),
            "focus (1.5s) must stay open after 1.0s silence: {focus_events:?}"
        );
        assert!(focus.is_speaking());

        let after = push_all(&mut focus, &silence(0.7));
        assert!(
            after.contains(&StreamVadEvent::SegmentEnded),
            "focus must close after reaching ~1.5s silence: {after:?}"
        );
    }
}

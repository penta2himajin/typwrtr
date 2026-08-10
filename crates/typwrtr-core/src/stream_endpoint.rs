//! Live Earshot + Segmenter endpointing for streaming PTT (VAD stage 2 pilot).
//!
//! The segmenter decides *when* a phrase ends. Closed PCM is the mic window
//! accumulated since the previous close (or listen start) — not a slice on
//! `SpeechSegment` bounds. [`crate::engine::DictationEngine::dictate`] runs
//! pipeline Earshot again for trim / NoSpeech (backend default threshold 0.2).
//!
//! Live endpointing uses a higher score cutoff than dictate trim: see
//! [`streaming_live_config`]. Focus Dictation still uses the Swift energy
//! detector until a later stage.

use std::time::Duration;

use euhadra::vad::{EarshotVad, Segmenter, SegmenterConfig, VadBackend, VadStream};

use crate::endpoint::{SPEECH_START_PAD_SAMPLES, STREAMING_PTT_SILENCE_MS};

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
/// trim / WER ([`docs.rs` earshot module](https://docs.rs/euhadra/latest/euhadra/vad/struct.EarshotVad.html));
/// that value keeps room tone as speech on laptop mics, so mid-hold never
/// closed (dogfood 2026-08-11). For streaming segment boundaries we follow
/// the Earshot live preset published by rlx-vad (`SegmentParams::earshot`:
/// threshold **0.35**, see crates.io / README) — still below the earshot
/// crate README's 0.5, which euhadra measured as harmful for recall.
pub const STREAMING_EARSHOT_ENDPOINT_THRESHOLD: f32 = 0.35;

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

/// Segmenter policy for streaming live endpointing.
///
/// - `threshold`: [`STREAMING_EARSHOT_ENDPOINT_THRESHOLD`] (rlx-vad Earshot preset)
/// - `min_silence`: [`STREAMING_PTT_SILENCE_MS`] (euhadra `SegmenterConfig` default ballpark)
/// - other fields: euhadra `SegmenterConfig::default()`
fn streaming_live_config() -> SegmenterConfig {
    let mut config = SegmenterConfig::default();
    config.threshold = Some(STREAMING_EARSHOT_ENDPOINT_THRESHOLD);
    config.min_silence = Duration::from_millis(STREAMING_PTT_SILENCE_MS);
    config
}

impl StreamListen {
    /// Open a listening period with Earshot + streaming endpoint config.
    pub fn start() -> Result<Self, String> {
        let vad = EarshotVad::new();
        let sample_rate = 16_000;
        let segmenter =
            Segmenter::new(&vad, sample_rate, streaming_live_config()).map_err(|e| e.to_string())?;
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

    /// Append PCM and return at most one event. Pending closes stick until taken.
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
            if !self.closed.is_empty() {
                return Ok(StreamVadEvent::SegmentEnded);
            }
            return Ok(StreamVadEvent::None);
        }

        self.push_samples(samples)
    }

    fn push_samples(&mut self, samples: &[f32]) -> Result<StreamVadEvent, String> {
        self.utterance.extend_from_slice(samples);
        self.pending_frame.extend_from_slice(samples);

        let mut saw_speech_started = false;
        let mut saw_segment_ended = false;

        while self.pending_frame.len() >= self.frame_size {
            let frame: Vec<f32> = self.pending_frame.drain(..self.frame_size).collect();
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

        if saw_segment_ended || !self.closed.is_empty() {
            return Ok(StreamVadEvent::SegmentEnded);
        }
        if saw_speech_started {
            return Ok(StreamVadEvent::SpeechStarted);
        }
        Ok(StreamVadEvent::None)
    }

    /// End the listen. Flushes an open utterance only (no quiet-tail ASR).
    pub fn stop(&mut self) -> StreamVadEvent {
        if !self.closed.is_empty() {
            return StreamVadEvent::SegmentEnded;
        }
        if !self.segmenter.is_speaking() {
            self.utterance.clear();
            self.pending_frame.clear();
            return StreamVadEvent::None;
        }
        if self.segmenter.flush().is_some() {
            self.seal_utterance_window();
            self.was_speaking = false;
            return StreamVadEvent::SegmentEnded;
        }
        self.utterance.clear();
        self.pending_frame.clear();
        StreamVadEvent::None
    }

    /// Pop one closed utterance's PCM.
    pub fn take_closed(&mut self) -> Option<Vec<f32>> {
        if self.closed.is_empty() {
            return None;
        }
        Some(self.closed.remove(0))
    }

    /// Seal the mic window accumulated since the last seal.
    ///
    /// Unframed remainder stays as the start of the next window.
    fn seal_utterance_window(&mut self) {
        let rem = self.pending_frame.len();
        let mut window = std::mem::take(&mut self.utterance);
        if rem > 0 && rem <= window.len() {
            self.utterance = window[window.len() - rem..].to_vec();
            window.truncate(window.len() - rem);
        } else {
            self.utterance.clear();
        }
        if !window.is_empty() {
            self.closed.push(window);
        }
    }

    fn trim_utterance_to_speech_pad(&mut self) {
        let keep = crate::endpoint::speech_start_keep_len(
            self.utterance.len(),
            SPEECH_START_PAD_SAMPLES,
        );
        if self.utterance.len() > keep {
            self.utterance = self.utterance[self.utterance.len() - keep..].to_vec();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_audio::{voiced_samples, RATE};

    fn silence(seconds: f32) -> Vec<f32> {
        vec![0.0; (seconds * RATE as f32) as usize]
    }

    fn push_all(listen: &mut StreamListen, samples: &[f32]) -> Vec<StreamVadEvent> {
        let chunk = (RATE as f32 * 0.08) as usize;
        let mut events = Vec::new();
        for piece in samples.chunks(chunk.max(1)) {
            loop {
                let ev = listen.push(piece, RATE).unwrap();
                if ev == StreamVadEvent::None {
                    break;
                }
                events.push(ev);
                if ev == StreamVadEvent::SegmentEnded {
                    assert!(
                        listen.take_closed().is_some(),
                        "SegmentEnded must leave a closed buffer"
                    );
                    continue;
                }
                break;
            }
        }
        events
    }

    #[test]
    fn live_endpoint_threshold_matches_rlx_earshot_preset() {
        assert!((STREAMING_EARSHOT_ENDPOINT_THRESHOLD - 0.35).abs() < f32::EPSILON);
        const _: () = assert!(STREAMING_EARSHOT_ENDPOINT_THRESHOLD > 0.2);
        const _: () = assert!(STREAMING_EARSHOT_ENDPOINT_THRESHOLD < 0.5);
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
            loop {
                let ev = listen.push(piece, RATE).unwrap();
                if ev == StreamVadEvent::SegmentEnded {
                    let closed = listen.take_closed().expect("closed");
                    closed_lens.push(closed.len());
                    continue;
                }
                if ev == StreamVadEvent::None {
                    break;
                }
                break;
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
}

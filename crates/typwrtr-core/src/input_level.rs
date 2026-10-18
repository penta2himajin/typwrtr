//! "No microphone input" check (ux-decisions Q43).
//!
//! Distinct from "no speech" (Q24): this is about the *signal level*, not the
//! detector. A muted or dead input delivers digital zero or close to it, far
//! below measured room tone (−45 dBFS), so a plain RMS cutoff separates them.

/// RMS at or below this is no input: −60 dBFS, 15 dB under measured room tone.
pub const DEAD_INPUT_RMS: f32 = 0.001;

/// Samples hands-free / Focus Dictation wait for before judging (~2 s @ 16 kHz).
pub const DEAD_INPUT_PROBE_SAMPLES: usize = 32_000;

/// True when `samples` carry no microphone signal. An empty capture counts as
/// dead: a mic that delivers nothing is the worst case, not a pass.
pub fn is_dead_input(samples: &[f32]) -> bool {
    if samples.is_empty() {
        return true;
    }
    let energy: f64 = samples.iter().map(|&s| f64::from(s) * f64::from(s)).sum();
    (energy / samples.len() as f64).sqrt() <= f64::from(DEAD_INPUT_RMS)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tone(amplitude: f32, len: usize) -> Vec<f32> {
        (0..len)
            .map(|i| amplitude * (i as f32 * 0.07).sin())
            .collect()
    }

    #[test]
    fn digital_silence_is_dead() {
        assert!(is_dead_input(&vec![0.0; DEAD_INPUT_PROBE_SAMPLES]));
    }

    #[test]
    fn empty_capture_is_dead() {
        assert!(is_dead_input(&[]));
    }

    #[test]
    fn room_tone_is_alive() {
        // −45 dBFS RMS: a sine with RMS 0.0056 has peak 0.0056 * √2.
        let rms = 10f32.powf(-45.0 / 20.0);
        assert!(!is_dead_input(&tone(rms * 2f32.sqrt(), 16_000)));
    }

    #[test]
    fn speech_level_is_alive() {
        assert!(!is_dead_input(&tone(0.2, 16_000)));
    }

    #[test]
    fn a_short_burst_in_silence_is_alive() {
        // 0.25 s of speech inside 2 s of zeros still proves the mic works.
        let mut samples = vec![0.0; DEAD_INPUT_PROBE_SAMPLES];
        samples[8_000..12_000].copy_from_slice(&tone(0.2, 4_000));
        assert!(!is_dead_input(&samples));
    }
}

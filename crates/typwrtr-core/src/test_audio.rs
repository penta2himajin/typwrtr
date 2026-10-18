//! Synthetic audio for tests.
//!
//! The pipeline now runs voice activity detection ahead of the ASR adapter, so a
//! buffer of zeroes is rejected as no-speech before any adapter is called. Tests
//! that only care about the text stages still need audio the detector accepts.
//!
//! Measured against `EarshotVad` (threshold 0.2): the signal below scores ~0.83
//! mean, silence ~0.18 mean with a ~0.28 peak. The peak is above the threshold,
//! which is why `min_speech` — not the threshold alone — is what keeps silence
//! from opening a segment.

use euhadra::types::AudioChunk;

pub(crate) const RATE: u32 = 16_000;

/// Stationary laptop-mic floor at about −45 dBFS (euhadra Earshot table).
///
/// Digital zeros are *not* a substitute: Earshot still peaks ~0.28 on
/// zeros, and the live endpoint needs a run of frames *below* the live cutoff.
pub(crate) fn room_tone(seconds: f32) -> Vec<f32> {
    let n = (seconds * RATE as f32) as usize;
    let mut state = 0x2545_F491_4F6C_DD1Du64;
    let amp = 10f32.powf(-45.0 / 20.0);
    (0..n)
        .map(|_| {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            let noise = (state >> 40) as f32 / 8_388_608.0 - 1.0;
            noise * amp
        })
        .collect()
}

/// Speech-like: a harmonic stack under a syllable-rate amplitude envelope.
pub(crate) fn voiced_samples(seconds: f32) -> Vec<f32> {
    let n = (seconds * RATE as f32) as usize;
    (0..n)
        .map(|i| {
            let t = i as f32 / RATE as f32;
            let envelope = 0.5 + 0.5 * (2.0 * std::f32::consts::PI * 4.0 * t).sin();
            let harmonics: f32 = (1..=12)
                .map(|h| {
                    let f = 120.0 * h as f32;
                    (2.0 * std::f32::consts::PI * f * t).sin() / h as f32
                })
                .sum();
            harmonics * envelope * 0.3
        })
        .collect()
}

/// Wrap samples as a single 16 kHz mono chunk.
pub(crate) fn chunk(samples: Vec<f32>) -> AudioChunk {
    AudioChunk {
        samples,
        sample_rate: RATE,
        channels: 1,
    }
}

/// One chunk of speech-like audio.
pub(crate) fn voiced_chunk(seconds: f32) -> AudioChunk {
    chunk(voiced_samples(seconds))
}

/// Speech-like audio with `pad` seconds of silence either side.
pub(crate) fn voiced_padded_with_silence(speech: f32, pad: f32) -> Vec<f32> {
    let pad_samples = (pad * RATE as f32) as usize;
    let mut out = vec![0.0; pad_samples];
    out.extend(voiced_samples(speech));
    out.extend(std::iter::repeat_n(0.0, pad_samples));
    out
}

/// Add desk-tap transients to `samples`: a decaying 300 Hz burst every 0.7 s.
///
/// Over −49 dBFS noise these score 0.5–0.66 under Earshot and, at the 0.2
/// calibration, held a dictate segment open across the whole buffer.
pub(crate) fn with_desk_taps(mut samples: Vec<f32>) -> Vec<f32> {
    let step = (0.7 * RATE as f32) as usize;
    let mut at = step / 2;
    while at < samples.len() {
        for (k, s) in samples[at..].iter_mut().take(800).enumerate() {
            let t = k as f32 / RATE as f32;
            *s += 0.1 * (-t * 120.0).exp() * (2.0 * std::f32::consts::PI * 300.0 * t).sin();
        }
        at += step;
    }
    samples
}

/// Scale `samples` to `dbfs` RMS.
pub(crate) fn at_dbfs(samples: Vec<f32>, dbfs: f32) -> Vec<f32> {
    let rms = (samples.iter().map(|x| x * x).sum::<f32>() / samples.len() as f32).sqrt();
    let gain = 10f32.powf(dbfs / 20.0) / rms;
    samples.into_iter().map(|x| x * gain).collect()
}

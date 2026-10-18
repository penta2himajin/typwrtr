//! One-key activation rules (ux-decisions Q44–Q45). The shell owns the timers;
//! these decide what a press or a pause means, so the thresholds live in one place.

/// A press held for less than this may be the first tap of a double-tap.
pub const TAP_MAX_MS: u64 = 300;

/// A second press within this long after a short tap's release starts hands-free.
pub const DOUBLE_TAP_WINDOW_MS: u64 = 400;

/// Hands-free ends after this long without speech (Q45, R4-Q1). Tuned on dogfood;
/// VAP is the candidate replacement (typwrtr#5).
pub const HANDS_FREE_IDLE_END_MS: u64 = 20_000;

/// Whether a press of `held_ms` may be the first tap of a double-tap. Longer presses
/// are push-to-talk and are processed at once.
pub fn is_possible_first_tap(held_ms: u64) -> bool {
    held_ms < TAP_MAX_MS
}

/// Whether a second press `gap_ms` after a short tap's release is a double-tap.
pub fn is_double_tap(gap_ms: u64) -> bool {
    gap_ms <= DOUBLE_TAP_WINDOW_MS
}

/// Whether hands-free has gone `idle_ms` without speech and should end.
pub fn hands_free_idle_expired(idle_ms: u64) -> bool {
    idle_ms >= HANDS_FREE_IDLE_END_MS
}

/// What a lone short tap does once the double-tap window passes (Q46).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SingleTap {
    /// Focus Dictation was listening: stop it and hold, as Esc does.
    StopFocus,
    /// Focus Dictation was held after Esc or a tap: listen again.
    ResumeFocus,
    /// Focus Dictation had nothing to toggle: process the capture as batch PTT.
    BatchPtt,
}

/// Decide a lone tap from Focus Dictation's state at key-down, which the shell must
/// record then: PTT closes the Focus mic on key-down, before the press is known to
/// be a tap.
pub fn single_tap_action(focus_listening: bool, focus_held: bool) -> SingleTap {
    if focus_listening {
        SingleTap::StopFocus
    } else if focus_held {
        SingleTap::ResumeFocus
    } else {
        SingleTap::BatchPtt
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn short_presses_may_be_taps_long_ones_are_ptt() {
        assert!(is_possible_first_tap(0));
        assert!(is_possible_first_tap(299));
        assert!(!is_possible_first_tap(300));
        assert!(!is_possible_first_tap(2_000));
    }

    #[test]
    fn double_tap_window_is_inclusive_at_400ms() {
        assert!(is_double_tap(0));
        assert!(is_double_tap(400));
        assert!(!is_double_tap(401));
    }

    #[test]
    fn hands_free_ends_after_20s_without_speech() {
        assert!(!hands_free_idle_expired(19_999));
        assert!(hands_free_idle_expired(20_000));
    }

    #[test]
    fn a_single_tap_toggles_focus_dictation_or_falls_back_to_batch_ptt() {
        assert_eq!(single_tap_action(true, false), SingleTap::StopFocus);
        assert_eq!(single_tap_action(false, true), SingleTap::ResumeFocus);
        assert_eq!(single_tap_action(false, false), SingleTap::BatchPtt);
        // An open mic is what the user sees, so stopping it wins.
        assert_eq!(single_tap_action(true, true), SingleTap::StopFocus);
    }

    #[test]
    fn a_tap_and_its_window_fit_inside_a_brisk_double_tap() {
        // The window is measured from the first tap's release, not press-to-press.
        assert!(is_possible_first_tap(150) && is_double_tap(200));
    }
}

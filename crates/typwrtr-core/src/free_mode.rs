//! Free/VAD (F3) arming and focus-gate policy.
//!
//! Mic / VAD / AX live in the Swift shell; this module owns the pure rules from
//! `docs/ux-decisions.md` §2 (F3) and §6 (secure fields).

use std::sync::{Arc, Mutex};

/// Accessibility focus classification supplied by the shell (stub inputs in tests).
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FocusKind {
    /// Clear text-field role (AXTextField / AXTextArea / editable combo text).
    TextField,
    /// Password / secure text field — Free is always blocked.
    SecureField,
    /// Focused element that is not a Free-eligible text field (or unknown).
    Other,
}

/// Coarse Free availability for menu-bar feedback (Q4: no silent failure).
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FreeAvailability {
    /// Disarmed — Free will not listen.
    Disarmed,
    /// Armed and currently allowed to open the mic.
    Listening,
    /// Armed, but no eligible text field is focused yet.
    ArmedWaitingFocus,
    /// Armed, focus exists but is not classified as a Free text field (or is secure).
    UnavailableExplained,
}

/// Explicit Free arming state (F3).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct FreeArmState {
    armed: bool,
}

impl FreeArmState {
    /// Create a disarmed Free controller.
    pub fn new() -> Self {
        Self { armed: false }
    }

    /// Explicitly arm Free mode.
    pub fn arm(&mut self) {
        self.armed = true;
    }

    /// Explicitly disarm Free mode.
    pub fn disarm(&mut self) {
        self.armed = false;
    }

    /// Whether Free is armed (independent of focus).
    pub fn is_armed(&self) -> bool {
        self.armed
    }

    /// Whether the mic should be open for Free listening right now.
    ///
    /// Requires armed + text field focus; secure fields never listen.
    pub fn should_listen(&self, focus: FocusKind) -> bool {
        self.armed && matches!(focus, FocusKind::TextField)
    }

    /// Menu / status feedback for the current focus.
    pub fn availability(&self, focus: FocusKind) -> FreeAvailability {
        if !self.armed {
            return FreeAvailability::Disarmed;
        }
        match focus {
            FocusKind::TextField => FreeAvailability::Listening,
            FocusKind::SecureField | FocusKind::Other => FreeAvailability::UnavailableExplained,
        }
    }

    /// When armed but there is no focus probe result yet.
    pub fn availability_without_focus(&self) -> FreeAvailability {
        if self.armed {
            FreeAvailability::ArmedWaitingFocus
        } else {
            FreeAvailability::Disarmed
        }
    }
}

/// Thread-safe Free arming handle for Swift (UniFFI).
#[derive(uniffi::Object)]
pub struct FreeController {
    inner: Mutex<FreeArmState>,
}

#[uniffi::export]
impl FreeController {
    /// Disarmed controller.
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            inner: Mutex::new(FreeArmState::new()),
        })
    }

    /// Arm Free mode.
    pub fn arm(&self) {
        self.inner.lock().expect("free lock").arm();
    }

    /// Disarm Free mode.
    pub fn disarm(&self) {
        self.inner.lock().expect("free lock").disarm();
    }

    /// Whether Free is armed.
    pub fn is_armed(&self) -> bool {
        self.inner.lock().expect("free lock").is_armed()
    }

    /// Whether Free should open the mic for this focus.
    pub fn should_listen(&self, focus: FocusKind) -> bool {
        self.inner.lock().expect("free lock").should_listen(focus)
    }

    /// Availability for a known focus kind.
    pub fn availability(&self, focus: FocusKind) -> FreeAvailability {
        self.inner.lock().expect("free lock").availability(focus)
    }

    /// Availability when no focused element was found.
    pub fn availability_without_focus(&self) -> FreeAvailability {
        self.inner
            .lock()
            .expect("free lock")
            .availability_without_focus()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn free_listening_requires_arm_and_text_focus() {
        let mut free = FreeArmState::default();
        assert!(!free.is_armed());
        assert!(!free.should_listen(FocusKind::TextField));
        assert!(!free.should_listen(FocusKind::Other));
        assert_eq!(
            free.availability(FocusKind::TextField),
            FreeAvailability::Disarmed
        );

        free.arm();
        assert!(free.is_armed());
        assert!(free.should_listen(FocusKind::TextField));
        assert!(!free.should_listen(FocusKind::Other));
        assert!(!free.should_listen(FocusKind::SecureField));
        assert_eq!(
            free.availability(FocusKind::TextField),
            FreeAvailability::Listening
        );
        assert_eq!(
            free.availability(FocusKind::Other),
            FreeAvailability::UnavailableExplained
        );
        assert_eq!(
            free.availability(FocusKind::SecureField),
            FreeAvailability::UnavailableExplained
        );
        assert_eq!(
            free.availability_without_focus(),
            FreeAvailability::ArmedWaitingFocus
        );

        free.disarm();
        assert!(!free.should_listen(FocusKind::TextField));
        assert_eq!(
            free.availability(FocusKind::TextField),
            FreeAvailability::Disarmed
        );
    }

    #[test]
    fn free_controller_ffi_surface() {
        let free = FreeController::new();
        assert!(!free.is_armed());
        free.arm();
        assert!(free.should_listen(FocusKind::TextField));
        assert_eq!(
            free.availability(FocusKind::Other),
            FreeAvailability::UnavailableExplained
        );
        free.disarm();
        assert!(!free.is_armed());
    }
}

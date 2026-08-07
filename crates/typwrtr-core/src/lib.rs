//! Typwrtr core: PTT session state and (later) euhadra transcription.
//!
//! Emission (Accessibility / clipboard) stays in the Swift shell.
//! See `docs/architecture.md`.

#![deny(missing_docs)]

mod session;

pub use session::{Session, SessionError, SessionStatus};

/// Workspace pin check: ensure `euhadra` resolves at build time.
#[inline]
pub fn euhadra_dependency_linked() -> bool {
    // Touch the crate so unused-dependency lint stays quiet until pipeline wiring.
    let _ = std::any::type_name::<euhadra::types::ContextSnapshot>();
    true
}

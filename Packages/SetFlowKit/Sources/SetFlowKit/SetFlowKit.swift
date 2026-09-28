/// SetFlowKit — pure-domain core for Set Flow.
///
/// Issue #1 ships only the skeleton namespace so CI has a real, testable
/// target. Issue #2 (domain) lands the routine/session entities
/// (`Routine`, `Exercise`, `SetBlock`, `Session`, `SetEntry`, `SessionNote`),
/// the versioned schema contract, and deterministic derivation helpers here.
/// The deterministic set queue and rest-timer state machine arrive with
/// issue #3, training summaries with issue #5, and the versioned JSON backup
/// plus CSV export codecs with issue #6. The GRDB store lives outside this
/// package.
public enum SetFlowKit {
    /// Namespace marker for the domain layer.
    public static let domain = "SetFlowKit"

    /// Current build/CI milestone marker consumed by the app's debug surface.
    public static let milestone = "M0-skeleton"
}

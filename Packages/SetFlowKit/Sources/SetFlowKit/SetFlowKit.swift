/// SetFlowKit — pure-domain core for Set Flow.
///
/// Issue #2 extends the skeleton namespace with stable models and validation contracts
/// that are serialization-safe and deterministic for local-first persistence.
/// Issue #3 adds the deterministic session queue engine and the durable rest-timer.
public enum SetFlowKit {
    /// Namespace marker for the domain layer.
    public static let domain = "SetFlowKit"

    /// Current build/CI milestone marker consumed by the app's debug surface.
    public static let milestone = "M2-session-runtime"

    /// Domain schema revision shared with persistence migrations.
    public static let domainSchemaVersion = 4
}

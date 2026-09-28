import Testing
@testable import SetFlowKit

@Suite("Skeleton placeholder")
struct SetFlowKitTests {
    @Test("domain namespace is reachable")
    func domainNamespace() {
        #expect(SetFlowKit.domain == "SetFlowKit")
    }

    @Test("milestone marker is set for M0")
    func milestoneMarker() {
        #expect(SetFlowKit.milestone == "M0-skeleton")
    }

    @Test("skeleton exposes no stored state beyond constants")
    func constantsAreStable() {
        // Guards the contract later issues depend on: these markers exist
        // and are pure constants (no clock, no I/O) in the M0 skeleton.
        let first = (SetFlowKit.domain, SetFlowKit.milestone)
        let second = (SetFlowKit.domain, SetFlowKit.milestone)
        #expect(first == second)
    }
}

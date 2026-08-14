import LoggingDomain
@testable import VirtualMachineDomain
import XCTest

final class VirtualMachineFleetTests: XCTestCase {
    @MainActor
    func testStopImmediatelyAndWaitDeletesTheRunningClone() async throws {
        let probe = VirtualMachineProbe()
        let virtualMachine = StubVirtualMachine(
            name: "base",
            probe: probe,
            returnsNormallyWhenCancelled: false
        )
        let fleet = VirtualMachineFleet(logger: StubLogger(), baseVirtualMachine: virtualMachine)

        fleet.start(numberOfMachines: 1)
        try await waitUntil { await probe.didStart }

        await fleet.stopImmediatelyAndWait()

        let didDelete = await probe.didDelete
        XCTAssertTrue(didDelete)
        XCTAssertFalse(fleet.isStarted)
    }

    @MainActor
    func testStopImmediatelyDeletesCloneWhenStartSwallowsCancellation() async throws {
        let probe = VirtualMachineProbe()
        let virtualMachine = StubVirtualMachine(
            name: "base",
            probe: probe,
            returnsNormallyWhenCancelled: true
        )
        let fleet = VirtualMachineFleet(logger: StubLogger(), baseVirtualMachine: virtualMachine)

        fleet.start(numberOfMachines: 1)
        try await waitUntil { await probe.didStart }

        await fleet.stopImmediatelyAndWait()

        let didDelete = await probe.didDelete
        XCTAssertTrue(didDelete)
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while await condition() == false {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor VirtualMachineProbe {
    var didStart = false
    var didDelete = false

    func recordStart() {
        didStart = true
    }

    func recordDelete() {
        didDelete = true
    }
}

private final class StubVirtualMachine: VirtualMachine {
    let name: String
    let canStart = true

    private let probe: VirtualMachineProbe
    private let returnsNormallyWhenCancelled: Bool

    init(
        name: String,
        probe: VirtualMachineProbe,
        returnsNormallyWhenCancelled: Bool
    ) {
        self.name = name
        self.probe = probe
        self.returnsNormallyWhenCancelled = returnsNormallyWhenCancelled
    }

    func start() async throws {
        await probe.recordStart()
        do {
            try await Task.sleep(for: .seconds(30))
        } catch is CancellationError where returnsNormallyWhenCancelled {
            return
        }
    }

    func clone(named newName: String) async throws -> VirtualMachine {
        StubVirtualMachine(
            name: newName,
            probe: probe,
            returnsNormallyWhenCancelled: returnsNormallyWhenCancelled
        )
    }

    func delete() async throws {
        try await Task.sleep(for: .milliseconds(100))
        await probe.recordDelete()
    }

    func getIPAddress() async throws -> String {
        "127.0.0.1"
    }
}

private struct StubLogger: Logger {
    func info(_ message: String) {}
    func error(_ message: String) {}
}

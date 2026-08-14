import LoggingDomain
@testable import VirtualMachineDomain
import XCTest

final class VirtualMachineEditorTests: XCTestCase {
    @MainActor
    func testStopImmediatelyAndWaitWaitsForTheEditorTaskToFinish() async throws {
        let probe = EditorProbe()
        let editor = VirtualMachineEditor(
            logger: EditorStubLogger(),
            virtualMachine: EditorStubVirtualMachine(probe: probe)
        )

        editor.start()
        try await waitUntil { await probe.didStart }

        await editor.stopImmediatelyAndWait()

        let didFinish = await probe.didFinish
        XCTAssertTrue(didFinish)
        XCTAssertFalse(editor.isStarted)
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

private actor EditorProbe {
    var didStart = false
    var didFinish = false

    func recordStart() {
        didStart = true
    }

    func recordFinish() {
        didFinish = true
    }
}

private final class EditorStubVirtualMachine: VirtualMachine {
    let name = "editor"
    let canStart = true

    private let probe: EditorProbe

    init(probe: EditorProbe) {
        self.probe = probe
    }

    func start() async throws {
        await probe.recordStart()
        do {
            try await Task.sleep(for: .seconds(30))
        } catch is CancellationError {
            let cleanupTask = Task.detached { [probe] in
                try await Task.sleep(for: .milliseconds(100))
                await probe.recordFinish()
            }
            try await cleanupTask.value
        }
    }

    func clone(named newName: String) async throws -> VirtualMachine {
        self
    }

    func delete() async throws {}

    func getIPAddress() async throws -> String {
        "127.0.0.1"
    }
}

private struct EditorStubLogger: Logger {
    func info(_ message: String) {}
    func error(_ message: String) {}
}

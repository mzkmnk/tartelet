import Foundation
import ShellData
import XCTest

final class ProcessShellTests: XCTestCase {
    func testWritesStandardInputAndClosesThePipe() async throws {
        let output = try await ProcessShell().runExecutable(
            atPath: "/bin/cat",
            withArguments: [],
            environment: [:],
            standardInput: "hello\n"
        )

        XCTAssertEqual(output, "hello\n")
    }

    func testCancellationTerminatesTheProcess() async throws {
        let task = Task {
            try await ProcessShell().runExecutable(
                atPath: "/bin/sleep",
                withArguments: ["30"],
                environment: [:],
                standardInput: nil
            )
        }

        try await Task.sleep(for: .milliseconds(100))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected the cancelled shell command to throw")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testCancellationBeforeRunDoesNotLaunchTheProcess() async throws {
        let markerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: markerURL) }

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ProcessShell().runExecutable(
                atPath: "/usr/bin/touch",
                withArguments: [markerURL.path],
                environment: [:],
                standardInput: nil
            )
        }

        do {
            _ = try await task.value
            XCTFail("Expected the cancelled shell command to throw")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
    }
}

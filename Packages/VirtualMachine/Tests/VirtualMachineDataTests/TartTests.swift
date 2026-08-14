import Foundation
import ShellDomain
@testable import VirtualMachineData
import XCTest

final class TartTests: XCTestCase {
    func testHeadlessRunOptionsAreIntrinsicAndNotDuplicated() {
        let tart = Tart(
            homeProvider: StubTartHomeProvider(),
            shell: StubShell(),
            defaultRunOptions: ["--no-graphics"]
        )

        let arguments = tart.makeRunArguments(
            name: "runner-1",
            cacheFolder: URL(fileURLWithPath: "/tmp/tart-cache"),
            environmentRunOption: "--no-graphics"
        )

        XCTAssertEqual(
            arguments,
            ["run", "--dir=cache:/tmp/tart-cache", "--no-graphics", "runner-1"]
        )
    }

    func testNormalRunOptionsRemainUnchanged() {
        let tart = Tart(
            homeProvider: StubTartHomeProvider(),
            shell: StubShell()
        )

        let arguments = tart.makeRunArguments(
            name: "editor",
            cacheFolder: URL(fileURLWithPath: "/tmp/tart-cache"),
            environmentRunOption: nil
        )

        XCTAssertEqual(arguments, ["run", "--dir=cache:/tmp/tart-cache", "editor"])
    }
}

private struct StubTartHomeProvider: TartHomeProvider {
    let homeFolderURL: URL? = nil
}

private struct StubShell: Shell {
    func runExecutable(
        atPath executablePath: String,
        withArguments arguments: [String],
        environment: [String: String],
        standardInput: String?
    ) async throws -> String {
        ""
    }
}

import Foundation
import ShellDomain

public struct ProcessShell: Shell {
    public init() {}

    public func runExecutable(
        atPath executablePath: String,
        withArguments arguments: [String],
        environment: [String: String],
        standardInput: String?
    ) async throws -> String {
        let process = Process()
        let sendableProcess = SendableProcess(process)
        return try await withTaskCancellationHandler {
            let pipe = Pipe()
            process.standardOutput = pipe
            process.arguments = arguments
            process.launchPath = executablePath
            let standardInputPipe = standardInput.map { _ in Pipe() }
            process.standardInput = standardInputPipe
            process.environment = environment
            try process.run()
            if let standardInput, let standardInputPipe {
                standardInputPipe.fileHandleForWriting.write(Data(standardInput.utf8))
                try standardInputPipe.fileHandleForWriting.close()
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            // Explicitly close the pipe file handle to prevent running out of file descriptors.
            // See https://github.com/swiftlang/swift/issues/57827
            try pipe.fileHandleForReading.close()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw ProcessShellError.unexpectedTerminationStatus(process.terminationStatus)
            }
            return String(data: data, encoding: .utf8) ?? ""
        } onCancel: {
            if sendableProcess.process.isRunning {
                sendableProcess.process.terminate()
            }
        }
    }
}

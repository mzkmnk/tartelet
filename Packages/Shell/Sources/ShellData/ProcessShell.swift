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
        let pipe = Pipe()
        process.standardOutput = pipe
        process.arguments = arguments
        process.launchPath = executablePath
        let standardInputPipe = standardInput.map { _ in Pipe() }
        process.standardInput = standardInputPipe
        process.environment = environment
        let sendableProcess = SendableProcess(process)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try sendableProcess.run()
            if let standardInputPipe {
                if let standardInput, Task.isCancelled == false {
                    standardInputPipe.fileHandleForWriting.write(Data(standardInput.utf8))
                }
                try standardInputPipe.fileHandleForWriting.close()
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            // Explicitly close the pipe file handle to prevent running out of file descriptors.
            // See https://github.com/swiftlang/swift/issues/57827
            try pipe.fileHandleForReading.close()
            process.waitUntilExit()
            try Task.checkCancellation()
            guard process.terminationStatus == 0 else {
                throw ProcessShellError.unexpectedTerminationStatus(process.terminationStatus)
            }
            return String(data: data, encoding: .utf8) ?? ""
        } onCancel: {
            sendableProcess.cancel()
        }
    }
}

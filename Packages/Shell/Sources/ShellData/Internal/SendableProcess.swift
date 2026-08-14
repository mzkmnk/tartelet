import Foundation

final class SendableProcess: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var cancellationRequested = false

    init(_ process: Process) {
        self.process = process
    }

    func run() throws {
        lock.lock()
        defer { lock.unlock() }
        guard cancellationRequested == false, Task.isCancelled == false else {
            throw CancellationError()
        }
        try process.run()
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancellationRequested = true
        if process.isRunning {
            process.terminate()
        }
    }
}

import Foundation
import LoggingDomain

@MainActor
@Observable
public final class VirtualMachineEditor {
    public private(set) var isStarted = false

    private let logger: Logger
    private let virtualMachine: VirtualMachine
    @ObservationIgnored
    private var runTask: Task<(), Error>? {
        didSet {
            isStarted = runTask != nil
        }
    }

    public init(logger: Logger, virtualMachine: VirtualMachine) {
        self.logger = logger
        self.virtualMachine = virtualMachine
    }

    public func start() {
        guard runTask == nil else {
            return
        }
        logger.info("Will start virtual machine editor...")
        runTask = Task {
            defer {
                self.runTask = nil
                self.logger.info("Did stop virtual machine editor")
            }
            try await virtualMachine.start()
        }
    }

    public func stop() {
        runTask?.cancel()
    }

    public func stopImmediatelyAndWait() async {
        guard let runTask else {
            return
        }
        runTask.cancel()
        _ = try? await runTask.value
    }
}

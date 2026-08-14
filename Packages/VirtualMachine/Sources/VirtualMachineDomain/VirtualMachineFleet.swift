import LoggingDomain
import Observation

@MainActor
@Observable
public final class VirtualMachineFleet {
    public private(set) var isStarted = false
    public private(set) var isStopping = false

    private let logger: Logger
    private let baseVirtualMachine: VirtualMachine
    private var activeTasks: [String: Task<(), Never>] = [:]

    public init(logger: Logger, baseVirtualMachine: VirtualMachine) {
        self.logger = logger
        self.baseVirtualMachine = baseVirtualMachine
    }

    public func start(numberOfMachines: Int) {
        guard !isStarted, !isStopping, numberOfMachines > 0 else {
            return
        }
        guard baseVirtualMachine.canStart else {
            return
        }
        isStarted = true
        for index in 0 ..< numberOfMachines {
            let name = baseVirtualMachine.name + "-\(index + 1)"
            startSequentiallyRunningVirtualMachines(named: name)
        }
    }

    public func stopImmediately() {
        _ = cancelAllActiveTasks()
    }

    public func stopImmediatelyAndWait() async {
        let tasks = cancelAllActiveTasks()
        for task in tasks {
            await task.value
        }
    }

    public func stop() {
        isStopping = true
    }

    private func cancelAllActiveTasks() -> [Task<(), Never>] {
        isStarted = false
        isStopping = true
        let tasks = Array(activeTasks.values)
        for task in tasks {
            task.cancel()
        }
        if tasks.isEmpty {
            isStopping = false
        }
        return tasks
    }
}

private extension VirtualMachineFleet {
    private func startSequentiallyRunningVirtualMachines(named name: String) {
        let task = Task {
            while !Task.isCancelled, !isStopping {
                do {
                    let virtualMachine = try await baseVirtualMachine.clone(named: name)
                    try await runVirtualMachine(virtualMachine)
                } catch {
                    // Ignore the error and try again until the task is cancelled. The error should
                    // have been logged so we know what is going on in case we need to debug.
                    // However, the actual error is not important at this point so we ignore it and
                    // let the loop run again, thus giving us another chance to start the virtual machine.
                }
            }
            logger.info("Task running virtual machine named \(name) was cancelled.")
            activeTasks.removeValue(forKey: name)
            if activeTasks.isEmpty {
                isStarted = false
                isStopping = false
            }
        }
        activeTasks[name] = task
    }

    private func runVirtualMachine(_ virtualMachine: VirtualMachine) async throws {
        logger.info("Start virtual machine named \(virtualMachine.name)")
        do {
            try await virtualMachine.start()
            try Task.checkCancellation()
            logger.info("Did stop virtual machine named \(virtualMachine.name)")
        } catch {
            logger.info(
                "Virtual machine named \(virtualMachine.name) stopped with message: "
                + error.localizedDescription
            )
            try await deleteVirtualMachineAfterStart(virtualMachine)
            throw error
        }
        try await deleteVirtualMachineAfterStart(virtualMachine)
    }

    private func deleteVirtualMachineAfterStart(_ virtualMachine: VirtualMachine) async throws {
        logger.info("Delete virtual machine named \(virtualMachine.name)")
        do {
            let deletionTask = Task(priority: .high) {
                try await virtualMachine.delete()
            }
            try await deletionTask.value
            logger.info("Did delete virtual machine named \(virtualMachine.name)")
        } catch {
            logger.info(
                "Could not delete virtual machine named \(virtualMachine.name): "
                + error.localizedDescription
            )
            throw error
        }
    }
}

import Foundation
import LoggingDomain
import SSHDomain
import VirtualMachineDomain

private enum TartExecStartValue {
    case virtualMachineTerminated
    case guestAgentConfigured
}

private enum TartExecStartError: LocalizedError {
    case failedStartingVirtualMachine(Error)
    case failedConfiguringGuestAgent(Error)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .failedStartingVirtualMachine:
            "Failed starting virtual machine"
        case .failedConfiguringGuestAgent:
            "Failed configuring virtual machine through Tart Guest Agent"
        case .cancelled:
            "Task was cancelled"
        }
    }
}

private typealias TartExecStartResult = Result<TartExecStartValue, TartExecStartError>

public final class TartExecConnectingVirtualMachine: VirtualMachine {
    public var name: String {
        virtualMachine.name
    }

    public var canStart: Bool {
        virtualMachine.canStart
    }

    private let logger: Logger
    private let virtualMachine: VirtualMachine
    private let tart: Tart
    private let connectionHandler: VirtualMachineSSHConnectionHandler

    public init(
        logger: Logger,
        virtualMachine: VirtualMachine,
        tart: Tart,
        connectionHandler: VirtualMachineSSHConnectionHandler
    ) {
        self.logger = logger
        self.virtualMachine = virtualMachine
        self.tart = tart
        self.connectionHandler = connectionHandler
    }

    public func start() async throws {
        try await withThrowingTaskGroup(of: TartExecStartResult.self) { group in
            group.addTask {
                await self.startVirtualMachine()
            }
            group.addTask {
                await self.configureGuestAgent(of: self.virtualMachine)
            }
            for try await result in group {
                switch result {
                case let .success(value):
                    if case .virtualMachineTerminated = value {
                        group.cancelAll()
                    }
                case let .failure(error):
                    switch error {
                    case .failedStartingVirtualMachine, .failedConfiguringGuestAgent:
                        group.cancelAll()
                        throw error
                    case .cancelled:
                        break
                    }
                }
            }
        }
    }

    public func clone(named newName: String) async throws -> VirtualMachine {
        let clone = try await virtualMachine.clone(named: newName)
        return TartExecConnectingVirtualMachine(
            logger: logger,
            virtualMachine: clone,
            tart: tart,
            connectionHandler: connectionHandler
        )
    }

    public func delete() async throws {
        try await virtualMachine.delete()
    }

    public func getIPAddress() async throws -> String {
        try await virtualMachine.getIPAddress()
    }
}

private extension TartExecConnectingVirtualMachine {
    func startVirtualMachine() async -> TartExecStartResult {
        do {
            try await virtualMachine.start()
            return .success(.virtualMachineTerminated)
        } catch {
            if error is CancellationError {
                return .failure(.cancelled)
            }
            return .failure(.failedStartingVirtualMachine(error))
        }
    }

    func configureGuestAgent(of virtualMachine: VirtualMachine) async -> TartExecStartResult {
        do {
            let connection = TartExecConnection(
                logger: logger,
                tart: tart,
                virtualMachineName: virtualMachine.name
            )
            try await waitForGuestAgent(connection, virtualMachineName: virtualMachine.name)
            try await connectionHandler.didConnect(to: virtualMachine, through: connection)
            try await connection.close()
            return .success(.guestAgentConfigured)
        } catch {
            if error is CancellationError {
                return .failure(.cancelled)
            }
            logger.error(
                "Could not configure virtual machine through Tart Guest Agent: "
                    + error.localizedDescription
            )
            return .failure(.failedConfiguringGuestAgent(error))
        }
    }

    func waitForGuestAgent(
        _ connection: TartExecConnection,
        virtualMachineName: String,
        attempt: Int = 1,
        maximumAttempts: Int = 30
    ) async throws {
        do {
            try Task.checkCancellation()
            try await connection.executeCommand("true")
        } catch {
            guard attempt < maximumAttempts else {
                throw error
            }
            logger.info(
                "Waiting for Tart Guest Agent in virtual machine named "
                    + "\(virtualMachineName) (attempt \(attempt) of \(maximumAttempts))."
            )
            try await Task.sleep(for: .seconds(1))
            try await waitForGuestAgent(
                connection,
                virtualMachineName: virtualMachineName,
                attempt: attempt + 1,
                maximumAttempts: maximumAttempts
            )
        }
    }
}

private struct TartExecConnection: SSHConnection {
    let logger: Logger
    let tart: Tart
    let virtualMachineName: String

    func executeCommand(_ command: String) async throws {
        let output = try await tart.execute(command, inVirtualMachineNamed: virtualMachineName)
        if !output.isEmpty {
            logger.info(output)
        }
    }

    func close() async throws {}
}

import FileSystemData
import Foundation
import GitHubData
import GitHubDomain
import Keychain
import LoggingData
import LoggingDomain
import NetworkingData
import Observation
import Security
import SettingsData
import ShellData
import SSHData
import VirtualMachineData
import VirtualMachineDomain

enum Composers {
    static let settingsStore = AppStorageSettingsStore()

    static let fleet = VirtualMachineFleet(
        logger: logger(subsystem: "VirtualMachineFleet"),
        baseVirtualMachine: baseVirtualMachine
    )

    static let editor = VirtualMachineEditor(
        logger: logger(subsystem: "VirtualMachineEditor"),
        virtualMachine: SettingsVirtualMachine(
            tart: Tart(
                homeProvider: SettingsTartHomeProvider(
                    settingsStore: settingsStore
                ),
                shell: ProcessShell()
            ),
            settingsStore: settingsStore
        )
    )

    static let gitHubCredentialsStore = KeychainGitHubCredentialsStore(
        keychain: keychain(
            logger: logger(subsystem: "GitHubCredentialsStore")
        ),
        serviceName: "Tartelet GitHub Account"
    )

    static let virtualMachineSSHCredentialsStore = KeychainVirtualMachineSSHCredentialsStore(
        keychain: keychain(
            logger: logger(subsystem: "KeychainVirtualMachineSSHCredentialsStore")
        ),
        serviceName: "Tartelet Virtual Machine SSH Credentials"
    )

    static func logger(subsystem: String) -> Logger {
        FileLogger(
            fileSystem: DiskFileSystem(),
            dateProvider: FoundationDateProvider(),
            subsystem: subsystem,
            daysOfRetention: 7
        )
    }
}

extension Composers {
    private static var baseVirtualMachine: VirtualMachine {
        let tart = Tart(
            homeProvider: SettingsTartHomeProvider(settingsStore: settingsStore),
            shell: ProcessShell()
        )
        let virtualMachine = SettingsVirtualMachine(
            tart: tart,
            settingsStore: settingsStore
        )
        let connectionHandler = CompositeVirtualMachineSSHConnectionHandler([
            PostBootScriptSSHConnectionHandler(),
            GitHubActionsRunnerSSHConnectionHandler(
                logger: logger(subsystem: "GitHubActionsRunnerSSHConnectionHandler"),
                client: NetworkingGitHubClient(
                    credentialsStore: gitHubCredentialsStore,
                    networkingService: URLSessionNetworkingService(
                        logger: logger(subsystem: "URLSessionNetworkingService")
                    )
                ),
                credentialsStore: gitHubCredentialsStore,
                configuration: SettingsGitHubActionsRunnerConfiguration(
                    settingsStore: settingsStore
                )
            )
        ])

        if shouldUseTartGuestAgent {
            return TartExecConnectingVirtualMachine(
                logger: logger(subsystem: "TartExecConnectingVirtualMachine"),
                virtualMachine: virtualMachine,
                tart: tart,
                connectionHandler: connectionHandler
            )
        }

        return SSHConnectingVirtualMachine(
            logger: logger(subsystem: "SSHConnectingVirtualMachine"),
            virtualMachine: virtualMachine,
            sshClient: VirtualMachineSSHClient(
                logger: logger(subsystem: "VirtualMachineSSHClient"),
                client: CitadelSSHClient(
                    logger: logger(subsystem: "CitadelSSHClient")
                ),
                ipAddressReader: RetryingVirtualMachineIPAddressReader(),
                credentialsStore: virtualMachineSSHCredentialsStore,
                connectionHandler: connectionHandler
            )
        )
    }

    static var shouldUseTartGuestAgent: Bool {
        ProcessInfo.processInfo.environment["TARTELET_USE_TART_EXEC"] == "1"
            || Bundle.main.bundleIdentifier == "com.mzkmnk.TarteletHeadless"
    }

    private static func keychain(logger: Logger) -> Keychain {
        Keychain(logger: logger, accessGroup: keychainAccessGroup)
    }

    private static var keychainAccessGroup: String? {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                  task,
                  "keychain-access-groups" as CFString,
                  nil
              ),
              let accessGroups = value as? [String]
        else {
            return nil
        }
        return accessGroups.first
    }
}

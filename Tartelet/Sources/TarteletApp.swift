import Darwin
import FileSystemData
import LoggingData
import MenuBar
import SettingsDomain
import SettingsUI
import ShellData
import SwiftUI
import VirtualMachineData
import VirtualMachineDomain

@main
struct TarteletApp: App {
    private static let headlessInstanceLock = HeadlessInstanceLock()

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        guard Composers.isHeadlessBuild else {
            return
        }

        switch Self.headlessInstanceLock.acquire() {
        case .acquired:
            break
        case .alreadyLocked:
            Darwin.exit(EXIT_SUCCESS)
        case let .failed(errorNumber):
            let message = "Could not acquire the TarteletHeadless instance lock: "
                + String(cString: strerror(errorNumber))
                + "\n"
            FileHandle.standardError.write(Data(message.utf8))
            Darwin.exit(EXIT_FAILURE)
        }
    }

    var body: some Scene {
        MenuBarItem(
            settingsStore: Composers.settingsStore,
            fleet: Composers.fleet,
            editor: Composers.editor,
            configurationState: ConfigurationState(
                settingsStore: Composers.settingsStore,
                virtualMachineSSHCredentialsStore: Composers.virtualMachineSSHCredentialsStore,
                githubCredentialsStore: Composers.gitHubCredentialsStore,
                requiresSSHCredentials: !Composers.shouldUseTartGuestAgent
            ),
            virtualMachineState: VirtualMachineState(fleet: Composers.fleet, editor: Composers.editor)
        )
        SettingsScene(
            settingsStore: Composers.settingsStore,
            gitHubCredentialsStore: Composers.gitHubCredentialsStore,
            virtualMachineSSHCredentialsStore: Composers.virtualMachineSSHCredentialsStore,
            virtualMachinesSourceNameRepository: TartVirtualMachineSourceNameRepository(
                tart: Tart(
                    homeProvider: SettingsTartHomeProvider(
                        settingsStore: Composers.settingsStore
                    ),
                    shell: ProcessShell()
                )
            ),
            logExporter: FileLogExporter(
                logger: Composers.logger(subsystem: "FileLogExporter"),
                fileSystem: DiskFileSystem()
            ),
            fleet: Composers.fleet,
            editor: Composers.editor
        )
    }
}

private final class HeadlessInstanceLock {
    enum AcquisitionResult {
        case acquired
        case alreadyLocked
        case failed(Int32)
    }

    private var fileDescriptor: Int32 = -1

    func acquire() -> AcquisitionResult {
        guard fileDescriptor == -1 else {
            return .acquired
        }

        let lockURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TarteletHeadless.fleet.lock")
        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR | O_EXLOCK | O_NONBLOCK | O_CLOEXEC,
            0o600
        )
        guard descriptor >= 0 else {
            let errorNumber = errno
            if errorNumber == EWOULDBLOCK || errorNumber == EAGAIN {
                return .alreadyLocked
            }
            return .failed(errorNumber)
        }
        fileDescriptor = descriptor
        return .acquired
    }

    deinit {
        guard fileDescriptor >= 0 else {
            return
        }
        Darwin.close(fileDescriptor)
    }
}

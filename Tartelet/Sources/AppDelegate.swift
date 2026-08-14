import AppKit
import Darwin
import Foundation
import SettingsUI
import VirtualMachineDomain

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settingsStore = Composers.settingsStore
    private let dock = Dock()
    private let logger = Composers.logger(subsystem: "AppDelegate")
    private var terminationSignalSource: DispatchSourceSignal?
    private var terminationTask: Task<Void, Never>?
    private var terminationDeadlineWorkItem: DispatchWorkItem?
    private var terminationCompletion: (() -> Void)?
    private var didCompleteTermination = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        if Composers.isHeadlessBuild {
            beginHandlingTerminationSignal()
        }
        dock.setIconShown(
            isHeadless == false && Composers.settingsStore.applicationUIMode.showInDock
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if isHeadless == false {
            beginObservingAppIconVisibility()
        } else {
            DispatchQueue.main.async {
                self.hideAllWindows()
            }
        }
        if Composers.settingsStore.startVirtualMachinesOnLaunch {
            Composers.fleet.start(numberOfMachines: Composers.settingsStore.numberOfVirtualMachines)
        }

        // If Tartelet is launched as a login item, we can keep the window hidden
        if launchedAsLogInItem == false && isHeadless == false {
            openSettingsWindow()
        }
    }

    // This delegate method let's you perform an action whenever the Finder reactivates an already
    // running application when the app is double-clicked again or clicked on in the dock.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard isHeadless == false else {
            hideAllWindows()
            return false
        }
        openSettingsWindow()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard Composers.isHeadlessBuild else {
            return .terminateNow
        }
        guard terminationTask == nil else {
            return .terminateLater
        }

        beginHeadlessTermination {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard Composers.isHeadlessBuild == false else {
            return
        }
        Composers.editor.stop()
        Composers.fleet.stop()
    }
}

private extension AppDelegate {
    private var isHeadless: Bool {
        Composers.isHeadlessUI
    }

    private func beginObservingAppIconVisibility() {
        withObservationTracking {
            _ = settingsStore.applicationUIMode
        } onChange: {
            DispatchQueue.main.async {
                self.dock.setIconShown(self.settingsStore.applicationUIMode.showInDock)
                self.beginObservingAppIconVisibility()
            }
        }
    }

    private func hideAllWindows() {
        NSApp.windows.forEach { $0.orderOut(nil) }
    }

    private func beginHeadlessTermination(completion: @escaping () -> Void) {
        guard terminationTask == nil else {
            return
        }
        terminationCompletion = completion
        let deadlineWorkItem = DispatchWorkItem { [weak self] in
            self?.logger.error("Timed out waiting for virtual machines to stop before termination.")
            self?.completeTerminationIfNeeded()
        }
        terminationDeadlineWorkItem = deadlineWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: deadlineWorkItem)
        terminationTask = Task { @MainActor in
            Composers.editor.stop()
            Composers.fleet.stopImmediately()
            await Composers.editor.stopImmediatelyAndWait()
            await Composers.fleet.stopImmediatelyAndWait()
            logger.info("Did stop virtual machines before termination.")
            completeTerminationIfNeeded()
        }
    }

    private func completeTerminationIfNeeded() {
        guard didCompleteTermination == false else {
            return
        }
        didCompleteTermination = true
        terminationDeadlineWorkItem?.cancel()
        terminationCompletion?()
    }

    private func beginHandlingTerminationSignal() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else {
                return
            }
            logger.info("Received SIGTERM; stopping virtual machines before termination.")
            beginHeadlessTermination {
                Darwin.exit(EXIT_SUCCESS)
            }
        }
        source.resume()
        terminationSignalSource = source
    }

    private var launchedAsLogInItem: Bool {
        // source: https://stackoverflow.com/a/19890943/4118208
        guard let event = NSAppleEventManager.shared().currentAppleEvent else {
            return false
        }
        return
            event.eventID == kAEOpenApplication &&
            event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    /// Opens Tartelet's Settings window
    ///
    /// To open the Settings/Preferences window programmatically in the past, we'd use:
    ///
    /// ```swift
    /// NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    /// ```
    ///
    /// Unfortunately, Apple removed the ability to do that, so we have to do the slightly
    /// hacky alternative of scanning through the app's menu items and activating the
    /// "Settings…" menu item directly. Not ideal, but it works.
    func openSettingsWindow() {
        // Works around an annoyance where the app always comes to the foreground when
        // being previewed in Xcode's SwiftUI Canvas.
        guard
            ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1"
        else {
            return
        }

        guard
            let menu = NSApplication.shared.menu,
            let sensoriumMenu = menu.items.first,
            let sensoriumMenuSubmenu = sensoriumMenu.submenu,
            let settingsMenuItem = sensoriumMenuSubmenu.items[safe: 2],
            let settingsMenuItemAction = settingsMenuItem.action
        else {
            return
        }

        NSApp.sendAction(
            settingsMenuItemAction,
            to: settingsMenuItem.target,
            from: settingsMenuItem
        )
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension Collection {
    /// Checks first if an index exists in an array, and returns `nil` if it does not exist.
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

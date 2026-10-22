import AppKit
import DownloadsCore
import SwiftUI

@main
struct MacDownloadManagerApp: App {
    @NSApplicationDelegateAdaptor private var lifecycle: AppLifecycle
    @State private var manager: DownloadManager
    @State private var ui = UIState()
    @State private var capture: BrowserCapture
    @State private var panels: Panels
    @State private var queues: QueueManager
    @State private var updater: AppUpdater

    init() {
        // Only one copy may run: a second one would take over the browser connection.
        // (Development runs with their own MDM_SUPPORT_DIR are separate on purpose.)
        if ProcessInfo.processInfo.environment["MDM_SUPPORT_DIR"] == nil, AppLifecycle.handOffToRunningCopy() {
            exit(0)
        }
        // Don't restore last session's windows: a restored "main window closed" state kept
        // the app windowless at launch, and restored progress windows came back empty.
        // Window sizes and positions are still remembered (NSWindow Frame defaults).
        UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])
        // Also show a Dock icon and menu bar when launched as a bare executable (swift run).
        NSApplication.shared.setActivationPolicy(.regular)
        // MDM_DEV_STORE keeps development runs (see DevHooks) out of the real download list.
        let store = ProcessInfo.processInfo.environment["MDM_DEV_STORE"].map { URL(fileURLWithPath: $0) }
            ?? DownloadManager.defaultStoreURL
        let manager = DownloadManager(storeURL: store)
        _manager = State(initialValue: manager)
        let queues = QueueManager(manager: manager, storeURL: QueueManager.storeURL(nextTo: store))
        _queues = State(initialValue: queues)
        // Listen for the browser from launch, whether or not a window is open.
        let capture = BrowserCapture(settings: manager.settings)
        do {
            try capture.start()
        } catch {
            print("Browser capture unavailable: \(error)")
        }
        _capture = State(initialValue: capture)
        let panels = Panels(manager: manager, capture: capture, queues: queues)
        _panels = State(initialValue: panels)
        queues.didFinishQueue = { [panels] queue in QueueFinish.perform(queue, panels: panels) }

        // Updates come from the project's GitHub releases; checked shortly after launch and
        // then every few hours (at most once a day, see AppUpdater.checkIfDue).
        let env = ProcessInfo.processInfo.environment
        let updater = AppUpdater(settings: manager.settings,
                                 api: env["MDM_DEV_UPDATE_API"].flatMap(URL.init(string:)) ?? AppUpdater.defaultAPI)
        _updater = State(initialValue: updater)
        updater.didFindUpdate = { [panels, manager] release in
            panels.showUpdate(updater)
            if env["MDM_DEV_AUTO_INSTALL_UPDATE"] != nil {
                Task { await UpdateFlow.install(release, updater: updater, manager: manager, onManualInstall: {}) }
            }
        }
        if env["MDM_DEV_UPDATE_API"] != nil { Task { await updater.check(userInitiated: true) } }
        manager.resumeAfterUpdate()
        if ProcessInfo.processInfo.environment["MDM_SUPPORT_DIR"] == nil {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                while true {
                    await updater.checkIfDue()
                    try? await Task.sleep(for: .seconds(6 * 3600))
                }
            }
        }
        queues.startQueuesOnLaunch()
        // The schedules are checked every 15 seconds while the app runs.
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            MainActor.assumeIsolated { queues.tick() }
        }
    }

    var body: some Scene {
        Window("Mac Download Manager", id: "main") {
            MainWindow(panels: panels)
                .environment(manager)
                .environment(ui)
                .environment(capture)
                .environment(queues)
                .frame(minWidth: 820, minHeight: 420)
        }
        .commands {
            AppCommands(manager: manager, ui: ui, queues: queues)
            CommandGroup(replacing: .appInfo) {
                AboutMenuButton()
                Button("Check for Updates…") { checkForUpdates() }
            }
        }

        Window("Scheduler", id: "scheduler") {
            SchedulerWindow()
                .environment(manager)
                .environment(queues)
        }
        .windowResizability(.contentSize)

        // Keeps the app (and its downloads) running when the main window is closed.
        MenuBarExtra {
            MenuBarMenu(panels: panels, checkForUpdates: checkForUpdates).environment(manager)
        } label: {
            MenuBarLabel().environment(manager)
        }

        Window("About Mac Download Manager", id: "about") {
            AboutWindow()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Settings {
            OptionsView().environment(manager).environment(capture).environment(updater)
        }
    }
}

extension MacDownloadManagerApp {
    /// "Check for Updates…": shows the Software Update window with the result.
    func checkForUpdates() {
        panels.showUpdate(updater)
        Task { await updater.check(userInitiated: true) }
    }
}

/// UI state shared between the main window and the menu commands.
@MainActor @Observable
final class UIState {
    var showingAddURL = false
    var showCategories = true
}

struct AppCommands: Commands {
    let manager: DownloadManager
    let ui: UIState
    let queues: QueueManager
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add New Download…") { ui.showingAddURL = true }
                .keyboardShortcut("n")
        }
        CommandMenu("Downloads") {
            Button("Pause All") { manager.pauseAll() }
            Button("Delete All Completed") { manager.removeCompleted() }
            Divider()
            Button("Scheduler…") { openWindow(id: "scheduler") }
                .keyboardShortcut("s", modifiers: [.command, .option])
            Menu("Start Queue") {
                ForEach(queues.queues) { queue in
                    Button(queue.name) { queues.start(queue.id) }.disabled(queues.running.contains(queue.id))
                }
            }
            Menu("Stop Queue") {
                ForEach(queues.queues) { queue in
                    Button(queue.name) { queues.stop(queue.id) }.disabled(!queues.running.contains(queue.id))
                }
            }
            Divider()
            Toggle("Speed Limiter", isOn: Binding(
                get: { manager.settings.speedLimitEnabled },
                set: { manager.settings.speedLimitEnabled = $0; manager.applySpeedLimit() }))
                .keyboardShortcut("l", modifiers: [.command, .option])
        }
        CommandGroup(after: .sidebar) {
            Toggle("Show Categories", isOn: Binding(get: { ui.showCategories }, set: { ui.showCategories = $0 }))
        }
    }
}

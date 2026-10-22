import AppKit
import DownloadsCore
import SwiftUI

/// The dialogs that pop up while the user is in the browser (Download File Info,
/// Download progress, Download complete). They are non-activating panels: like Spotlight,
/// they appear over whatever is on screen, including a full-screen browser, without
/// switching Spaces or activating the app. Regular SwiftUI windows can't do that.
@MainActor @Observable
final class Panels {
    @ObservationIgnored private let manager: DownloadManager
    @ObservationIgnored private let capture: BrowserCapture
    @ObservationIgnored private let queues: QueueManager
    private var open: [String: NSPanel] = [:]

    func isProgressShown(_ item: DownloadItem) -> Bool { open["progress-\(item.id)"] != nil }

    /// Running downloads whose progress window is hidden ("minimized" in IDM's words).
    var minimized: [DownloadItem] {
        manager.items.filter { $0.status == .downloading && !isProgressShown($0) }
    }

    /// "Restore all download windows".
    func restoreAll() {
        minimized.forEach(showProgress)
    }

    init(manager: DownloadManager, capture: BrowserCapture, queues: QueueManager) {
        self.manager = manager
        self.capture = capture
        self.queues = queues
    }

    /// IDM's "Shut down" dialog: a countdown before the queue's "when done" action, with Cancel.
    func showFinishCountdown(_ queue: DownloadQueue, action: @escaping () -> Void) {
        show(key: "finish-\(queue.id)", title: "Queue finished", floating: true) { close in
            FinishCountdown(queue: queue, perform: { close(); action() }, cancel: close)
        }
    }

    func showCapture(_ pending: PendingCapture) {
        show(key: "capture-\(pending.id)", title: "Download File Info", floating: true) { [capture] close in
            FileInfoStep(url: pending.url, headers: pending.request.headers,
                         suggestedName: pending.suggestedName, media: pending.mediaSource,
                         knownSize: pending.media?.option?.size, close: close)
                .onDisappear { capture.finish(pending) }
        }
    }

    func showProgress(_ item: DownloadItem) {
        show(key: "progress-\(item.id)", title: item.fileName, floating: false) { _ in
            DownloadProgressWindow(item: item)
        }
    }

    /// IDM's "File Properties", one window per download.
    func showProperties(_ item: DownloadItem) {
        show(key: "properties-\(item.id)", title: "File Properties", floating: false) { _ in
            FilePropertiesWindow(item: item)
        }
    }

    func showComplete(_ item: DownloadItem) {
        open["progress-\(item.id)"]?.close()
        show(key: "complete-\(item.id)", title: "Download complete", floating: true) { _ in
            DownloadCompleteWindow(item: item)
        }
    }

    private func show<Content: View>(key: String, title: String, floating: Bool,
                                     @ViewBuilder content: (_ close: @escaping () -> Void) -> Content) {
        if let existing = open[key] {
            existing.orderFrontRegardless()
            existing.makeKey()
            return
        }
        let panel = DialogPanel(title: title, floating: floating)
        let close: () -> Void = { [weak panel] in panel?.close() }
        let hosting = FirstClickHostingView(rootView: AnyView(content(close)
            .environment(manager)
            .environment(capture)
            .environment(queues)
            .environment(\.closeWindow, CloseWindowAction(close))))
        // The panel follows the SwiftUI view's size (e.g. "Hide details").
        hosting.sizingOptions = [.minSize, .intrinsicContentSize, .maxSize]
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        panel.onClose = { [weak self] in self?.open[key] = nil }
        open[key] = panel
        panel.presentOnScreenWithMouse()
    }
}

/// The browser stays the active app while a panel is up, so the panel is not key yet;
/// accept the first click as a real click instead of only focusing the panel.
private final class FirstClickHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class DialogPanel: NSPanel {
    var onClose: (() -> Void)?

    init(title: String, floating: Bool) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                   styleMask: [.titled, .closable, .miniaturizable, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        self.title = title
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        level = floating ? .floating : .normal
        // On every Space, including a full-screen app's, so it shows wherever the user is.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    // Text fields (Description, speed limit) need keyboard focus.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func close() {
        super.close()
        onClose?()
        onClose = nil
    }

    /// Centers on the screen with the mouse and shows the panel without activating the app.
    func presentOnScreenWithMouse() {
        layoutIfNeeded()
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main {
            let area = screen.visibleFrame
            let size = frame.size
            setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2 + area.height / 8))
        }
        orderFrontRegardless()
        makeKey()
    }
}

/// Closes the window or panel a view is shown in.
struct CloseWindowAction {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    func callAsFunction() { action() }
}

extension EnvironmentValues {
    @Entry var closeWindow = CloseWindowAction {}
}

extension View {
    /// Keeps the hosting window's title in sync (panels don't use navigationTitle).
    func windowTitle(_ title: String) -> some View {
        background(WindowTitleSetter(title: title))
    }
}

private struct WindowTitleSetter: NSViewRepresentable {
    let title: String
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { view.window?.title = title }
    }
}

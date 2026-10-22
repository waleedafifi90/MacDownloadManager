import AppKit
import DownloadsCore
import SwiftUI

/// "Software Update": what the updater found, the release notes, and installing it.
struct SoftwareUpdateWindow: View {
    @Environment(DownloadManager.self) private var manager
    @Environment(\.closeWindow) private var closeWindow
    let updater: AppUpdater

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 10) {
                content
            }
        }
        .padding(20)
        .frame(width: 520)
        .windowTitle("Software Update")
    }

    @ViewBuilder private var content: some View {
        switch updater.state {
        case .idle, .checking:
            Text("Checking for updates…").font(.headline)
            ProgressView().controlSize(.small)
        case .upToDate:
            Text("Mac Download Manager is up to date").font(.headline)
            Text("Version \(updater.currentVersion?.description ?? "?") is the newest version available.")
                .foregroundStyle(.secondary)
            buttons { Button("OK") { closeWindow() }.keyboardShortcut(.defaultAction) }
        case .failed(let message):
            Text("Couldn't update").font(.headline)
            Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            buttons {
                Button("Close") { closeWindow() }
                Button("Try Again") { Task { await updater.check(userInitiated: true) } }
                    .keyboardShortcut(.defaultAction)
            }
        case .available(let release):
            Text("A new version of Mac Download Manager is available!").font(.headline)
            Text("Version \(release.version.description) is available. You have \(updater.currentVersion?.description ?? "?").")
                .foregroundStyle(.secondary)
            notes(release)
            if !AppUpdater.canReplace(Bundle.main.bundleURL) {
                Text("This copy can't replace itself where it is. The update will open so you can drag it to Applications.")
                    .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            buttons {
                Button("Skip This Version") { updater.skip(release); closeWindow() }
                Spacer()
                Button("Remind Me Later") { updater.dismiss(); closeWindow() }
                Button("Install Update") { install(release) }.keyboardShortcut(.defaultAction)
            }
        case .downloading(let fraction):
            Text("Downloading the update…").font(.headline)
            ProgressView(value: fraction)
            Text("Running downloads will be paused and continue after the update.")
                .font(.callout).foregroundStyle(.secondary)
        case .installing:
            Text("Installing the update…").font(.headline)
            ProgressView().progressViewStyle(.linear)
        }
    }

    private func buttons<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack { content() }.padding(.top, 4)
    }

    private func notes(_ release: UpdateRelease) -> some View {
        ScrollView {
            Text(Self.render(release.notes))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(10)
        }
        .frame(height: 200)
        .background(.background, in: .rect(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
    }

    /// Release notes are Markdown: headings in bold, list items as bullets, inline
    /// formatting (bold, links, code) kept.
    static func render(_ markdown: String) -> AttributedString {
        var result = AttributedString()
        for (index, rawLine) in markdown.components(separatedBy: .newlines).enumerated() {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            var heading = false
            if line.hasPrefix("#") {
                line = String(line.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
                heading = true
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                line = "•  " + line.dropFirst(2)
            }
            var text = (try? AttributedString(markdown: line)) ?? AttributedString(line)
            if heading { text.font = .headline }
            if index > 0 { result.append(AttributedString("\n")) }
            result.append(text)
        }
        return result
    }

    private func install(_ release: UpdateRelease) {
        Task { await UpdateFlow.install(release, updater: updater, manager: manager, onManualInstall: closeWindow.callAsFunction) }
    }
}

/// Installing an update: download and verify it, pause downloads, swap the app, relaunch.
@MainActor
enum UpdateFlow {
    static func install(_ release: UpdateRelease, updater: AppUpdater, manager: DownloadManager,
                        onManualInstall: () -> Void) async {
        let app = Bundle.main.bundleURL
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mdm-update")
        do {
            let dmg = try await updater.download(release, to: folder)
            guard AppUpdater.canReplace(app) else {
                // Let the user drag the verified update into Applications.
                NSWorkspace.shared.open(dmg)
                updater.dismiss()
                onManualInstall()
                return
            }
            manager.pauseAllForUpdate()
            // Give paused downloads a moment to save where they stopped.
            try await Task.sleep(for: .seconds(1))
            try await updater.install(dmg: dmg, replacing: app, expecting: release.version)
            AppUpdater.relaunchAfterQuit(app)
            NSApp.terminate(nil)
        } catch {
            updater.fail(error)
        }
    }
}

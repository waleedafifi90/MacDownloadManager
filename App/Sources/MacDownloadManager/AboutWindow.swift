import AppKit
import DownloadsCore
import SwiftUI

/// Who made the app and where to follow the project.
enum Developer {
    static let name = "Waleed A. Afifi"
    static let email = "waleedafifi.blog@gmail.com"
    static let github = URL(string: "https://github.com/waleedafifi90")!
    static let project = URL(string: "https://github.com/waleedafifi90/MacDownloadManager")!
    static let issues = URL(string: "https://github.com/waleedafifi90/MacDownloadManager/issues")!
}

/// "About Mac Download Manager".
struct AboutWindow: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        return (info?["CFBundleShortVersionString"] as? String) ?? "?"
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 112, height: 112)
            VStack(spacing: 4) {
                Text("Mac Download Manager").font(.title2.bold())
                Text("Version \(version)").foregroundStyle(.secondary)
            }
            Text("A fast download manager for macOS, with resumable multi-connection downloads, browser capture and video downloads.")
                .multilineTextAlignment(.center)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            VStack(spacing: 8) {
                Text("Developed by").font(.caption).foregroundStyle(.secondary)
                Text(Developer.name).font(.headline)
                HStack(spacing: 18) {
                    Link(destination: URL(string: "mailto:\(Developer.email)")!) {
                        Label(Developer.email, systemImage: "envelope")
                    }
                    Link(destination: Developer.github) {
                        Label("Follow on GitHub", systemImage: "person.crop.circle.badge.plus")
                    }
                }
                .font(.callout)
            }

            HStack(spacing: 18) {
                Link("Project on GitHub", destination: Developer.project)
                Link("Report an Issue", destination: Developer.issues)
            }
            .font(.callout)

            Text("© 2026 \(Developer.name) · MIT License")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(width: 440)
    }
}

/// Opens the About window from a menu, also while the app has no Dock icon.
struct AboutMenuButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("About Mac Download Manager") {
            NSApp.setActivationPolicy(.regular)
            openWindow(id: "about")
            NSApp.activate()
        }
    }
}

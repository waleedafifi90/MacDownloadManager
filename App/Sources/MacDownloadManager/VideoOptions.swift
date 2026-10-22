import DownloadsCore
import SwiftUI

/// Options ▸ Video: the tools behind "Download this video".
struct VideoOptions: View {
    @Environment(DownloadManager.self) private var manager
    @State private var ytDlpVersion: String?
    @State private var working = false
    @State private var message: String?

    private var tools: VideoTools { manager.videoTools }

    var body: some View {
        Form {
            Section {
                LabeledContent("yt-dlp") {
                    if let path = tools.ytDlp {
                        VStack(alignment: .trailing) {
                            Text(ytDlpVersion ?? "…")
                            Text(path.path).font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Not installed").foregroundStyle(.orange)
                    }
                }
                HStack {
                    Button(tools.ytDlp == nil ? "Install yt-dlp" : "Update yt-dlp", action: install)
                        .disabled(working)
                    if working { ProgressView().controlSize(.small) }
                }
                Text("Finds the videos and their qualities on YouTube and many other sites. Downloaded from github.com/yt-dlp/yt-dlp and checked against its published SHA-256.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("ffmpeg") {
                    if let path = tools.ffmpeg {
                        Text(path.path).foregroundStyle(.secondary)
                    } else {
                        Text("Not installed").foregroundStyle(.orange)
                    }
                }
                Text(tools.ffmpeg == nil
                     ? "Needed to join separate video and audio streams (most qualities above 360p on YouTube). Install it with Homebrew: brew install ffmpeg"
                     : "Joins separate video and audio streams without re-encoding.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let message { Text(message).font(.callout) }
        }
        .formStyle(.grouped)
        .task { await readVersion() }
    }

    private func readVersion() async {
        guard let ytDlp = tools.ytDlp else { ytDlpVersion = nil; return }
        let process = Process()
        process.executableURL = ytDlp
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        let output = await Task.detached { pipe.fileHandleForReading.readDataToEndOfFile() }.value
        ytDlpVersion = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func install() {
        working = true
        message = nil
        Task {
            do {
                let tag = try await tools.installYtDlp()
                message = "Installed yt-dlp \(tag)."
            } catch {
                message = "Could not install yt-dlp: \(error)"
            }
            working = false
            await readVersion()
        }
    }
}

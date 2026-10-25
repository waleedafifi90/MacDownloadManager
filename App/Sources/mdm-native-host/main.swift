import AppKit
import CaptureProtocol
import Foundation

// Native Messaging host. Chrome starts it when the extension connects and talks to it
// over stdin/stdout; it answers "hello" with the capture rules and relays "capture"
// requests to the app, starting the app first if it is not running.

let stdin = FileHandle.standardInput
let stdout = FileHandle.standardOutput

func reply(_ message: CaptureMessage) {
    guard let json = try? JSONEncoder().encode(message), json.count <= NativeMessaging.maxOutgoing else { return }
    stdout.write(NativeMessaging.frame(json))
}

/// The app bundle this host ships in: <App>.app/Contents/MacOS/mdm-native-host.
func appBundle() -> URL? {
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let bundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return bundle.pathExtension == "app" ? bundle : nil
}

/// Whether a copy of the app is running (it may still be starting and not listening yet).
func appIsRunning() -> Bool {
    guard let bundle = appBundle(), let id = Bundle(url: bundle)?.bundleIdentifier else { return false }
    return !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
}

/// Sends a message to the app. Listing a video's qualities runs yt-dlp, which can take a
/// while. If the app isn't running it is started in the background (menu bar only, no
/// window) unless `startApp` is false, and we wait up to 15s for it. A running app that is
/// slow to answer is never "opened" again: for macOS that is the user reopening the app,
/// and it brings up the main window in front of whatever the user is doing.
func forward(_ message: CaptureMessage, startApp: Bool = true) -> CaptureMessage {
    let timeout: TimeInterval = message.type == "listFormats" ? 120 : 15
    do {
        return try UnixSocketClient.exchange(message, timeout: timeout)
    } catch CaptureError.connectFailed {
        // Nothing is listening: the app isn't running, or is still starting.
    } catch {
        return .result(accepted: false, error: "Mac Download Manager didn't answer in time")
    }
    guard startApp else { return .result(accepted: false, error: CaptureMessage.appNotRunning) }
    if !appIsRunning() {
        guard let bundle = appBundle() else { return .result(accepted: false, error: CaptureMessage.appNotRunning) }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", "-j", bundle.path, "--args", "--background"]
        try? open.run()
        open.waitUntilExit()
    }

    let deadline = Date().addingTimeInterval(15)
    while Date() < deadline {
        Thread.sleep(forTimeInterval: 0.3)
        if let answer = try? UnixSocketClient.exchange(message, timeout: timeout) { return answer }
    }
    return .result(accepted: false, error: "App did not start")
}

/// The version of the extension the app keeps for "Load unpacked"; when it is newer than
/// the running one, the extension reloads itself from disk.
func extensionFolderVersion() -> String? {
    let manifest = CaptureProtocol.supportDirectory.appendingPathComponent("ChromeExtension/manifest.json")
    guard let data = try? Data(contentsOf: manifest),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return json["version"] as? String
}

while let body = try NativeMessaging.read(from: stdin) {
    guard let message = try? JSONDecoder().decode(CaptureMessage.self, from: body) else {
        reply(.result(accepted: false, error: "Malformed message"))
        continue
    }
    switch message.type {
    case "hello":
        // Tell the app the extension is there (for its setup window), without starting it.
        _ = try? UnixSocketClient.exchange(CaptureMessage(type: "hello", extensionVersion: message.extensionVersion),
                                           timeout: 1)
        reply(CaptureMessage(type: "rules", rules: CaptureRules.load(), extensionVersion: extensionFolderVersion()))
    case "capture":
        if let capture = message.capture, capture.httpURL != nil {
            reply(forward(CaptureMessage(type: "capture", capture: capture)))
        } else {
            reply(.result(accepted: false, error: "Not an http(s) link"))
        }
    case "listFormats", "downloadMedia":
        if let media = message.media, CaptureRequest(url: media.pageUrl).httpURL != nil {
            reply(forward(CaptureMessage(type: message.type, media: media), startApp: message.startApp ?? true))
        } else {
            reply(.result(accepted: false, error: "Not an http(s) page"))
        }
    default:
        reply(.result(accepted: false, error: "Unknown message type"))
    }
}

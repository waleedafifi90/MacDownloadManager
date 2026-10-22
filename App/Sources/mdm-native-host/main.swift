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

/// Sends a message to the app, starting it and waiting up to 15s if needed. Listing a
/// video's qualities runs yt-dlp, which can take a while.
func forward(_ message: CaptureMessage) -> CaptureMessage {
    let timeout: TimeInterval = message.type == "listFormats" ? 120 : 15
    if let answer = try? UnixSocketClient.exchange(message, timeout: timeout) { return answer }

    guard let bundle = appBundle() else { return .result(accepted: false, error: "App not running") }
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = [bundle.path]
    try? open.run()
    open.waitUntilExit()

    let deadline = Date().addingTimeInterval(15)
    while Date() < deadline {
        Thread.sleep(forTimeInterval: 0.3)
        if let answer = try? UnixSocketClient.exchange(message, timeout: timeout) { return answer }
    }
    return .result(accepted: false, error: "App did not start")
}

while let body = try NativeMessaging.read(from: stdin) {
    guard let message = try? JSONDecoder().decode(CaptureMessage.self, from: body) else {
        reply(.result(accepted: false, error: "Malformed message"))
        continue
    }
    switch message.type {
    case "hello":
        reply(CaptureMessage(type: "rules", rules: CaptureRules.load()))
    case "capture":
        if let capture = message.capture, capture.httpURL != nil {
            reply(forward(CaptureMessage(type: "capture", capture: capture)))
        } else {
            reply(.result(accepted: false, error: "Not an http(s) link"))
        }
    case "listFormats", "downloadMedia":
        if let media = message.media, CaptureRequest(url: media.pageUrl).httpURL != nil {
            reply(forward(CaptureMessage(type: message.type, media: media)))
        } else {
            reply(.result(accepted: false, error: "Not an http(s) page"))
        }
    default:
        reply(.result(accepted: false, error: "Unknown message type"))
    }
}

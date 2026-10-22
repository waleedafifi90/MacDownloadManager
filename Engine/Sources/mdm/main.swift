import DownloadEngine
import Foundation

// Usage: mdm <url> [-o output] [-n connections]
var args = Array(CommandLine.arguments.dropFirst())
guard let urlString = args.first, let url = URL(string: urlString) else {
    print("Usage: mdm <url> [-o output] [-n connections]")
    exit(1)
}
args.removeFirst()

var options = DownloadOptions()
var output = URL(fileURLWithPath: url.lastPathComponent.isEmpty ? "download" : url.lastPathComponent)
while let flag = args.first {
    args.removeFirst()
    guard let value = args.first else { break }
    args.removeFirst()
    switch flag {
    case "-o": output = URL(fileURLWithPath: value)
    case "-n": options.maxConnections = Int(value) ?? options.maxConnections
    default: print("Unknown option \(flag)"); exit(1)
    }
}

let started = Date()
let download = SegmentedDownload(url: url, destination: output, options: options)
do {
    let saved = try await download.start { p in
        let mb = Double(p.downloaded) / 1_048_576
        let speed = mb / max(Date().timeIntervalSince(started), 0.001)
        let percent = p.total.map { String(format: "%5.1f%%", Double(p.downloaded) * 100 / Double($0)) } ?? "  ?  "
        print(String(format: "\r%@  %.1f MB  %.2f MB/s  connections: %d   ", percent, mb, speed, p.activeConnections),
              terminator: "")
        fflush(stdout)
    }
    print("\nSaved to \(saved.path)")
} catch {
    print("\nDownload failed: \(error)")
    exit(1)
}

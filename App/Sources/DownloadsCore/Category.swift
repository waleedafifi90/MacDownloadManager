import Foundation

/// A file category, chosen by extension. Defaults follow IDM's built-in list
/// (specs/08-ui.md §2), plus common macOS formats.
public struct DownloadCategory: Hashable, Sendable, Identifiable {
    public let name: String
    public let symbol: String
    public let extensions: [String]
    public var id: String { name }

    public static let compressed = DownloadCategory(
        name: "Compressed", symbol: "doc.zipper",
        extensions: ["zip", "rar", "r0*", "r1*", "arj", "gz", "sit", "sitx", "sea", "ace", "bz2", "7z", "tar", "xz", "tgz"])
    public static let documents = DownloadCategory(
        name: "Documents", symbol: "doc.text",
        extensions: ["doc", "pdf", "ppt", "pps", "docx", "pptx", "xls", "xlsx", "pages", "key", "numbers", "epub"])
    public static let music = DownloadCategory(
        name: "Music", symbol: "music.note",
        extensions: ["mp3", "wav", "wma", "mpa", "ram", "ra", "aac", "aif", "m4a", "tsa", "flac", "aiff"])
    public static let programs = DownloadCategory(
        name: "Programs", symbol: "app.badge",
        extensions: ["exe", "msi", "dmg", "pkg", "app", "apk"])
    public static let video = DownloadCategory(
        name: "Video", symbol: "film",
        extensions: ["avi", "mpg", "mpe", "mpeg", "asf", "wmv", "mov", "qt", "rm", "mp4", "flv", "m4v", "webm",
                     "ogv", "ogg", "mkv", "ts", "tsv"])
    public static let general = DownloadCategory(name: "General", symbol: "doc", extensions: [])

    public static let all: [DownloadCategory] = [.compressed, .documents, .music, .programs, .video, .general]

    public static func named(_ name: String) -> DownloadCategory {
        all.first { $0.name == name } ?? .general
    }

    /// The category whose extension list matches the file name; `r0*`-style patterns
    /// match split archives such as `.r00`, `.r01`.
    public static func forFile(named fileName: String) -> DownloadCategory {
        let ext = (fileName as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return .general }
        return all.first { category in
            category.extensions.contains { pattern in
                pattern.hasSuffix("*") ? ext.hasPrefix(pattern.dropLast()) : ext == pattern
            }
        } ?? .general
    }
}

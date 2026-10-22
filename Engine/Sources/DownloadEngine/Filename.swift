import Foundation

enum Filename {
    /// The file name a server suggests: Content-Disposition's `filename*` (RFC 6266/5987)
    /// or `filename`, otherwise the last path component of the final URL.
    static func suggested(by response: HTTPURLResponse) -> String? {
        if let header = response.value(forHTTPHeaderField: "Content-Disposition"),
            let name = fromContentDisposition(header)
        {
            return sanitized(name)
        }
        guard let last = response.url?.lastPathComponent, !last.isEmpty, last != "/" else { return nil }
        return sanitized(last)
    }

    static func fromContentDisposition(_ header: String) -> String? {
        var plain: String?
        for part in header.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2 else { continue }
            switch pair[0].lowercased() {
            case "filename*":
                // charset'language'percent-encoded-value
                let pieces = pair[1].split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                if pieces.count == 3, let decoded = String(pieces[2]).removingPercentEncoding { return decoded }
            case "filename":
                plain = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            default:
                break
            }
        }
        return plain
    }

    /// Keeps only the last path component and drops characters macOS cannot store.
    static func sanitized(_ name: String) -> String? {
        let last = name.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? ""
        let cleaned = last.replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? nil : cleaned
    }
}

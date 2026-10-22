import CryptoKit
import Foundation

/// A version like "0.1.2" (a leading "v", as in tags, is ignored).
public struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    public let parts: [Int]

    public init?(_ text: String) {
        let trimmed = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let parts = trimmed.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        self.parts = parts.compactMap { $0 }
    }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0
            let y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    public static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    /// The running app's version (CFBundleShortVersionString).
    public static var current: AppVersion? {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(AppVersion.init)
    }
}

/// A published release with everything needed to install it safely.
public struct UpdateRelease: Equatable, Sendable {
    public var version: AppVersion
    public var notes: String
    public var pageURL: URL
    public var dmgURL: URL
    /// The SHA-256 GitHub computed for the DMG (hex).
    public var dmgSHA256: String
    public var dmgSize: Int64
    /// The detached Ed25519 signature (`<dmg>.sig`).
    public var signatureURL: URL

    public static func == (a: UpdateRelease, b: UpdateRelease) -> Bool {
        a.version == b.version && a.dmgURL == b.dmgURL && a.dmgSHA256 == b.dmgSHA256
    }

    /// Reads GitHub's "latest release" JSON. A release without a DMG, its SHA-256 or its
    /// signature is not offered: it can't be verified.
    public static func parse(_ json: Data) throws -> UpdateRelease {
        struct Release: Decodable {
            struct Asset: Decodable {
                let name: String
                let browser_download_url: URL
                let digest: String?
                let size: Int64
            }
            let tag_name: String
            let body: String?
            let html_url: URL
            let draft: Bool?
            let prerelease: Bool?
            let assets: [Asset]
        }
        let release = try JSONDecoder().decode(Release.self, from: json)
        guard release.draft != true, release.prerelease != true else { throw UpdateError.noUsableRelease }
        guard let version = AppVersion(release.tag_name) else { throw UpdateError.badVersion(release.tag_name) }
        guard let dmg = release.assets.first(where: { $0.name.hasSuffix(".dmg") }),
            let digest = dmg.digest, digest.hasPrefix("sha256:"),
            let signature = release.assets.first(where: { $0.name == dmg.name + ".sig" })
        else { throw UpdateError.noUsableRelease }
        return UpdateRelease(version: version, notes: release.body ?? "", pageURL: release.html_url,
                             dmgURL: dmg.browser_download_url, dmgSHA256: String(digest.dropFirst("sha256:".count)).lowercased(),
                             dmgSize: dmg.size, signatureURL: signature.browser_download_url)
    }
}

public enum UpdateError: Error, Equatable {
    case noUsableRelease
    case badVersion(String)
    case checksumMismatch
    case badSignature
    case notInstallable(String)
    case installFailed(String)
}

/// Release DMGs are signed with an Ed25519 key that only the maintainer has (kept in the
/// Keychain by `mdm-release`); the app accepts an update only if the signature over the
/// DMG's SHA-256 checks out with this public key. A compromised GitHub account alone
/// can't ship an update.
public enum UpdateSignature {
    public static let publicKey = "htgfFkI5lhjy4tE7Yp8HUCj3acj+PuMP9r8w1EnyFrs="

    public static func sha256Hex(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The bytes that are signed: the DMG's SHA-256 as lowercase hex.
    static func message(forSHA256 hex: String) -> Data { Data(hex.lowercased().utf8) }

    public static func sign(sha256 hex: String, with privateKey: Curve25519.Signing.PrivateKey) throws -> String {
        try privateKey.signature(for: message(forSHA256: hex)).base64EncodedString()
    }

    public static func isValid(_ signatureBase64: String, sha256 hex: String, publicKeyBase64: String = publicKey) -> Bool {
        guard let keyData = Data(base64Encoded: publicKeyBase64),
            let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
            let signature = Data(base64Encoded: signatureBase64.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return false }
        return key.isValidSignature(signature, for: message(forSHA256: hex))
    }
}

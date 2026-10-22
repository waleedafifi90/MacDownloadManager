import CryptoKit
import DownloadsCore
import Foundation

// Release signing for app updates. The Ed25519 private key lives in the login Keychain
// (never in the repository); the app ships with the public key (UpdateSignature.publicKey).
//
//   mdm-release keygen              create the key (once) and print the public key
//   mdm-release public-key          print the public key
//   mdm-release export-private-key  print the private key, to back it up somewhere safe
//   mdm-release sign <file.dmg>     write <file.dmg>.sig

let service = "MacDownloadManager release signing"
let account = "ed25519"

func security(_ arguments: [String]) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    try? process.run()
    process.waitUntilExit()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return (process.terminationStatus, output.trimmingCharacters(in: .whitespacesAndNewlines))
}

func storedKey() -> Curve25519.Signing.PrivateKey? {
    let result = security(["find-generic-password", "-s", service, "-a", account, "-w"])
    guard result.status == 0, let data = Data(base64Encoded: result.output) else { return nil }
    return try? Curve25519.Signing.PrivateKey(rawRepresentation: data)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "keygen":
    if storedKey() != nil {
        fail("A signing key already exists in the Keychain. Replacing it would stop installed copies from accepting updates.")
    }
    let key = Curve25519.Signing.PrivateKey()
    let stored = security(["add-generic-password", "-s", service, "-a", account,
                           "-w", key.rawRepresentation.base64EncodedString(), "-T", "/usr/bin/security"])
    guard stored.status == 0 else { fail("Could not save the key in the Keychain.") }
    print(key.publicKey.rawRepresentation.base64EncodedString())
    FileHandle.standardError.write(Data("""
        Saved the private key in the login Keychain (“\(service)”).
        Put the public key above in UpdateSignature.publicKey, and back up the private key
        (mdm-release export-private-key) somewhere safe: without it no update can be shipped.

        """.utf8))
case "public-key":
    guard let key = storedKey() else { fail("No signing key; run: mdm-release keygen") }
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "export-private-key":
    guard let key = storedKey() else { fail("No signing key; run: mdm-release keygen") }
    print(key.rawRepresentation.base64EncodedString())
case "sign":
    guard arguments.count == 2 else { fail("usage: mdm-release sign <file.dmg>") }
    guard let key = storedKey() else { fail("No signing key; run: mdm-release keygen") }
    let file = URL(fileURLWithPath: arguments[1])
    let sha = try UpdateSignature.sha256Hex(of: file)
    let signature = try UpdateSignature.sign(sha256: sha, with: key)
    guard UpdateSignature.isValid(signature, sha256: sha, publicKeyBase64: key.publicKey.rawRepresentation.base64EncodedString()) else {
        fail("Signing failed")
    }
    if UpdateSignature.publicKey != key.publicKey.rawRepresentation.base64EncodedString() {
        fail("This key doesn't match UpdateSignature.publicKey in the app; installed copies would reject the update.")
    }
    try Data((signature + "\n").utf8).write(to: file.appendingPathExtension("sig"))
    print("Signed \(file.lastPathComponent) (SHA-256 \(sha))")
default:
    fail("usage: mdm-release keygen | public-key | export-private-key | sign <file.dmg>")
}

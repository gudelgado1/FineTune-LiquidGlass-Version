#!/usr/bin/env swift
import Foundation
import CryptoKit

// Verifies the exact release archive against the public key embedded in its app.
// Usage: swift scripts/verify-update-signature.swift FineTune.zip FineTune.app/Contents/Info.plist BASE64_SIGNATURE
let arguments = CommandLine.arguments
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}
guard arguments.count == 4 else {
    fail("Usage: verify-update-signature.swift ARCHIVE INFO_PLIST BASE64_SIGNATURE")
}
do {
    let plistData = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
    guard let info = try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
          let encodedKey = info["SUPublicEDKey"] as? String,
          let keyData = Data(base64Encoded: encodedKey), keyData.count == 32,
          let signature = Data(base64Encoded: arguments[3]), signature.count == 64 else {
        fail("Invalid public key or signature encoding")
    }
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
    let archive = try Data(contentsOf: URL(fileURLWithPath: arguments[1]), options: .mappedIfSafe)
    guard key.isValidSignature(signature, for: archive) else { fail("Invalid archive signature") }
    print("Archive signature verified against the app’s public key")
} catch {
    fail("Could not verify archive: " + error.localizedDescription)
}

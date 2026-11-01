# Releasing FineTune (Liquid Glass Version)

## Signing chains

The v2 signing key is stored in the login Keychain under the Sparkle account
`FineTune-gudelgado1-v2`. Only its public key is in `FineTune/Info.plist`:
`bbJTWltSeENt5vhQ8dWrgJgtLuqEaKc6a17mWUdW/8I=`.
The app keeps its existing bundle identifier and settings directories.

The private key for the legacy releases was lost with the previous Mac. Those
releases are ad hoc signed, without a Developer ID trust anchor for key rotation.
Install the new base manually once; the old installation cannot authenticate an
archive signed only by the new key. See [Sparkle key rotation](https://sparkle-project.org/documentation/#3-segue-for-security-concerns).

The new base points to `main/appcast-v2.xml` in this fork. The legacy `appcast.xml`
remains unchanged for existing installations. The v2 feed starts empty: staging
this configuration does not publish a release. Until the branch is merged, its
`main` feed URL is not live. Preview launchers disable automatic update checks.

## Backup and restore

The maintainer has an authenticated, password-encrypted v2 backup and a portable
restore kit outside the repository. Keep the encrypted file and restore kit on
another device or backup medium as well. A copy only on this Mac does not protect
against losing this Mac. Keep the password separately; do not put passwords,
private seeds, or backup archives in Git, Actions artifacts, issues, or logs.

Run `Restaurar-Sparkle.command` from that kit locally on a replacement Mac. It
asks for the password in the Terminal and restores the named Keychain account
only after authenticating the backup and matching the public key. It refuses to
replace a different existing key. The kit includes the Swift source and format
information; retain them with the encrypted file.

Check the public identity with the pinned Sparkle tools (no private export):

```bash
SPARKLE_BIN="/path/to/SourcePackages/artifacts/sparkle/Sparkle/bin"
"$SPARKLE_BIN/generate_keys" --account FineTune-gudelgado1-v2 -p
```

## Prepare a candidate

Use Xcode 27+ and the pinned package resolution. Increment
`CURRENT_PROJECT_VERSION` for each release; the v2 base uses build **4**, marketing
version **1.0.2**. Sparkle compares build numbers, not marketing versions. Keep
preview build numbers below the next stable build and disable updates in QA.

Build Release with the repository’s existing local ad hoc signing settings, then
verify the copied app with `codesign --verify --deep --strict`. The current local
candidate is ad hoc signed and not notarized. Do not claim Developer ID signing
or notarization from an Ed25519 archive signature.

Package the exact app as `FineTune.app` at the archive root, preserving symlinks:

```bash
APP="/path/to/Release/FineTune.app"
ZIP="/path/to/candidate/FineTune.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
"$SPARKLE_BIN/sign_update" --account FineTune-gudelgado1-v2 "$ZIP"
```

Record the printed public `sparkle:edSignature` and `length`. Independently verify
against the Info.plist from the app in that exact archive:

```bash
swift scripts/verify-update-signature.swift "$ZIP" "$APP/Contents/Info.plist" "BASE64_SIGNATURE"
```

Verify archive integrity, app signature, build number, architecture and embedded
public key. Confirm that the previous public key and a modified archive both fail
verification. Test the update in isolated QA copies before publishing.

## Publish after review

Publishing the stable release/feed and merging the PR are separate review steps.
Upload the verified archive as a GitHub Release asset. Only after the asset exists,
add an item to `appcast-v2.xml` with its HTTPS URL, exact byte length, signature,
`<sparkle:version>4</sparkle:version>`, short version `1.0.2` and the built app’s
minimum macOS version. Do not add the new archive to the legacy feed.

Follow [Sparkle’s publication guide](https://sparkle-project.org/documentation/publishing/).
An independent signature check does not certify end-to-end installation. Validate
the live feed and an actual v2-to-v2 update after publishing an appropriate QA
release. Replacing the executable can require re-granting Accessibility for media
keys; ordinary user audio settings retain the same storage locations.

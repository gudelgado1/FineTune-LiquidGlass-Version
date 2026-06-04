# Releasing FineTune (Liquid Glass Version)

How to cut a new release and ship it through Sparkle auto-update.

## How updates work here

- The app is **ad-hoc signed** (no paid Developer ID / no notarization). Users open
  it the first time with **right-click → Open**.
- Updates are delivered by **Sparkle** using an **EdDSA (ed25519)** signature:
  - The app embeds the **public** key in `Info.plist` → `SUPublicEDKey`
    (`0EhgtQvpW/aizEs/Ii1LLTinU6jMY0/AkcPuRL6mFzQ=`).
  - The matching **private** key lives only in your **login Keychain** and is used
    to sign each release.
  - `Info.plist` → `SUFeedURL` points at
    `https://raw.githubusercontent.com/gudelgado1/FineTune-LiquidGlass-Version/main/appcast.xml`.
  - Each release ships a `FineTune.zip` as a **GitHub Release asset**; `appcast.xml`
    (on `main`) lists it with its signature so the app can verify the download.

```
app (SUPublicEDKey) ──checks──► appcast.xml (main) ──points to──► GitHub Release asset (FineTune.zip, signed)
```

## One-time setup (already done — for reference)

The signing key was created with Sparkle's `generate_keys`. It is **not** in the
repo. The public key is in `Info.plist`; the private key is in the login Keychain
as **"Private key for signing Sparkle updates"**.

### ⚠️ Back up the private key

If you lose it you can never sign updates again (you'd have to generate a new key
and make every user reinstall). Export it and store it somewhere safe **outside the
repo** (password manager / encrypted backup):

```bash
SPARKLE_BIN="$(find ~/Library/Developer/Xcode/DerivedData -path '*/artifacts/sparkle/Sparkle/bin' -type d | head -1)"
"$SPARKLE_BIN/generate_keys" -x ~/Desktop/finetune_sparkle_private_key.txt
# move that file to safe storage, then delete it from the Desktop
```

To restore on a new machine: `"$SPARKLE_BIN/generate_keys" -f finetune_sparkle_private_key.txt`

## Cutting a release

Prerequisites: Xcode 16, `gh` authenticated (`gh auth login`), the Sparkle key in
your Keychain.

### 1. Bump the version

Edit **both** in `FineTune.xcodeproj` (Target → Build Settings), or in
`FineTune.xcodeproj/project.pbxproj`:

- `MARKETING_VERSION` → e.g. `1.0.1` (the user-facing version / `CFBundleShortVersionString`)
- `CURRENT_PROJECT_VERSION` → bump by 1, e.g. `2` (the build number / Sparkle's
  `sparkle:version`, which is what Sparkle actually compares)

Commit and push the bump.

### 2. Build Release + package the zip

```bash
DD="$HOME/Library/Developer/Xcode/DerivedData/FineTune-Release"
# Clock-skew guard: remove the product + intermediates so xcodebuild can't skip.
rm -rf "$DD/Build/Products/Release/FineTune.app" \
       "$DD/Build/Intermediates.noindex/FineTune.build/Release"

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild build \
  -project FineTune.xcodeproj -scheme FineTune -configuration Release \
  -derivedDataPath "$DD" -destination 'platform=macOS,arch=arm64' \
  ENABLE_HARDENED_RUNTIME=NO          # required: ad-hoc + Sparkle.framework

APP="$DD/Build/Products/Release/FineTune.app"
ZIP="$DD/Build/Products/Release/FineTune.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
```

> `ENABLE_HARDENED_RUNTIME=NO` is mandatory — the hardened runtime rejects the
> separately ad-hoc-signed `Sparkle.framework` and the app SIGKILLs at launch.
> `scripts/build-dmg.sh` assumes a Developer ID + notarization we don't have; don't
> use it for ad-hoc releases.

### 3. Sign the zip

```bash
SPARKLE_BIN="$(find ~/Library/Developer/Xcode/DerivedData -path '*/artifacts/sparkle/Sparkle/bin' -type d | head -1)"
"$SPARKLE_BIN/sign_update" "$ZIP"
# → prints:  sparkle:edSignature="…" length="…"
```

Copy the `edSignature` and `length`.

### 4. Create the GitHub Release

```bash
VERSION=1.0.1   # match step 1
gh release create "v$VERSION" "$ZIP#FineTune.zip" \
  --repo gudelgado1/FineTune-LiquidGlass-Version \
  --title "FineTune (Liquid Glass) $VERSION" \
  --notes "…release notes…"
```

The asset URL becomes:
`https://github.com/gudelgado1/FineTune-LiquidGlass-Version/releases/download/v$VERSION/FineTune.zip`

### 5. Add the entry to `appcast.xml` and push

Add a new `<item>` at the top of `<channel>` (newest first), using the signature,
length, and URL from above:

```xml
<item>
    <title>1.0.1</title>
    <sparkle:version>2</sparkle:version>                 <!-- = CURRENT_PROJECT_VERSION -->
    <sparkle:shortVersionString>1.0.1</sparkle:shortVersionString>
    <sparkle:minimumSystemVersion>14.2</sparkle:minimumSystemVersion>
    <pubDate>Thu, 04 Jun 2026 14:47:27 +0000</pubDate>  <!-- date -u "+%a, %d %b %Y %H:%M:%S +0000" -->
    <enclosure url="https://github.com/gudelgado1/FineTune-LiquidGlass-Version/releases/download/v1.0.1/FineTune.zip"
               sparkle:edSignature="…"
               length="…"
               type="application/octet-stream"/>
</item>
```

```bash
git add appcast.xml && git commit -m "Publish v1.0.1 to the appcast" && git push origin main
```

## Verify

```bash
# Appcast is live on the feed and lists the new version:
curl -fsSL https://raw.githubusercontent.com/gudelgado1/FineTune-LiquidGlass-Version/main/appcast.xml | grep -E "shortVersionString|enclosure"

# Release asset downloads (302 → 200, content-length == length in the appcast):
curl -sIL https://github.com/gudelgado1/FineTune-LiquidGlass-Version/releases/download/v1.0.1/FineTune.zip | grep -iE "^HTTP|content-length"
```

Then, from an **older** installed build, **Settings → Updates → Check for Updates**
should offer the new version and install it.

## Notes

- The `sparkle:version` (build number) is what Sparkle compares — always bump
  `CURRENT_PROJECT_VERSION`, even for tiny releases.
- Keep `appcast.xml` items newest-first; you may keep older items for history.
- Re-deploying changes the app's cdhash, which can drop the **Accessibility** grant
  (media keys). Re-grant in System Settings → Privacy & Security → Accessibility.

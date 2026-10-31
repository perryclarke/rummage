#!/bin/zsh
# Build build/release/QLZip-<version>.dmg: a disk image holding "Install QLZip.pkg", an installer
# that puts QLZip.app in /Applications (or ~/Applications) and registers its Quick Look extension.
#
#   ./scripts/release.sh             Developer ID–signed and notarized, for distribution
#   ./scripts/release.sh --unsigned  signed for this Mac only (Apple Development), not notarized;
#                                    for testing the installer before the certificates exist
#
# One-time setup for signed releases:
#   1. Create "Developer ID Application" and "Developer ID Installer" certificates
#      (Xcode › Settings › Accounts › Manage Certificates).
#   2. Store notarization credentials:
#        xcrun notarytool store-credentials QLZip --apple-id <you@example.com> --team-id YB35Q4YF78
#      (uses an app-specific password from appleid.apple.com)
# If notarization fails, `xcrun notarytool log <submission id> --keychain-profile QLZip` says why.
set -euo pipefail

cd "${0:A:h}/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(ls -d /Applications/Xcode*.app 2>/dev/null | sort -V | tail -1)/Contents/Developer}"
profile="${NOTARY_PROFILE:-QLZip}"
out=build/release
work=$out/work

signed=true
if [[ "${1:-}" == --unsigned ]]; then
    signed=false
elif [[ $# -gt 0 ]]; then
    echo "usage: $0 [--unsigned]" >&2
    exit 2
fi

if $signed; then
    for certificate in "Developer ID Application" "Developer ID Installer"; do
        if ! security find-identity -v | grep -q "$certificate"; then
            echo "error: no '$certificate' certificate in the keychain (see setup notes in $0," >&2
            echo "       or pass --unsigned for a test build)" >&2
            exit 1
        fi
    done
    if ! xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1; then
        echo "error: no notarization credentials named '$profile' (see setup notes in $0)" >&2
        exit 1
    fi
fi

notarize() {
    xcrun notarytool submit "$1" --keychain-profile "$profile" --wait
    xcrun stapler staple "$1"
}

rm -rf "$out"
mkdir -p "$work"
xcodegen generate --quiet

# 1. The app.
if $signed; then
    xcodebuild -project QLZip.xcodeproj -scheme QLZip -configuration Release \
        -derivedDataPath build/DerivedData -archivePath "$work/QLZip.xcarchive" \
        CODE_SIGN_IDENTITY="Developer ID Application" OTHER_CODE_SIGN_FLAGS="--timestamp" \
        -quiet archive
    cat > "$work/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>teamID</key><string>YB35Q4YF78</string>
    <key>signingStyle</key><string>manual</string>
    <key>signingCertificate</key><string>Developer ID Application</string>
</dict>
</plist>
EOF
    xcodebuild -exportArchive -archivePath "$work/QLZip.xcarchive" \
        -exportOptionsPlist "$work/ExportOptions.plist" -exportPath "$work/export" -quiet
    app="$work/export/QLZip.app"
else
    xcodebuild -project QLZip.xcodeproj -scheme QLZip -configuration Release \
        -destination 'generic/platform=macOS' -derivedDataPath build/DerivedData -quiet build
    app=build/DerivedData/Build/Products/Release/QLZip.app
fi
version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$app/Contents/Info.plist")

# 2. The installer package.
mkdir -p "$work/root"
ditto "$app" "$work/root/QLZip.app"
# Installer would otherwise "upgrade" any copy of QLZip.app it finds elsewhere on the disk
# (such as a build folder) instead of installing to the chosen location.
pkgbuild --analyze --root "$work/root" "$work/components.plist" >/dev/null
plutil -replace 0.BundleIsRelocatable -bool NO "$work/components.plist"
pkgbuild --root "$work/root" --component-plist "$work/components.plist" \
    --identifier com.perryclarke.QLZip --version "$version" --install-location /Applications \
    --scripts Installer/scripts --quiet "$work/QLZip.pkg"
# pkgbuild stores each file's com.apple.provenance attribute (which macOS adds to files written
# by processes started from downloaded apps, such as most terminals) as an AppleDouble entry,
# so installing would copy this Mac's provenance onto every file. Keep pkgbuild's PackageInfo
# but rebuild the payload, scripts and bill of materials without them. (pkgutil --flatten
# archives the Scripts folder itself, without the attributes.)
pkgutil --expand "$work/QLZip.pkg" "$work/component"
rm -rf "$work/QLZip.pkg" "$work/component/Scripts"
(cd "$work/root" && find . | cpio -o --format odc -R 0:0 --quiet) | gzip -9 > "$work/component/Payload"
ditto Installer/scripts "$work/component/Scripts"
lsbom "$work/component/Bom" | grep -v '/\._' > "$work/bom.txt" # keeps pkgbuild's root:wheel owners
mkbom -i "$work/bom.txt" "$work/component/Bom"
files=$(wc -l < "$work/bom.txt" | tr -d ' ')
sed -i '' "s/numberOfFiles=\"[0-9]*\"/numberOfFiles=\"$files\"/" "$work/component/PackageInfo"
pkgutil --flatten "$work/component" "$work/QLZip.pkg"

cat > "$work/distribution.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>QLZip</title>
    <conclusion file="conclusion.html" mime-type="text/html"/>
    <options customize="never" require-scripts="false" hostArchitectures="arm64,x86_64"/>
    <domains enable_localSystem="true" enable_currentUserHome="true"/>
    <allowed-os-versions><os-version min="14.0"/></allowed-os-versions>
    <choices-outline><line choice="default"><line choice="com.perryclarke.QLZip"/></line></choices-outline>
    <choice id="default"/>
    <choice id="com.perryclarke.QLZip" visible="false"><pkg-ref id="com.perryclarke.QLZip"/></choice>
    <pkg-ref id="com.perryclarke.QLZip" version="$version" onConclusion="none">#QLZip.pkg</pkg-ref>
</installer-gui-script>
EOF
mkdir -p "$work/dmg"
pkg="$work/dmg/Install QLZip.pkg"
sign=()
$signed && sign=(--sign "Developer ID Installer" --timestamp)
productbuild --distribution "$work/distribution.xml" --package-path "$work" \
    --resources Installer/Resources "${sign[@]}" --quiet "$pkg"
$signed && notarize "$pkg"

# 3. The disk image.
dmg="$out/QLZip-$version.dmg"
hdiutil create -volname "QLZip $version" -srcfolder "$work/dmg" -format UDZO -quiet "$dmg"
if $signed; then
    codesign --sign "Developer ID Application" --timestamp "$dmg"
    notarize "$dmg"
    spctl --assess --type install --verbose "$pkg"
    spctl --assess --type open --context context:primary-signature --verbose "$dmg"
else
    echo "warning: unsigned test build; Gatekeeper will block it on other Macs" >&2
fi

# Launch Services registers the build copies of QLZip.app, and being identical to an installed
# copy, they would take over its Quick Look extension; unregister them.
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
for copy in build/DerivedData/Build/Products/Release/QLZip.app $work/**/QLZip.app(N/); do
    pluginkit -r "$copy/Contents/PlugIns/QLZipPreview.appex" 2>/dev/null || true
    $lsregister -u "$copy" 2>/dev/null || true
done
echo "Release ready: $dmg"

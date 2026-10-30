#!/bin/zsh
# Build a Developer ID–signed, notarized QLZip.zip for distribution.
#
# One-time setup:
#   1. Create a "Developer ID Application" certificate (Xcode › Settings › Accounts › Manage Certificates).
#   2. Store notarization credentials:
#        xcrun notarytool store-credentials QLZip --apple-id <you@example.com> --team-id YB35Q4YF78
#      (uses an app-specific password from appleid.apple.com)
set -euo pipefail

cd "${0:A:h}/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(ls -d /Applications/Xcode*.app 2>/dev/null | sort -V | tail -1)/Contents/Developer}"
profile="${NOTARY_PROFILE:-QLZip}"
out=build/release

if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
    echo "error: no 'Developer ID Application' certificate in the keychain (see setup notes in $0)" >&2
    exit 1
fi

rm -rf "$out"
mkdir -p "$out"
xcodegen generate --quiet
xcodebuild -project QLZip.xcodeproj -scheme QLZip -configuration Release \
    -derivedDataPath build/DerivedData -archivePath "$out/QLZip.xcarchive" \
    CODE_SIGN_IDENTITY="Developer ID Application" OTHER_CODE_SIGN_FLAGS="--timestamp" \
    -quiet archive

cat > "$out/ExportOptions.plist" <<EOF
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
xcodebuild -exportArchive -archivePath "$out/QLZip.xcarchive" \
    -exportOptionsPlist "$out/ExportOptions.plist" -exportPath "$out/export" -quiet

app="$out/export/QLZip.app"
ditto -c -k --keepParent "$app" "$out/QLZip-notarize.zip"
xcrun notarytool submit "$out/QLZip-notarize.zip" --keychain-profile "$profile" --wait
xcrun stapler staple "$app"
spctl --assess --type execute --verbose "$app"

ditto -c -k --keepParent "$app" "$out/QLZip.zip"
echo "Release ready: $out/QLZip.zip"

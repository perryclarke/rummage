#!/bin/zsh
# Build QLZip with the local Apple Development identity and install it to ~/Applications.
set -euo pipefail

cd "${0:A:h}/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(ls -d /Applications/Xcode*.app 2>/dev/null | sort -V | tail -1)/Contents/Developer}"

xcodegen generate --quiet
xcodebuild -project QLZip.xcodeproj -scheme QLZip -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath build/DerivedData -quiet build

app=build/DerivedData/Build/Products/Release/QLZip.app
dest="$HOME/Applications/QLZip.app"
mkdir -p "$HOME/Applications"
rm -rf "$dest"
cp -R "$app" "$dest"

# Make sure only the installed copy is registered, not the one in the build folder.
pluginkit -r "$PWD/$app/Contents/PlugIns/QLZipPreview.appex" 2>/dev/null || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$PWD/$app" 2>/dev/null || true

# Register the extension and flush Quick Look's caches so the new build is used.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f -R "$dest"
pluginkit -a "$dest/Contents/PlugIns/QLZipPreview.appex"
pluginkit -e use -i com.perryclarke.QLZip.Preview
qlmanage -r >/dev/null
qlmanage -r cache >/dev/null

echo "Installed $dest"

#!/bin/zsh
# Build Rummage with the local Apple Development identity and install it to ~/Applications.
set -euo pipefail

cd "${0:A:h}/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(ls -d /Applications/Xcode*.app 2>/dev/null | sort -V | tail -1)/Contents/Developer}"

xcodegen generate --quiet
xcodebuild -project Rummage.xcodeproj -scheme Rummage -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath build/DerivedData -quiet build

app=build/DerivedData/Build/Products/Release/Rummage.app
dest="$HOME/Applications/Rummage.app"
extension=com.perryclarke.Rummage.Preview
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# Make sure only the installed copy is registered, not the copies in the build folder: this
# build's, and those release.sh leaves (its archive, export and package root). This comes first:
# the system applies it asynchronously, and as the copies all have the same bundle ID, applied after
# the installed copy is registered it can unregister that one too.
for copy in "$PWD/$app" "$PWD"/build/release/work/**/Rummage.app(N/); do
    pluginkit -r "$copy/Contents/PlugIns/RummagePreview.appex" 2>/dev/null || true
    $lsregister -u "$copy" 2>/dev/null || true
done

mkdir -p "$HOME/Applications"
rm -rf "$dest"
cp -R "$app" "$dest"

# Register the extension, checking that it took (registration is asynchronous, so retry).
for attempt in {1..5}; do
    $lsregister -f -R "$dest"
    pluginkit -a "$dest/Contents/PlugIns/RummagePreview.appex"
    sleep 1
    pluginkit -m -v -i $extension | grep -qF "$dest" && break
    if (( attempt == 5 )); then
        echo "The Quick Look extension didn't register; run this script again." >&2
        exit 1
    fi
done
pluginkit -e use -i $extension

# Flush Quick Look's caches so the new build is used.
qlmanage -r >/dev/null
qlmanage -r cache >/dev/null

echo "Installed $dest"

#!/bin/zsh
# Build a zip with a sampling of file types and edge cases for trying QLZip: images, camera RAW
# files, documents, spreadsheets, code, text in odd encodings, fonts, media, a symlink, a nested zip,
# an encrypted entry and more. Its README.md says what each preview should show.
#
# usage: scripts/make-test-archive.sh [--raw FILE_OR_FOLDER]... [OUTPUT.zip]
#   --raw   camera RAW files to include, or a folder to take them from (including its subfolders);
#           without any, the archive has no RAW folder
#   OUTPUT  where to write the archive (default: build/QLZip Test Archive.zip)
set -euo pipefail

cd "${0:A:h}/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(ls -d /Applications/Xcode*.app 2>/dev/null | sort -V | tail -1)/Contents/Developer}"

raws=()
output="build/QLZip Test Archive.zip"
while (( $# )); do
    case $1 in
        --raw) raws+=("$2"); shift 2 ;;
        -h|--help) sed -n '2,9p' "$0" | cut -c3-; exit 0 ;;
        *) output=$1; shift ;;
    esac
done
output=${output:A}
tools=$PWD/scripts/test-archive

work=$(mktemp -d -t qlzip-test-archive)
trap 'rm -rf "$work"' EXIT
name="QLZip Test Archive"
root="$work/$name"
mkdir -p "$root"

echo "Generating files…"
xcrun swiftc -O "$tools/generate.swift" -o "$work/generate"
"$work/generate" "$root"
python3 -I "$tools/generate.py" "$root" "$work"

cd "$root"

# A photo in several formats, from a macOS wallpaper (or a generated picture if there's none).
photo=(/System/Library/Desktop\ Pictures/*.heic(N[1]))
photo=${photo:-Images/Gallery/picture-1.jpg}
sips -Z 4000 -s format jpeg "$photo" --out Images/photo.jpg >/dev/null
sips -s format heic Images/photo.jpg --out Images/photo.heic >/dev/null
sips -Z 1600 -s format tiff Images/photo.jpg --out Images/photo.tiff >/dev/null
width=$(sips -g pixelWidth Images/photo.jpg | awk '/pixelWidth/ { print $2 }')
sips --cropToHeightWidth $(( width / 5 )) "$width" Images/photo.jpg --out Images/panorama.jpg >/dev/null
cp /System/Applications/Calculator.app/Contents/Resources/AppIcon.icns Images/

# Camera RAW files.
if (( ${#raws} )); then
    mkdir -p RAW
    for raw in $raws; do
        find "$raw" -type f \( -iname '*.cr3' -o -iname '*.cr2' -o -iname '*.crw' -o -iname '*.nef' -o -iname '*.nrw' \
            -o -iname '*.arw' -o -iname '*.dng' -o -iname '*.raf' -o -iname '*.orf' -o -iname '*.rw2' -o -iname '*.pef' \
            -o -iname '*.srw' -o -iname '*.3fr' -o -iname '*.iiq' \) -exec cp {} RAW/ \;
    done
    files=(RAW/*(N))
    if (( ${#files} )); then chmod 644 $files; else rmdir RAW; fi
fi

# The same formatted letter as RTF, Word, Word 97 and OpenDocument.
for format in rtf docx doc odt; do
    textutil -convert $format "$work/letter.html" -output "Documents/Formatted Letter.$format"
done

# Fonts: TrueType, OpenType, a collection (WOFF is generated).
cp "/System/Library/Fonts/Supplemental/Andale Mono.ttf" Fonts/
otf=(/Library/Fonts/*.otf(N[1]) /System/Library/Fonts/**/*.otf(N[1]))
cp "$otf[1]" Fonts/
cp "/System/Library/Fonts/Avenir Next.ttc" "Fonts/Avenir Next (collection).ttc"

# Audio.
say -o Media/speech.m4a --file-format=m4af --data-format=aac \
    "This is a test recording for the QLZip test archive. If you can hear this, audio previews work."
afconvert -f WAVE -d LEI16 Media/speech.m4a Media/speech.wav

# A document only Quick Look's thumbnail can show, if Numbers is installed.
numbers=/Applications/Numbers.app/Contents/Resources/SampleDocument.numbers
[[ -f $numbers ]] && cp "$numbers" "Other/Numbers document (thumbnail preview).numbers"

# Archive structure: an empty folder, a symlink and a zip inside the zip.
mkdir -p "Other/Empty Folder"
ln -s ../Text/notes.txt "Other/link to notes.txt"
mkdir "$work/nested"
echo "A file inside a zip inside the zip." > "$work/nested/inner.txt"
cp "Images/tiny 32px.png" "$work/nested/"
(cd "$work/nested" && zip -q -X "$root/Other/nested archive.zip" inner.txt "tiny 32px.png")

echo "Zipping…"
cd "$work"
mkdir -p "${output:h}"
rm -f "$output"
zip -r -y -X -q "$output" "$name" -x '*.DS_Store'
# Added on its own with a password, so that only this entry is encrypted.
echo "This entry is encrypted, so it can't be previewed. The password is qlzip." > "$name/Other/secret (encrypted).txt"
zip -X -q -P qlzip "$output" "$name/Other/secret (encrypted).txt"

echo "Made $output ($(du -h "$output" | cut -f1 | tr -d ' '), $(zipinfo -1 "$output" | grep -cv '/$') files)"

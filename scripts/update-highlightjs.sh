#!/bin/zsh
# Rebuild the vendored highlight.js bundle used for syntax coloring:
# the "common" build (36 languages) plus the extra grammars listed below.
#
#   ./scripts/update-highlightjs.sh [version]
set -euo pipefail

version="${1:-11.12.0}"
extra_languages=(
    apache armasm awk clojure cmake dart dockerfile dos elixir elm erlang fortran fsharp
    glsl gradle groovy haskell http julia latex lisp llvm matlab nginx nix ocaml
    powershell properties protobuf scala scheme tcl verilog vhdl vim x86asm
)

cd "${0:A:h}/.."
dest=PreviewExtension/Vendor/highlightjs
base="https://cdn.jsdelivr.net/npm/@highlightjs/cdn-assets@$version"
tmp=$(mktemp -d)
trap 'command rm -rf "$tmp"' EXIT

curl -sSf -o "$tmp/core.js" "$base/highlight.min.js"
curl -sSf -o "$tmp/LICENSE" "$base/LICENSE"
for lang in $extra_languages; do
    curl -sSf -o "$tmp/$lang.js" "$base/languages/$lang.min.js"
done

mkdir -p "$dest"
{
    cat "$tmp/core.js"
    for lang in $extra_languages; do
        printf '\n'
        cat "$tmp/$lang.js"
    done
} > "$dest/highlight.min.js"
command cp "$tmp/LICENSE" "$dest/highlightjs-LICENSE.txt"  # bundled: BSD-3 requires shipping the notice
echo "highlight.js $version + ${#extra_languages} extra languages -> $dest ($(wc -c < "$dest/highlight.min.js" | tr -d ' ') bytes)"

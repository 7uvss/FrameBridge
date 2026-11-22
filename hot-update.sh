#!/bin/zsh
set -eu
cd "${0:A:h}"
build=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' Info.plist)
folder="$HOME/Library/Application Support/FrameBridge/Shaders/$build"
mkdir -p "$folder"
if [[ "${1:-}" == --reset ]]; then
    rm -f "$folder/Pipeline.metal"
else
    sourceFile="${1:-Sources/Pipeline.metal}"
    temp=$(mktemp "$folder/.shader.XXXXXX")
    trap 'rm -f "$temp"' EXIT
    cp "$sourceFile" "$temp"
    mv -f "$temp" "$folder/Pipeline.metal"
fi

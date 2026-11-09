#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

build_dir="${1:-$PWD/build}"
mkdir -p "$build_dir"
build_dir="$(cd "$build_dir" && pwd)"
bundle="$build_dir/Driftwood.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources" "$build_dir/module-cache"
for arch in arm64 x86_64; do
    xcrun swiftc -O -parse-as-library -target "${arch}-apple-macosx14.0" \
        -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
        -module-cache-path "$build_dir/module-cache" \
        Sources/*.swift -o "$build_dir/Driftwood-$arch"
done
xcrun lipo -create "$build_dir/Driftwood-arm64" "$build_dir/Driftwood-x86_64" \
    -output "$bundle/Contents/MacOS/Driftwood"
cp Info.plist "$bundle/Contents/"
cp LICENSE LICENSE-WallFlow "$bundle/Contents/Resources/"
cp -R Artwork "$bundle/Contents/Resources/"
codesign --force --sign - "$bundle"
printf '%s\n' "$bundle"

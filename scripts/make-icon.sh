#!/bin/bash
# Preserve the supplied artwork; mask it into the macOS icon shape, then resize it into the standard icon set.
set -euo pipefail
cd "$(dirname "$0")/.."
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT
iconset="$temporary/BatEcho.iconset"
mkdir "$iconset"
master="$temporary/BatEcho-1024.png"
swift scripts/make-icon-master.swift Resources/BatEcho.png "$master"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$master" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$master" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o Resources/BatEcho.icns
echo "Generated Resources/BatEcho.icns"

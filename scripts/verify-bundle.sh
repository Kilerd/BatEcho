#!/bin/bash
# Validate the assembled app, including resources that SwiftPM alone cannot test.
set -euo pipefail
app="${1:?Usage: scripts/verify-bundle.sh path/to/BatEcho.app}"
plist="$app/Contents/Info.plist"
codesign --verify --deep --strict --verbose=2 "$app"
test "$(plutil -extract CFBundleExecutable raw -o - "$plist")" = BatEcho
test "$(plutil -extract CFBundleDisplayName raw -o - "$plist")" = BatEcho
test "$(plutil -extract CFBundleIdentifier raw -o - "$plist")" = com.kilerd.voicer
test "$(plutil -extract CFBundleIconFile raw -o - "$plist")" = BatEcho
lipo "$app/Contents/MacOS/BatEcho" -verify_arch arm64
resources="$app/Contents/Resources"
test -s "$resources/BatEcho.icns"
test -s "$resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
for file in lexicon.json pinyin-characters.json pinyin-phrases.json ThirdPartyNotices.txt FireRed-LICENSE Silero-LICENSE; do
    test -s "$resources/BatEcho_BatEcho.bundle/Contents/Resources/ASRResources/$file"
done
entitlements=$(codesign -d --xml --entitlements - "$app" 2>/dev/null)
test "$(printf '%s' "$entitlements" | plutil -extract 'com\.apple\.security\.device\.audio-input' raw -o - -)" = true
python3 "$(dirname "$0")/check-repository-privacy.py" --bundle "$app"
echo "BatEcho bundle, arm64 executable, icon, MLX kernels and microphone entitlement verified."
"$app/Contents/MacOS/BatEcho" --verify-runtime

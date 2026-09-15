#!/bin/bash
# Build and verify a Developer ID distribution. This script never publishes it.
# BATECHO_SIGN_IDENTITY: certificate name or SHA-1 in the local keychain.
# BATECHO_NOTARY_PROFILE: existing notarytool keychain profile (default: batecho-notary).
# BATECHO_NOTARY_KEYCHAIN: keychain containing the profile (default: login keychain).
# BATECHO_EXPECTED_VERSION: optional version assertion, used by tag builds.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "error: $*" >&2; exit 1; }
case "${1:-}" in
    ''|--preflight) ;;
    *) fail "Usage: scripts/release.sh [--preflight]" ;;
esac
version=$(plutil -extract CFBundleShortVersionString raw -o - Resources/Info.plist)
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Version must be X.Y.Z in Resources/Info.plist."
if [[ -n "${BATECHO_EXPECTED_VERSION:-}" && "$version" != "$BATECHO_EXPECTED_VERSION" ]]; then
    fail "Tag/version mismatch: expected $BATECHO_EXPECTED_VERSION, Info.plist has $version."
fi
identity="${BATECHO_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')}"
[[ -n "$identity" && "$identity" != '-' ]] || fail "A Developer ID Application identity is required."
profile="${BATECHO_NOTARY_PROFILE:-batecho-notary}"
keychain="${BATECHO_NOTARY_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
notary_auth=(--keychain-profile "$profile" --keychain "$keychain")
identities=$(security find-identity -v -p codesigning)
if ! printf '%s\n' "$identities" | awk -v wanted="$identity" '
    /Developer ID Application/ {
        name=$0; sub(/^[^"]*"/, "", name); sub(/".*$/, "", name)
        if ($2 == wanted || name == wanted) found=1
    }
    END { exit !found }'; then
    fail "The selected identity is not an available Developer ID Application certificate."
fi
if ! xcrun notarytool history "${notary_auth[@]}" --output-format json >/dev/null; then
    fail "Notary profile '$profile' cannot authenticate. See docs/macos-release.md."
fi
echo "Preflight passed: BatEcho $version; Developer ID identity and notary profile available."
[[ "${1:-}" != --preflight ]] || exit 0

make build SIGN_IDENTITY=-
mkdir -p dist
app=dist/BatEcho.app
archive="dist/BatEcho-${version}-macos-arm64.zip"
temporary=$(mktemp -d "${TMPDIR:-/tmp}/batecho-release.XXXXXX")
trap 'rm -rf "$temporary"' EXIT
rm -rf "$app"
ditto build/BatEcho.app "$app"

# Only the main executable is Mach-O; MLX's compiled kernels are resource data.
# --deep is useful for verification, but is deprecated for signing.
codesign --force --options runtime --timestamp \
    --entitlements Resources/BatEcho.entitlements --sign "$identity" "$app"
scripts/verify-bundle.sh "$app"
signature=$(codesign -dvv "$app" 2>&1)
[[ "$signature" == *"Authority=Developer ID Application:"* ]] || fail "Wrong signing certificate."
[[ "$signature" == *"(runtime)"* ]] || fail "Hardened Runtime is missing."
[[ "$signature" == *"Timestamp="* ]] || fail "Secure timestamp is missing."

# Submit a throwaway ZIP, staple the app, then create the downloadable ZIP.
# Signing again after notarization would invalidate the ticket.
ditto -c -k --keepParent "$app" "$temporary/notarize-upload.zip"
submission="dist/notarization.json"
submit_result=0
xcrun notarytool submit "$temporary/notarize-upload.zip" \
    "${notary_auth[@]}" --wait --timeout 30m --output-format json \
    > "$submission" || submit_result=$?
status=$(plutil -extract status raw -o - "$submission" 2>/dev/null || true)
submission_id=$(plutil -extract id raw -o - "$submission" 2>/dev/null || true)
if [[ "$submit_result" != 0 || "$status" != Accepted ]]; then
    if [[ -n "$submission_id" ]]; then
        xcrun notarytool log "$submission_id" "${notary_auth[@]}" \
            dist/notarization-log.json || true
        echo "Submission ID: $submission_id (kept in $submission)" >&2
    fi
    fail "Notarization did not finish as Accepted (status: ${status:-unknown}). No release archive was produced."
fi
xcrun stapler staple "$app"
xcrun stapler validate "$app"

# Ticket propagation can lag. Require both a successful exit and the expected
# source; never treat a diagnostic substring on a failed assessment as success.
assert_notarized() {
    local target="$1" attempt assessment
    for attempt in 1 2 3 4 5 6 7 8; do
        if assessment=$(spctl --assess --type execute --verbose=2 "$target" 2>&1); then
            if [[ "$assessment" == *"source=Notarized Developer ID"* ]]; then
                echo "$assessment"
                return 0
            fi
        fi
        if [[ "$attempt" != 8 ]]; then
            echo "Waiting for Gatekeeper ticket propagation ($attempt/8)…"
            sleep 15
        fi
    done
    echo "$assessment" >&2
    return 1
}
assert_notarized "$app" || fail "Gatekeeper did not accept the notarized app."
ditto -c -k --keepParent "$app" "$temporary/BatEcho.zip"
ditto -x -k "$temporary/BatEcho.zip" "$temporary/unpacked"
scripts/verify-bundle.sh "$temporary/unpacked/BatEcho.app"
xcrun stapler validate "$temporary/unpacked/BatEcho.app"
assert_notarized "$temporary/unpacked/BatEcho.app" || fail "The unpacked ZIP did not pass Gatekeeper."

# Move the archive into dist only after the exact download passes verification.
mv -f "$temporary/BatEcho.zip" "$archive"
(cd dist && shasum -a 256 "$(basename "$archive")" > SHA256SUMS)
{
    echo "product=BatEcho"
    echo "version=$version"
    echo "commit=$(git rev-parse HEAD)"
    echo "dirty=$(test -z "$(git status --porcelain)" && echo false || echo true)"
    echo "architecture=arm64"
    echo "notarization_id=$submission_id"
    echo "notarization_status=$status"
    echo "built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > dist/build-info.txt
echo "Ready: $archive (signed, notarized, stapled and verified; not published)."

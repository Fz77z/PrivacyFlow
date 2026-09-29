#!/bin/bash
# Build PrivacyFlow.app into build/.
#
# Assembles the bundle around the release binary, copies its resources, and
# signs it. It installs nothing: the result stays in build/.
#
# scripts/release.sh wraps the result in a DMG and, for a Developer ID build,
# notarises it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_SOURCE="$ROOT/app"
BUILD="$ROOT/build"
BUNDLE="$BUILD/PrivacyFlow.app"
VERSION="$(tr -d '[:space:]' < "$APP_SOURCE/VERSION")"
SILERO_VAD_DIR="$APP_SOURCE/Resources/SileroVAD"
# "adhoc" for builds that run only on this Mac or are shared unsigned, or
# "developer-id" for a release, which also needs DEVELOPER_ID_IDENTITY set to
# the certificate's name, e.g. "Developer ID Application: Name (TEAMID)".
SIGNING="${SIGNING:-adhoc}"
# Debug builds carry the --preview screenshot harness; releases do not.
CONFIGURATION="${CONFIGURATION:-release}"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Refusing to build: app/VERSION must be a version like 1.2.3, got '$VERSION'" >&2
    exit 1
fi
case "$SIGNING" in
    adhoc) ;;
    developer-id)
        if [[ -z "${DEVELOPER_ID_IDENTITY:-}" ]]; then
            echo "Refusing to build: SIGNING=developer-id needs DEVELOPER_ID_IDENTITY" >&2
            exit 1
        fi
        ;;
    *)
        echo "Refusing to build: SIGNING must be adhoc or developer-id, got '$SIGNING'" >&2
        exit 1
        ;;
esac

echo "Building PrivacyFlow $VERSION ($CONFIGURATION)"
swift build --package-path "$APP_SOURCE" -c "$CONFIGURATION" --arch arm64
BINARY="$(swift build --package-path "$APP_SOURCE" -c "$CONFIGURATION" --arch arm64 --show-bin-path)/PrivacyFlow"

# Assembled from scratch every time, so a stale file can never survive.
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
sed "s/VERSION_PLACEHOLDER/$VERSION/g" "$APP_SOURCE/Resources/Info.plist" > "$BUNDLE/Contents/Info.plist"
cp "$BINARY" "$BUNDLE/Contents/MacOS/PrivacyFlow"
# The debug map lists every source and object file by its path on this
# machine. A release carries no debug information, so it goes...
strip -S "$BUNDLE/Contents/MacOS/PrivacyFlow"

RESOURCES="$BUNDLE/Contents/Resources"
cp "$APP_SOURCE/Resources/Fonts/Inter-Regular.ttf" "$APP_SOURCE/Resources/Fonts/Inter-SemiBold.ttf" "$RESOURCES/"
cp "$APP_SOURCE/Resources/Fonts/OFL.txt" "$RESOURCES/Inter-OFL.txt"
cp "$APP_SOURCE/Resources/Sounds/press.wav" "$APP_SOURCE/Resources/Sounds/release.wav" "$RESOURCES/"
cp "$APP_SOURCE/Resources/models.json" "$RESOURCES/"
cp "$SILERO_VAD_DIR/silero_vad.onnx" "$RESOURCES/"
cp "$SILERO_VAD_DIR/LICENSE" "$RESOURCES/silero_vad-LICENSE.txt"

# The worker's private Python runtime, built by scripts/build-runtime.sh. It is
# rebuilt only when missing, because it is slow and pinned; delete
# build/runtime to force it after changing worker/...
if [[ ! -x "$BUILD/runtime/bin/python3" ]]; then
    "$ROOT/scripts/build-runtime.sh"
fi
cp -R "$BUILD/runtime" "$RESOURCES/runtime"
cp "$ROOT/LICENSE" "$RESOURCES/LICENSE.txt"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$RESOURCES/THIRD_PARTY_NOTICES.md"

# The icon takes a while to render and is deterministic, so it is rendered only
# when the generator is newer than its output. Delete build/AppIcon.png to force it.
ICON="$BUILD/AppIcon.png"
if [[ ! -f "$ICON" || "$ROOT/scripts/make-icon.swift" -nt "$ICON" ]]; then
    echo "Rendering the app icon"
    swift "$ROOT/scripts/make-icon.swift" "$ICON"
fi
ICONSET="$BUILD/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z $size $size "$ICON" --out "$ICONSET/icon_${size}x${size}.png" > /dev/null
    sips -z $((size * 2)) $((size * 2)) "$ICON" --out "$ICONSET/icon_${size}x${size}@2x.png" > /dev/null
done
iconutil -c icns "$ICONSET" -o "$RESOURCES/AppIcon.icns"

# Nothing that ships may name the machine it was built on. Checked before
# signing, so a leak can never be sealed into a release...
leaks="$(LC_ALL=C /usr/bin/grep -rlaF "$HOME" "$BUNDLE" || true)"
if [[ -n "$leaks" ]]; then
    echo "The bundle contains this machine's home directory path in:" >&2
    echo "$leaks" >&2
    exit 1
fi

# Every Mach-O file in the runtime is signed on its own, innermost first, before
# the bundle that seals them. A Developer ID signature adds the hardened runtime,
# which notarisation requires, and a secure timestamp...
if [[ "$SIGNING" == "developer-id" ]]; then
    SIGN_ARGUMENTS=(--force --timestamp --options runtime --sign "$DEVELOPER_ID_IDENTITY")
else
    SIGN_ARGUMENTS=(--force --sign -)
fi
while IFS= read -r -d '' candidate; do
    if file --brief "$candidate" | grep -q "Mach-O"; then
        codesign "${SIGN_ARGUMENTS[@]}" "$candidate"
    fi
done < <(find "$RESOURCES/runtime" -type f -print0)
codesign "${SIGN_ARGUMENTS[@]}" --entitlements "$APP_SOURCE/Resources/PrivacyFlow.entitlements" "$BUNDLE"
codesign --verify --strict --deep "$BUNDLE"

IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$BUNDLE/Contents/Info.plist")"
UI_ELEMENT="$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$BUNDLE/Contents/Info.plist")"
if [[ "$IDENTIFIER" != "io.github.fz77z.privacyflow" || "$UI_ELEMENT" != "true" ]]; then
    echo "The assembled Info.plist is wrong: identifier '$IDENTIFIER', LSUIElement '$UI_ELEMENT'" >&2
    exit 1
fi
echo "Built $BUNDLE"

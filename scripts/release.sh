#!/bin/bash
# Build the release DMG, build/PrivacyFlow-<version>.dmg, ready to attach to a
# GitHub release.
#
# SIGNING=adhoc (the default) builds a DMG that is not notarised. It installs
# and runs, but macOS blocks the first launch until the user allows it in
# System Settings, and treats every new version as a different app for
# permissions. The README tells users both.
#
# SIGNING=developer-id signs with DEVELOPER_ID_IDENTITY and notarises with the
# notarytool keychain profile named by NOTARY_PROFILE, created once with:
#
#     xcrun notarytool store-credentials <profile> --apple-id <id> --team-id <team>
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build"
SIGNING="${SIGNING:-adhoc}"
VERSION="$(tr -d '[:space:]' < "$ROOT/app/VERSION")"
DMG="$BUILD/PrivacyFlow-$VERSION.dmg"

if [[ "$SIGNING" == "developer-id" && -z "${NOTARY_PROFILE:-}" ]]; then
    echo "Refusing to release: SIGNING=developer-id needs NOTARY_PROFILE" >&2
    exit 1
fi

# A release must download its models from somewhere, so every file in the
# manifest needs a URL. scripts/publish-models.py fills them in...
if grep -q '"url": null' "$ROOT/app/Resources/models.json"; then
    echo "Refusing to release: app/Resources/models.json has files without a URL. Run scripts/publish-models.py first." >&2
    exit 1
fi

# The worker's runtime is rebuilt from its pins for every release, so nothing
# left over from development can ship...
rm -rf "$BUILD/runtime"
SIGNING="$SIGNING" "$ROOT/scripts/build-app.sh"

# The disk image holds the app beside a link to /Applications, so installing is
# one drag...
STAGING="$BUILD/dmg"
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$BUILD/PrivacyFlow.app" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -quiet -volname "PrivacyFlow $VERSION" -srcfolder "$STAGING" -format ULFO -fs APFS "$DMG"
rm -rf "$STAGING"

if [[ "$SIGNING" == "developer-id" ]]; then
    codesign --force --timestamp --sign "$DEVELOPER_ID_IDENTITY" "$DMG"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose "$DMG"
fi

echo "Released $DMG ($(du -h "$DMG" | cut -f1))"
echo "SHA-256 $(shasum -a 256 "$DMG" | cut -d' ' -f1)"

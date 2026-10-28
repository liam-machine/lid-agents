#!/bin/bash
# Builds "build/Lid Agents.app" (universal), dist/lid-agents.tar.gz and dist/LidAgents.dmg.
#   scripts/build.sh [version]     version defaults to the VERSION file
#
# Signing: with SIGN_IDENTITY (e.g. "Developer ID Application: Name (TEAMID)") the app and
# DMG are signed with the hardened runtime; without it they are ad-hoc signed.
# Notarization: with NOTARY_KEY_PATH, NOTARY_KEY_ID and NOTARY_ISSUER_ID (an App Store
# Connect API key), or NOTARY_PROFILE (a `notarytool store-credentials` profile), the app and
# DMG are notarized and stapled.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(cat VERSION)}"
VERSION="${VERSION#v}"
APP="build/Lid Agents.app"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"

rm -rf build dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj build/AppIcon.iconset build/dmg dist

echo "==> Compiling (arm64 + x86_64)"
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos13.0" -o "build/obj/LidAgents-$arch" app/LidAgents.swift
done
lipo -create -output "$APP/Contents/MacOS/LidAgents" build/obj/LidAgents-arm64 build/obj/LidAgents-x86_64

echo "==> Bundling $VERSION"
sed "s/__VERSION__/$VERSION/g" app/Info.plist > "$APP/Contents/Info.plist"
sed "s/^AGENTS_VERSION=.*/AGENTS_VERSION=\"$VERSION\"/" bin/agents > "$APP/Contents/Resources/agents"
chmod 755 "$APP/Contents/Resources/agents"
cp integrations/opencode/lid-agents.js "$APP/Contents/Resources/opencode-lid-agents.js"

echo "==> Icon"
swift assets/make_icon.swift build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

notarize() {   # notarize <file>: submit, wait, and staple
  local args=()
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    args=(--keychain-profile "$NOTARY_PROFILE")
  elif [ -n "${NOTARY_KEY_PATH:-}" ]; then
    args=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
  else
    return 0
  fi
  local upload="$1"
  if [ -d "$1" ]; then upload="build/notarize.zip"; ditto -c -k --keepParent "$1" "$upload"; fi
  echo "==> Notarizing $(basename "$1") (usually 1-5 minutes)"
  xcrun notarytool submit "$upload" "${args[@]}" --wait --timeout 30m | tee build/notary.log
  grep -q 'status: Accepted' build/notary.log || { echo "Notarization was not accepted" >&2; exit 1; }
  xcrun stapler staple "$1"
}

if [ -n "$SIGN_IDENTITY" ]; then
  echo "==> Signing with $SIGN_IDENTITY (hardened runtime)"
  codesign --force --options runtime --timestamp --entitlements app/LidAgents.entitlements --sign "$SIGN_IDENTITY" "$APP"
else
  echo "==> Signing ad hoc (set SIGN_IDENTITY for a Developer ID build)"
  codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP"
if [ -n "$SIGN_IDENTITY" ]; then notarize "$APP"; fi

echo "==> Packaging"
COPYFILE_DISABLE=1 tar --no-mac-metadata -C build -czf dist/lid-agents.tar.gz "Lid Agents.app"

ditto "$APP" "build/dmg/Lid Agents.app"
ln -s /Applications build/dmg/Applications
hdiutil create -quiet -volname "Lid Agents" -srcfolder build/dmg -ov -format UDZO dist/LidAgents.dmg
if [ -n "$SIGN_IDENTITY" ]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" dist/LidAgents.dmg
  notarize dist/LidAgents.dmg
fi

for f in dist/*; do echo "==> $f ($(du -h "$f" | cut -f1))"; done

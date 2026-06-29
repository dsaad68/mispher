#!/usr/bin/env bash
# Package the Mispher macOS app for distribution outside the App Store:
# archive (Release, Developer ID signing) -> export -> notarize -> staple -> .dmg -> notarize+staple dmg.
# Outputs a notarized, stapled Mispher.app and Mispher.dmg under build/ (gitignored).
#
# One-time prerequisites:
#   1. A "Developer ID Application" certificate in your login keychain
#      (Xcode > Settings > Accounts > Manage Certificates). Confirm with:
#        security find-identity -v -p codesigning | grep "Developer ID Application"
#   2. Hardened Runtime enabled on the Mispher target (already set in the project).
#   3. Stored notarization credentials (an app-specific password from appleid.apple.com,
#      NOT your Apple ID password):
#        xcrun notarytool store-credentials mispher-notary \
#          --apple-id dsaad68@gmail.com --team-id 2WW2TG6GQG --password <app-specific-password>
#
# Usage: Scripts/package-mispher.sh [keychain-profile]   (default profile: mispher-notary)
set -euo pipefail

profile="${1:-mispher-notary}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
proj="$root/app/Mispher/Mispher.xcodeproj"
opts="$root/app/Mispher/ExportOptions.plist"
out="$root/build"
archive="$out/Mispher.xcarchive"
exportdir="$out/export"
app="$exportdir/Mispher.app"
zip="$out/Mispher.zip"
dmg="$out/Mispher.dmg"  # stable, unversioned name so releases/latest/download/Mispher.dmg is stable

rm -rf "$archive" "$exportdir" "$zip" "$dmg"
mkdir -p "$out"

echo "==> Archiving (Release, Developer ID signing)..."
xcodebuild -project "$proj" -scheme Mispher -configuration Release \
	-destination 'generic/platform=macOS' -archivePath "$archive" archive

echo "==> Exporting the signed .app..."
xcodebuild -exportArchive -archivePath "$archive" \
	-exportOptionsPlist "$opts" -exportPath "$exportdir"

echo "==> Zipping for the notary service..."
ditto -c -k --keepParent "$app" "$zip"

echo "==> Submitting to Apple's notary service (profile: $profile)..."
# --wait blocks until Apple returns Accepted/Invalid. On Invalid, read the log with:
#   xcrun notarytool log <submission-id> --keychain-profile "$profile"
xcrun notarytool submit "$zip" --keychain-profile "$profile" --wait

echo "==> Stapling the ticket to the .app..."
xcrun stapler staple "$app"

echo "==> Verifying the .app signature + Gatekeeper acceptance..."
codesign -dv --verbose=4 "$app" 2>&1 | grep -E "Authority|Identifier|Runtime|TeamIdentifier" || true
spctl -a -vvv --type exec "$app" || true

echo "==> Building $dmg (drag-to-Applications layout)..."
stage="$(mktemp -d)"
cp -R "$app" "$stage/"
ln -s /Applications "$stage/Applications"   # the familiar drag-install target
hdiutil create -volname Mispher -srcfolder "$stage" -ov -format ULFO "$dmg"
rm -rf "$stage"

echo "==> Notarizing + stapling the DMG (so the downloaded .dmg itself passes Gatekeeper)..."
xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait
xcrun stapler staple "$dmg"
spctl -a -vvv --type open --context context:primary-signature "$dmg" || true

echo
echo "Done:"
echo "  app -> $app"
echo "  dmg -> $dmg   (notarized + stapled; ready to attach to a GitHub Release)"

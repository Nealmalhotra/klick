#!/bin/zsh
# Builds a universal, Developer ID–signed, notarized and stapled Klick.dmg.
#
# One-time setup:
#   1. Xcode ▸ Settings ▸ Accounts: add the paid developer Apple ID, then
#      Manage Certificates ▸ + ▸ "Developer ID Application".
#   2. Store notarization credentials in the keychain (app-specific password
#      from account.apple.com ▸ Sign-In and Security ▸ App-Specific Passwords):
#        xcrun notarytool store-credentials klick-notary \
#          --apple-id <apple-id> --team-id <TEAMID> --password <app-specific-password>
#
# Usage: scripts/release.sh            → build/Klick.dmg
#        NOTARY_PROFILE=other scripts/release.sh
set -euo pipefail
cd "${0:A:h}/.."

PROFILE=${NOTARY_PROFILE:-klick-notary}
IDENTITY=${DEVELOPER_ID:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)}
[[ -n $IDENTITY ]] || { echo "No 'Developer ID Application' certificate in the keychain." >&2; exit 1; }
TEAM=${IDENTITY##*\(}; TEAM=${TEAM%\)}
echo "Signing as: $IDENTITY"

DERIVED=build/dd-release
APP=$DERIVED/Build/Products/Release/Klick.app
DMG=build/Klick.dmg

xcodegen generate --quiet
rm -rf $DERIVED
xcodebuild -project Klick.xcodeproj -scheme Klick -configuration Release \
  -derivedDataPath $DERIVED ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  -quiet build

codesign --verify --deep --strict --verbose=2 $APP
lipo -archs $APP/Contents/MacOS/Klick

STAGE=$(mktemp -d)
cp -R $APP $STAGE/
ln -s /Applications $STAGE/Applications
rm -f $DMG
hdiutil create -volname Klick -srcfolder $STAGE -fs HFS+ -format UDZO -ov $DMG >/dev/null
rm -rf $STAGE
codesign --sign "$IDENTITY" --timestamp $DMG

xcrun notarytool submit $DMG --keychain-profile "$PROFILE" --wait
xcrun stapler staple $DMG
spctl --assess --type open --context context:primary-signature --verbose=2 $DMG
echo "Done: $DMG"

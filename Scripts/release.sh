#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
: "${MILK_TEAM_ID:?Set MILK_TEAM_ID}"
: "${MILK_SIGN_IDENTITY:?Set MILK_SIGN_IDENTITY to a Developer ID Application identity}"
: "${MILK_NOTARY_PROFILE:?Set MILK_NOTARY_PROFILE to a Keychain notarytool profile}"
: "${MILK_APPCAST_URL:?Set the HTTPS Sparkle feed URL}"
: "${MILK_UPDATE_PUBLIC_KEY:?Set the Sparkle EdDSA public key}"
xcodebuild -project Milk.xcodeproj -scheme Milk -configuration Release -archivePath build/Milk.xcarchive archive DEVELOPMENT_TEAM="$MILK_TEAM_ID" CODE_SIGN_IDENTITY="$MILK_SIGN_IDENTITY" MILK_APPCAST_URL="$MILK_APPCAST_URL" MILK_UPDATE_PUBLIC_KEY="$MILK_UPDATE_PUBLIC_KEY"
xcodebuild -exportArchive -archivePath build/Milk.xcarchive -exportPath build/release -exportOptionsPlist Configuration/ExportOptions.plist DEVELOPMENT_TEAM="$MILK_TEAM_ID"
ditto -c -k --sequesterRsrc --keepParent build/release/Milk.app build/release/Milk.zip
xcrun notarytool submit build/release/Milk.zip --keychain-profile "$MILK_NOTARY_PROFILE" --wait
xcrun stapler staple build/release/Milk.app
ditto -c -k --sequesterRsrc --keepParent build/release/Milk.app build/release/Milk.zip
codesign --verify --deep --strict --verbose=2 build/release/Milk.app
spctl --assess --type execute --verbose=2 build/release/Milk.app
echo 'Create the Sparkle-signed appcast with generate_appcast before publishing this archive.'

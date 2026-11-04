#!/bin/zsh
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
sdk="${MILK_EXTENSION_SDK:-}"
if [[ -z "$sdk" ]]; then
  for app in /Applications/Milk.app "$HOME/Applications/Milk.app"; do
    if [[ -d "$app/Contents/Resources/ExtensionSDK" ]]; then
      sdk="$app/Contents/Resources/ExtensionSDK"
      break
    fi
  done
fi

[[ -n "$sdk" && -f "$sdk/libMilkExtensionKit.dylib" ]] || {
  print -u2 "MilkExtensionKit SDK missing. Set MILK_EXTENSION_SDK to the ExtensionSDK directory."
  exit 1
}
modules="$sdk"
[[ -d "$sdk/Modules" ]] && modules="$sdk/Modules"

bundle="$here/dist/MilkCalculator.milkext"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$here/manifest.json" "$bundle/Contents/Resources/manifest.json"

python3 - "$bundle/Contents/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], "wb") as handle:
    plistlib.dump({
        "CFBundleIdentifier": "dev.thatmingo.milk-calculator",
        "CFBundleName": "Calculator",
        "CFBundlePackageType": "BNDL",
        "CFBundleExecutable": "MilkCalculator",
        "NSPrincipalClass": "MilkCalculator.MilkCalculator",
        "CFBundleShortVersionString": "1.0.0",
    }, handle)
PY

xcrun swiftc -swift-version 5 -target arm64-apple-macosx26.0 \
  -parse-as-library -emit-library -Xlinker -bundle \
  -module-name MilkCalculator -I "$modules" -L "$sdk" \
  -lMilkExtensionKit "$here/Sources/MilkCalculator.swift" \
  -o "$bundle/Contents/MacOS/MilkCalculator"

codesign --force --sign - "$bundle"
codesign --verify --verbose=2 "$bundle"
print "Built: $bundle"

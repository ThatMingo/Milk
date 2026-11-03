#!/bin/zsh
set -euo pipefail
here="${0:A:h}"
project="${here:h:h:h}"
sdk="${MILK_EXTENSION_SDK:-$project/.build/arm64-apple-macosx/debug}"
sdkModules="$sdk/Modules"
[[ -d "$sdkModules" ]] || sdkModules="$sdk"
[[ -f "$sdk/libMilkExtensionKit.dylib" ]] || { print -u2 "MilkExtensionKit SDK not found at $sdk"; exit 1; }
out="${1:-$here/build/oMLX Stats.milkext}"
rm -rf "$out"
mkdir -p "$out/Contents/MacOS" "$out/Contents/Resources"
cp "$here/manifest.json" "$out/Contents/Resources/manifest.json"
python3 - "$out" <<'PY'
import json,pathlib,plistlib,sys
root=pathlib.Path(sys.argv[1])
m=json.loads((root/'Contents/Resources/manifest.json').read_text())
(root/'Contents/Info.plist').write_bytes(plistlib.dumps({
'CFBundleIdentifier':m['id'],'CFBundleName':m['name'],'CFBundlePackageType':'BNDL',
'CFBundleExecutable':m['executable'],'NSPrincipalClass':m['principalClass'],
'CFBundleShortVersionString':m['version']}))
PY
xcrun swiftc -swift-version 5 -target arm64-apple-macosx26.0 -parse-as-library -emit-library -Xlinker -bundle \
  -module-name OMLXStatsTest -I "$sdkModules" -L "$sdk" -lMilkExtensionKit \
  "$here/OMLXStatsTest.swift" -o "$out/Contents/MacOS/OMLXStatsTest"
codesign --force --sign - "$out"
print "$out"

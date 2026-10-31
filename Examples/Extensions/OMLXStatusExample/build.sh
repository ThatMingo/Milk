#!/bin/zsh
set -euo pipefail
example="${0:A:h}"
project="${example:h:h:h}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="$project/.build/clang-cache"
# SDK may also be supplied from Milk.app/Contents/Resources/ExtensionSDK by external authors.
sdk="${MILK_EXTENSION_SDK:-$project/.build/arm64-apple-macosx/debug}"
sdkModules="$sdk/Modules"
[[ -d "$sdkModules" ]] || sdkModules="$sdk"
[[ -f "$sdk/libMilkExtensionKit.dylib" ]] || { print -u2 "Build Milk first, or set MILK_EXTENSION_SDK to its SDK directory."; exit 1; }
destination="${1:-$example/build/OMLXStatusExample.milkext}"
mkdir -p "$destination/Contents/MacOS" "$destination/Contents/Resources"
rm -f "$destination/manifest.json"
cp "$example/manifest.json" "$destination/Contents/Resources/manifest.json"
# Build update fixtures by supplying MILK_EXAMPLE_VERSION, without editing source/manifest.
python3 - "$destination" <<'PY'
import json,os,pathlib,plistlib,sys
root=pathlib.Path(sys.argv[1]); path=root/'Contents/Resources/manifest.json'; manifest=json.loads(path.read_text())
manifest['version']=os.environ.get('MILK_EXAMPLE_VERSION',manifest['version'])
path.write_text(json.dumps(manifest,indent=2)+'\n')
(root/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':manifest['id'],'CFBundleName':manifest['name'],'CFBundlePackageType':'BNDL','CFBundleExecutable':manifest['executable'],'NSPrincipalClass':manifest['principalClass'],'CFBundleShortVersionString':manifest['version']}))
PY
xcrun swiftc -swift-version 5 -target arm64-apple-macosx26.0 -parse-as-library -emit-library -Xlinker -bundle -module-name OMLXStatusExample -I "$sdkModules" -L "$sdk" -lMilkExtensionKit "$example/OMLXStatusExample.swift" -o "$destination/Contents/MacOS/OMLXStatusExample"
# No SDK is embedded in the extension: dyld uses the host's single shared SDK.
codesign --force --sign - "$destination"
print "$destination"

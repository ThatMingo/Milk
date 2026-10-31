#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
[[ $(uname -m) == arm64 ]] || { print -u2 "Milk targets Apple Silicon."; exit 1; }
swift build --cache-path "$PWD/.build/cache" "$@"
mkdir -p output
staging=$(mktemp -d "$PWD/output/.Milk-build-XXXXXX")
trap 'rm -rf "$staging"' EXIT
app="$staging/Milk.app"
resources="$app/Contents/Resources"
mkdir -p "$app/Contents/MacOS" "$resources"
binary_directory=$(swift build --show-bin-path "$@")
cp "$binary_directory/Milk" "$app/Contents/MacOS/Milk"
mkdir -p "$app/Contents/Frameworks" "$resources/ExtensionSDK/Modules/MilkExtensionKit.swiftmodule"
cp "$binary_directory/libMilkExtensionKit.dylib" "$app/Contents/Frameworks/"
install_name_tool -add_rpath '@executable_path/../Frameworks' "$app/Contents/MacOS/Milk"
# Distributable SDK metadata/resources; extensions link the host library dynamically.
cp "$binary_directory"/Modules/MilkExtensionKit*.swiftinterface "$resources/ExtensionSDK/Modules/MilkExtensionKit.swiftmodule/"
cp "$binary_directory/Modules/MilkExtensionKit.swiftinterface" "$resources/ExtensionSDK/Modules/MilkExtensionKit.swiftmodule/arm64-apple-macos.swiftinterface"
cp "$binary_directory/Modules/MilkExtensionKit.swiftdoc" "$resources/ExtensionSDK/Modules/MilkExtensionKit.swiftmodule/arm64-apple-macos.swiftdoc"
cp "$binary_directory/libMilkExtensionKit.dylib" "$resources/ExtensionSDK/"
cp Packages/MilkExtensionKit/Sources/MilkExtensionKit/*.swift "$resources/ExtensionSDK/"
# The separately built example is deliberately absent from Milk.app.
# Milk ships clean. Only the Milk-authored integration and notice metadata are
# resources; Pi binaries, tools, assets and manifests are never staged.
python3 scripts/stage-app-resources.py "$resources"
identity="${CODESIGN_IDENTITY:--}"
# Sign the shared SDK before sealing the application.
codesign --force --options runtime --sign "$identity" "$app/Contents/Frameworks/libMilkExtensionKit.dylib"
codesign --force --options runtime --sign "$identity" "$resources/ExtensionSDK/libMilkExtensionKit.dylib"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Milk</string>
<key>CFBundleIdentifier</key><string>dev.milk.phase1</string>
<key>CFBundleName</key><string>Milk</string>
<key>CFBundleDisplayName</key><string>Milk</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.7.0</string>
<key>CFBundleVersion</key><string>7</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>UTExportedTypeDeclarations</key><array><dict><key>UTTypeIdentifier</key><string>dev.milk.extension</string><key>UTTypeConformsTo</key><array><string>com.apple.bundle</string></array><key>UTTypeDescription</key><string>Milk Extension</string><key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>milkext</string></array></dict></dict></array>
<key>CFBundleDocumentTypes</key><array><dict><key>CFBundleTypeName</key><string>Milk Extension</string><key>CFBundleTypeRole</key><string>Viewer</string><key>LSItemContentTypes</key><array><string>dev.milk.extension</string></array><key>LSTypeIsPackage</key><true/></dict></array>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
codesign --force --options runtime --entitlements scripts/milk-app.entitlements --sign "$identity" "$app"
codesign --verify --deep --strict "$app"

rm -rf "$PWD/output/Milk.app"
mv "$app" "$PWD/output/Milk.app"

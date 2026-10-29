#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project Milk.xcodeproj -scheme Milk -configuration Debug -derivedDataPath build/DerivedData -skipPackagePluginValidation build

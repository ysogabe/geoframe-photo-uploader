#!/bin/zsh
# SwiftPM でビルドし、PhotoKit 権限を取れるよう最小 .app に包んで ad-hoc 署名する。
set -euo pipefail
cd "${0:A:h}/.."
swift build -c release
APP=.build/MD5Precheck.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/MD5Precheck "$APP/Contents/MacOS/MD5Precheck"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "built $PWD/$APP"

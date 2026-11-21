#!/bin/zsh
# SwiftPM で release ビルドし、.build/GeoFrameUploader.app に包んで署名する。
# 署名 ID: 環境変数 SIGN_IDENTITY > "Apple Development" 証明書（TCC の許可が再ビルドで消えない）> ad-hoc "-"
set -euo pipefail
cd "${0:A:h}/.."
swift build -c release
BIN="$(swift build -c release --show-bin-path)/GeoFrameUploader"
APP=.build/GeoFrameUploader.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/GeoFrameUploader"
cp Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  # 証明書の SHA-1 ハッシュで指定（同名証明書が複数あっても曖昧にならない）
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep '"Apple Development' | head -n 1 | awk '{print $2}' || true)"
fi
[[ -z "$IDENTITY" ]] && IDENTITY="-"

if [[ "$IDENTITY" == "-" ]]; then
  echo "signing ad-hoc (-)"
  codesign --force --sign - --identifier dev.local.geoframe.uploader "$APP"
else
  NAME="$(security find-identity -v -p codesigning 2>/dev/null | grep "$IDENTITY" | sed -E 's/.*"(.*)".*/\1/' | head -n 1 || true)"
  echo "signing with identity ${NAME:-$IDENTITY}"
  codesign --force --sign "$IDENTITY" --identifier dev.local.geoframe.uploader --timestamp=none "$APP"
fi
codesign --verify --strict --verbose=1 "$APP"
echo "built $PWD/$APP"

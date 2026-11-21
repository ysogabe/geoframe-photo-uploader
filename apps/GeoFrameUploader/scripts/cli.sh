#!/bin/zsh
# 使い方: scripts/cli.sh <status|scan|auth|upload|signout> [追加引数...]
# .app 経由で起動する（写真ライブラリの TCC 許可は .app のバンドル ID / 署名に紐づくため）。
# 結果 JSON は out/<sub>.json、ログ（stdout/stderr）は out/<sub>.log
set -euo pipefail
CALLER_PWD="$PWD"
cd "${0:A:h}/.."
if [[ $# -lt 1 ]]; then
  echo "usage: $0 <status|scan|auth|upload|signout> [args...]" >&2
  exit 2
fi
SUB=$1; shift
case "$SUB" in
  status|scan|auth|upload|signout) ;;
  *) echo "usage: $0 <status|scan|auth|upload|signout> [args...]" >&2; exit 2 ;;
esac
# open で起動したアプリの cwd は / になるため、ファイルパス引数は呼び出し元基準の絶対パスにする
ARGS=()
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--remote-md5-file" && $# -ge 2 ]]; then
    P="$2"
    [[ "$P" != /* ]] && P="$CALLER_PWD/$P"
    ARGS+=("$1" "$P"); shift 2
  else
    ARGS+=("$1"); shift
  fi
done
APP="$PWD/.build/GeoFrameUploader.app"
if [[ ! -d "$APP" ]]; then
  echo "$APP がありません。先に scripts/build-app.sh を実行してください" >&2
  exit 2
fi
mkdir -p out
OUT="$PWD/out/$SUB.json"
LOG="$PWD/out/$SUB.log"
rm -f "$OUT" "$LOG"
set +e
open -W -n --stdout "$LOG" --stderr "$LOG" "$APP" --args --cli "$SUB" --out "$OUT" "${ARGS[@]}"
RC=$?
set -e
[[ -f "$LOG" ]] && cat "$LOG"
echo "---"
if [[ -f "$OUT" ]]; then
  cat "$OUT"
else
  echo "結果 JSON が生成されませんでした: $OUT" >&2
  exit 1
fi
exit $RC

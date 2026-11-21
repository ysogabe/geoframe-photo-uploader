#!/bin/zsh
# 使い方: scripts/run.sh <mode: status|run|selftest> [追加引数...]
# 結果 JSON は out/result-<mode>.json、ログは out/<mode>.log
set -euo pipefail
cd "${0:A:h}/.."
MODE=$1; shift
mkdir -p out
OUT="$PWD/out/result-$MODE.json"
LOG="$PWD/out/$MODE.log"
rm -f "$OUT"
open -W -n --stdout "$LOG" --stderr "$LOG" .build/MD5Precheck.app --args --out "$OUT" --mode "$MODE" "$@"
cat "$LOG"; echo "---"; cat "$OUT"

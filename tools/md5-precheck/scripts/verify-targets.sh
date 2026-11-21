#!/bin/zsh
# 指定した写真の MD5 を事前確認する。撮影日時はローカルタイムとして解釈し、±1日で検索する。
# 使い方: verify-targets.sh 'FILENAME|YYYY-MM-DD HH:MM|md5' [...]
# 例:     verify-targets.sh 'IMG_0001.HEIC|2026-04-19 12:00|0123456789abcdef0123456789abcdef'
if (( $# == 0 )); then
  print -u2 "usage: ${0:t} 'FILENAME|YYYY-MM-DD HH:MM|md5' [...]"
  print -u2 "example: ${0:t} 'IMG_0001.HEIC|2026-04-19 12:00|0123456789abcdef0123456789abcdef'"
  exit 64
fi
args=()
for t in "$@"; do
  args+=(--target "$t")
done
exec "${0:A:h}/run.sh" run "${args[@]}"

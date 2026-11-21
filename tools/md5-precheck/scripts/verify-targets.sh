#!/bin/zsh
# 今回の検証対象3枚（撮影日時はローカルタイムとして解釈、±1日で検索）
exec "${0:A:h}/run.sh" run \
  --target 'IMG_1254.HEIC|2026-11-01 12:50|ff4362a04595e00ea3db6d1ee3ea1314' \
  --target 'IMG_1252.HEIC|2026-11-01 12:02|e34f709a83d49dc4388267d00d3bbdf4' \
  --target 'IMG_1167.HEIC|2026-09-25 16:52|1a43b58c6cb09045221f21b99226f057'

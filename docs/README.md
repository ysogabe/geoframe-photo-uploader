# GeoFrame Uploader — ドキュメント

アプリの概要は [README](../README.md) と [紹介ページ（LP）](https://ysogabe.github.io/geoframe-photo-uploader/) にあります。ここでは、導入手順・使い方・技術設計の詳細をまとめています。

## 使い方と準備

| 文書 | 内容 |
|---|---|
| [使い方と運用ガイド](USAGE.md) | ビルド、署名、GUI / CLI の操作手順、`config.json` / `records.jsonl` / `item-cache.json` の扱いとリセット方法 |
| [Google Cloud 側の準備](google-cloud-setup.md) | 自分の Google Cloud プロジェクトで「デスクトップ アプリ」用 OAuth クライアントを作成して配置する手順（初回のみ） |

## 設計と技術判断

| 文書 | 内容 |
|---|---|
| [技術設計書](DESIGN.md) | `UploaderCore` / SwiftUI / CLI のモジュール構成、PhotoKit 原本抽出、Drive 再開可能アップロード、二重 MD5 検証、自動重複確認とローカルキャッシュの仕組み |
| [Google ドライブ接続方式の評価と決定](drive-connection-decision.md) | ネイティブ OAuth + Drive API v3 と `rclone` の比較、スコープ選択（`drive`）、公開ステータスとトークン寿命の判断記録 |

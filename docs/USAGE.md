# 使い方と運用ガイド

## 動作要件

- macOS 14（Sonoma）以降
- Xcode または Command Line Tools（Swift 5.9+）
- 写真ライブラリへのアクセス（GUI / CLI 初回実行時に「フルアクセス」を許可）
- 自分用の Google Cloud OAuth クライアント（[Google Cloud 側の準備](google-cloud-setup.md) を参照）

## ビルドと署名

```sh
cd apps/GeoFrameUploader
swift build
swift test
scripts/build-app.sh
```

`scripts/build-app.sh` は release ビルドを行い、`Resources/AppIcon.icon` を `xcrun actool` でコンパイルして `.build/GeoFrameUploader.app` を組み立て・署名します。署名 ID は次の優先順で選ばれます。

1. 環境変数 `SIGN_IDENTITY`（`-` を指定すると ad-hoc 署名）
2. キーチェーン内の `"Apple Development"` 証明書
3. ad-hoc（`-`）

`"Apple Development"` 証明書で署名しておくと、再ビルドしても macOS の TCC（写真ライブラリ許可）やキーチェーンのアクセス許可が維持されます。

## 初回セットアップ

1. Google ドライブのマイドライブ直下に送信先フォルダ（既定名 `GeoFrame`）を用意します。
2. [Google Cloud 側の準備](google-cloud-setup.md) に従って `oauth-client.json` を作成し、以下に配置します。

```sh
mkdir -p ~/Library/Application\ Support/GeoFrameUploader
chmod 700 ~/Library/Application\ Support/GeoFrameUploader
mv ~/Downloads/client_secret_*.json ~/Library/Application\ Support/GeoFrameUploader/oauth-client.json
chmod 600 ~/Library/Application\ Support/GeoFrameUploader/oauth-client.json
```

3. アプリを起動し、ヘッダーの **「Google に接続」** からブラウザでサインインします（リフレッシュトークンは macOS キーチェーンのサービス `dev.local.geoframe.uploader` に保存されます）。
4. 写真ライブラリのアクセス許可を求められたら **「フルアクセス」** を許可します（限定アクセスでは原本の正確な取得・一覧ができないため、システム設定への案内が表示されます）。

## GUI の操作

### 1. 日付で読み込む
- **単日** または **期間** を選び、**「読み込む」**（`⌘R`）を押します。
- 撮影日の判定は Mac のローカルタイムゾーンの暦日（`00:00:00` 〜 翌日 `00:00:00` 未満）です。
- 読み込み直後に、通信なしで `item-cache.json` の前回結果（`送信済み` / `重複（Drive に既存）` / `確認済み・未送信` / `前回失敗`）が各写真にバッジ表示されます。

### 2. 送る写真を選ぶ
- **対象形式**（JPEG / PNG / HEIC / HEIF / TIFF）の写真だけ選択できます。DNG・RAW・動画・GIF などは薄く表示され、対象外の理由が出ます。
- **「すべて選択」** は、前回までに送信済みまたは Drive に既存とみなせる写真を選びません（必要な場合は個別に手動選択できます）。
- **「送信済み・重複を隠す」** をオンにすると、処理済みの写真を一覧から隠して未送信分だけに集中できます。

### 3. 重複を確認する（任意・自動 / 手動）
- **「選んだら自動で重複確認」**（設定は `UserDefaults` に保存、既定オフ）をオンにすると、写真を選ぶたびに新しく選んだ写真だけを裏で 1 枚ずつ照合します（約 0.3 秒待ってから開始）。Drive に既存、または同じ選択内で先に選んだ写真と同一内容の場合は自動で選択から外し、上部バナーで通知します。
- 手動でまとめて確認したいときは **「重複を確認」** を押します。
- いずれも原本 MD5 がキャッシュにあれば iCloud からの再取得・書き出しを省略します。重複確認は送信を行いません。

### 4. 送信する
- **「送信」** を押すと送信を開始します（選択が 20 件を超える場合は確認ダイアログが出ます）。
- 送信中は一覧が暗くなり、中央にモーダルパネルが表示されます。現在処理中の写真の大きなサムネイル、枚数（`n / N 枚目（残り k 枚）`）、処理段階（原本取得 / 重複確認 / 送信 % / MD5 照合）、MB 進捗、累計件数、次に送る最大 5 枚のサムネイルが確認できます。
- **「中止」**（または `Esc` キー）で処理中の 1 枚を中断して止めることができます。
- 完了後は同じパネルに結果サマリー（送信済み / 重複スキップ / 失敗 / 未処理）と `records.jsonl` を Finder で開くボタンが表示されます。

## CLI での利用

写真ライブラリの権限は `.app` バンドルに紐づくため、CLI は必ず `scripts/cli.sh` 経由で実行します。結果 JSON は `apps/GeoFrameUploader/out/<サブコマンド>.json`、ログは `out/<サブコマンド>.log` に出力されます（JSON は位置情報を含むため権限 `0600` で保存されます）。

```sh
cd apps/GeoFrameUploader

# 状態確認（権限・oauth-client.json・キーチェーン・キャッシュ件数。ダイアログは出さない）
scripts/cli.sh status

# 指定日の写真をスキャン（--hash で MD5/SHA-256 計算、サインイン済みなら重複判定も付与）
scripts/cli.sh scan --from 2026-04-19 [--to 2026-04-20] [--hash [--no-cache]] [--remote-md5-file path.json]

# ブラウザで Google にサインイン
scripts/cli.sh auth

# 指定 ID または先頭 N 件を送信（--max 既定 3 件を超えると実行せずエラー）
scripts/cli.sh upload --from 2026-04-19 [--to ...] (--ids ID1,ID2 | --limit N) [--max N]

# サインアウト（Keychain 削除 + revoke）
scripts/cli.sh signout
```

## 設定ファイルとデータ（`~/Library/Application Support/GeoFrameUploader/`）

ディレクトリは権限 `0700`、各データファイルは `0600` で作成されます。

| ファイル | 役割 |
|---|---|
| `oauth-client.json` | Google Cloud Console から取得した「デスクトップ アプリ」用 OAuth クライアント JSON（git 管理外） |
| `config.json` | 送信先設定（`{"folderId": "...", "folderName": "GeoFrame"}`）。`folderId` 省略時はマイドライブ直下の `folderName` を解決して保存（0 件や複数件のときはエラー） |
| `records.jsonl` | 1 実行・1 写真ごとの追記型送信ログ（`localIdentifier`, ファイル名, MD5, SHA-256, 撮影日時・EXIF・タイムゾーン, 位置情報, 解像度, バースト ID, お気に入り, 結果, Drive fileId, 検証結果など） |
| `item-cache.json` | 写真ごとの MD5/SHA-256 と前回結果のキャッシュ。重複判定の正は常に Drive の `files.list` であり、ここは再書き出しの省略と一覧の初期バッジ表示に使用 |

### キャッシュのリセット
アプリを終了した状態で `item-cache.json` を削除すると、次回起動時に `records.jsonl` から自動で再構築されます。過去の表示履歴自体を初期化したい場合は、`records.jsonl` も別の場所へ退避してください。

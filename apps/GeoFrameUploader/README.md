# GeoFrame Uploader

写真アプリ（PhotoKit）から日付で選んだ写真の**原本バイト列をそのまま**、Google ドライブのマイドライブ直下フォルダ「GeoFrame」へ送る macOS アプリです。

- 送るのは `PHAssetResource` の `.photo` リソースだけです。再エンコードはせず、EXIF も元のまま残ります。編集済みの写真でも `.fullSizePhoto` ではなく原本を送ります。Live Photo は静止画だけで、`.pairedVideo` は送りません。
- 重複判定: 原本バイトの MD5 と、フォルダ内ファイルの Drive `md5Checksum` を照合します。
- 送れる形式は JPEG / PNG / HEIC / HEIF / TIFF です。DNG・RAW・動画・GIF などは「対象外」として理由を表示します。
- Drive には常に新規ファイルとして作成します。既存ファイルの上書き・更新・改名・削除はしません。ファイル名は原本ファイル名のままです。
- 送信後に検証します。まずアップロード応答の `md5Checksum` を照合し、次に新しく取り直した `files.list` で、ファイル ID と md5 が一致することを確認します。両方が通ったものだけを `sent` とします。

## 構成

```
apps/GeoFrameUploader/
  Package.swift                 SwiftPM（macOS 14+、外部依存なし）
  Info.plist                    バンドル ID dev.local.geoframe.uploader
  Sources/UploaderCore/         ロジック一式（SwiftUI 非依存）
    AppPaths.swift              設定ディレクトリ / oauth-client.json / config.json
    Eligibility.swift           形式判定（純粋関数）と MIME 対応
    PhotoItem.swift             アセットの値型・日付範囲
    PhotoLibrary.swift          PhotoKit の認可・列挙・サムネイル
    OriginalExporter.swift      .photo の一時ファイル書き出し + MD5/SHA-256（1 パス）+ EXIF 日時
    OAuthPrimitives.swift       PKCE / 認可 URL / コールバック検証 / Keychain
    LoopbackServer.swift        127.0.0.1 限定のループバック受信（NWListener）
    GoogleAuth.swift            OAuth（インストール型アプリ + PKCE）、トークン更新、サインアウト
    DriveClient.swift           files.list（ページング）/ フォルダ解決 / 再開可能アップロード
    UploadPlanner.swift         重複判定（純粋関数）/ --remote-md5-file の読み込み
    UploadCoordinator.swift     逐次アップロード・検証・イベント通知
    RecordStore.swift           records.jsonl（0600）
    UploaderService.swift       UI と CLI が共有する窓口（actor）
    DuplicatePrecheck.swift     送信前の重複確認（書き出し + MD5 + 照合のみ、送信しない）
    HTTPSupport.swift           伏字化（トークン類の除去）・フォームエンコード
  Sources/GeoFrameUploader/     実行ファイル（--cli なら CLI、無ければ SwiftUI）
    AppModel.swift              @MainActor の状態管理（UploaderService を保持）
    ThumbnailCache.swift        サムネイルのメモリキャッシュ
    Views/                      ヘッダー / 日付指定 / グリッド / セル / 操作バー / 結果 / バナー
  Tests/UploaderCoreTests/      XCTest（URLProtocol スタブで Drive / OAuth を検証）
  scripts/build-app.sh          release ビルド → .app 組み立て → 署名
  scripts/cli.sh                .app 経由で CLI を実行
```

UI を実装するときは `UploaderService` を使います。`status()`、`loadItems(fromDay:toDay:)`、`signIn()`、`resolveFolderId()`、`remoteIndex()`、`upload(items:maxItemsPerRun:onEvent:)`、`uploadStream(...)`、`precheckDuplicates(items:onProgress:)`、`thumbnail(...)` が用意されています。`onEvent` は任意のスレッドから呼ばれるので、UI 側で MainActor に移してください。

## UI

1. **ヘッダー**: 写真ライブラリの許可状態（未確認 / 許可済み / 拒否 / 限定）。フルアクセスでなければ許可ボタン、拒否・限定ならシステム設定（プライバシー > 写真）を開くボタンを出します。Google は oauth-client.json 未配置（置き場所と `docs/google-cloud-setup.md` を案内）/ 未接続（「Google に接続」、接続中はキャンセル可）/ 接続済み（「ログアウト」と送信先フォルダ名・ID）を表示します。状態はアプリがアクティブになるたびに再確認します（ダイアログは出しません）。
2. **日付指定**: 単日 / 期間を選び「読み込む」（⌘R）。全 N 件 / 対象 M 件 / 対象外 K 件を表示します。
3. **グリッド**: サムネイル、ファイル名、撮影時刻（HH:mm）、形式、お気に入り・バースト・Live・位置情報の印。対象外は薄く表示し、理由を出して選択できません。クリックまたはチェックで選択、「すべて選択」「選択解除」。
4. **重複を確認**（任意）: 選択した写真の原本 MD5 を計算して Drive と照合するだけで、送信はしません。結果は目安で、送信時にも改めて照合します。
5. **送信**: 選択が 20 件を超えると件数を示す確認ダイアログを出し、承認後にだけ送ります（`maxItemsPerRun` = 選択件数）。送信は 1 件ずつで、全体の進捗（i/N）と各セルの段階（原本を取得中 / 重複を確認中 / 送信中 xx% / 検証中）を表示します。「中止」（Esc）で止められます。
6. **結果**: セルごとに 送信済み / 重複でスキップ（ツールチップに Drive fileId か先行写真）/ 対象外 / 失敗（エラー文）/ 中止。実行後は件数のまとめ、失敗一覧、records.jsonl の場所と「Finder で表示」を出します。実行後は再送を防ぐため選択を解除します。
7. エラーはウィンドウ上部のバナーで表示します（モーダルにしません）。

## ビルドとテスト

```sh
cd apps/GeoFrameUploader
swift build
swift test
scripts/build-app.sh       # .build/GeoFrameUploader.app を作って署名
```

署名に使う ID は次の順で決まります。

1. 環境変数 `SIGN_IDENTITY`（`-` を指定すると ad-hoc）
2. キーチェーン内の「Apple Development」証明書
3. ad-hoc

「Apple Development」で署名しておくと、再ビルドしても写真ライブラリの許可や Keychain のアクセス許可が維持されます。

## 設定ファイル

置き場所は `~/Library/Application Support/GeoFrameUploader/` です（権限 0700）。

| ファイル | 内容 |
| --- | --- |
| `oauth-client.json` | Google Cloud Console でダウンロードした「デスクトップ アプリ」用 OAuth クライアント JSON（`{"installed":{...}}`）。**git に入れないこと** |
| `config.json` | `{"folderId": "...", "folderName": "GeoFrame"}`。`folderId` を省略すると、マイドライブ直下の `folderName` を検索して保存します。0 件や複数件のときは推測せずエラーにします |
| `records.jsonl` | 送信記録。1 実行・1 写真ごとに 1 行の JSON です（0600） |

- リフレッシュトークンは Keychain だけに保存します（サービス `dev.local.geoframe.uploader`、アカウント `google-refresh-token`、ThisDeviceOnly）。
- アクセストークンはメモリ上にだけ保持します。
- トークン・認可コード・シークレットはログに出しません。

要求スコープは `GoogleAuth.scopes`（`https://www.googleapis.com/auth/drive`）です。

## CLI

必ず `.app` 経由で起動します。写真ライブラリの許可は `.app` に紐づくためです。結果 JSON は `out/<サブコマンド>.json` に、ログは `out/<サブコマンド>.log` に出力されます。

```sh
scripts/cli.sh status
scripts/cli.sh scan --from 2026-11-01 [--to 2026-11-02] [--hash] [--remote-md5-file path.json]
scripts/cli.sh auth
scripts/cli.sh upload --from 2026-11-01 [--to ...] (--ids ID1,ID2 | --limit N) [--max N]
scripts/cli.sh signout
```

各サブコマンドの動作:

- `status`: 写真ライブラリの許可状態、oauth-client.json の有無と妥当性、Keychain のトークンの有無（中身は読みません）、config を表示します。ダイアログは一切出しません。
- `scan`: 期間内（ローカル時刻の暦日、`--to` 省略時は 1 日だけ）のアセットを、対象/対象外とその理由つきで一覧にします。
  - `--hash` を付けると、対象の原本を書き出して MD5 / SHA-256 を計算します（一時ファイルはすぐ削除）。
  - `--remote-md5-file`（md5 文字列の配列、または `rclone lsjson --hash` の出力）を渡すか Drive にサインイン済みのときは、重複判定（`plan`）も付けます。
  - アップロードは決してしません。初回実行時は写真ライブラリの許可ダイアログが出ます。
- `auth`: ブラウザで Google にサインインし、付与されたスコープを表示します（トークンは表示しません）。
- `upload`: 選んだ写真を実際に送ります。
  - `--ids` を指定するとその ID の写真を、`--limit N` を指定すると対象のうち先頭 N 件を送ります。
  - 選択が `--max`（既定 3）を超えると何もせずエラーにします。
  - 結果は records.jsonl にも追記されます。
- `signout`: Keychain のトークンを削除し、ベストエフォートで revoke します。

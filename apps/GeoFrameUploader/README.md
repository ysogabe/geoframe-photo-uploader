# GeoFrame Uploader

写真アプリ（PhotoKit）から日付で選んだ写真の**原本バイト列をそのまま**、Google ドライブのマイドライブ直下フォルダ「GeoFrame」へ送る macOS アプリです。

- 送るのは `PHAssetResource` の `.photo` リソースだけです。再エンコードはせず、EXIF も元のまま残ります。編集済みの写真でも `.fullSizePhoto` ではなく原本を送ります。Live Photo は静止画だけで、`.pairedVideo` は送りません。
- 重複判定: 原本バイトの MD5 と、フォルダ内ファイルの Drive `md5Checksum` を照合します。
- 送れる形式は JPEG / PNG / HEIC / HEIF / TIFF です。DNG・RAW・動画・GIF などは「対象外」として理由を表示します。
- Drive には常に新規ファイルとして作成します。既存ファイルの上書き・更新・改名・削除はしません。ファイル名は原本ファイル名のままです。
- 送信後に検証します。まずアップロード応答の `md5Checksum` を照合し、次に新しく取り直した `files.list` で、ファイル ID と md5 が一致することを確認します。両方が通ったものだけを `sent` とします。
  - アップロードが終わった後の照合中に中止したときは、照合を中止から最大 10 秒まで続けます（通れば `sent`）。終わらなかったときは `failed`（「アップロード済み（応答の md5 は一致）・中止のため一覧での照合は未完了」）とし、Drive fileId と md5 を記録とキャッシュに残します。再送はせず、次の重複確認・送信で Drive 一覧と照合すると「重複（Drive に既存）」になります。

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
    ResultCache.swift           item-cache.json（写真ごとの MD5 と前回の結果、0600）
    UploaderService.swift       UI と CLI が共有する窓口（actor）
    DuplicatePrecheck.swift     送信前の重複確認（MD5 はキャッシュ優先、照合のみ、送信しない）
    HTTPSupport.swift           伏字化（トークン類の除去）・フォームエンコード
  Sources/GeoFrameUploader/     実行ファイル（--cli なら CLI、無ければ SwiftUI）
    AppModel.swift              @MainActor の状態管理（UploaderService を保持）
    ThumbnailCache.swift        サムネイルのメモリキャッシュ
    Views/                      ヘッダー / 日付指定 / グリッド / セル / 操作バー / 結果 / バナー
  Tests/UploaderCoreTests/      XCTest（URLProtocol スタブで Drive / OAuth を検証）
  scripts/build-app.sh          release ビルド → .app 組み立て → 署名
  scripts/cli.sh                .app 経由で CLI を実行
```

UI を実装するときは `UploaderService` を使います。`status()`、`loadItems(fromDay:toDay:)`、`signIn()`、`resolveFolderId()`、`remoteIndex()`、`upload(items:maxItemsPerRun:onEvent:)`、`uploadStream(...)`、`precheckDuplicates(items:onProgress:)`、`autoPrecheck(item:priorSelected:)`、`sessionRemoteIndex()`、`cachedEntries(for:)`、`resultCache()`、`thumbnail(...)` が用意されています。`onEvent` は任意のスレッドから呼ばれるので、UI 側で MainActor に移してください。

## UI

1. **ヘッダー**: 写真ライブラリの許可状態（未確認 / 許可済み / 拒否 / 限定）。フルアクセスでなければ許可ボタン、拒否・限定ならシステム設定（プライバシー > 写真）を開くボタンを出します。Google は oauth-client.json 未配置（置き場所と `docs/google-cloud-setup.md` を案内）/ 未接続（「Google に接続」、接続中はキャンセル可）/ 接続済み（「ログアウト」と送信先フォルダ名・ID）を表示します。状態はアプリがアクティブになるたびに再確認します（ダイアログは出しません）。
2. **日付指定**: 単日 / 期間を選び「読み込む」（⌘R）。全 N 件 / 対象 M 件 / 対象外 K 件 / 前回送信済み n 件を表示します。
3. **グリッド**: サムネイル、ファイル名、撮影時刻（HH:mm）、形式、お気に入り・バースト・Live・位置情報の印。対象外は薄く表示し、理由を出して選択できません。クリックまたはチェックで選択、「すべて選択」「選択解除」。
   - 読み込んだ直後に、`item-cache.json` に残っている前回までの結果を通信せずに表示します: 「送信済み」（ツールチップに日時と fileId）/「重複（Drive に既存）」/「確認済み・未送信」/「前回失敗」。現在の送信先フォルダについての結果だけを出します。
   - 「すべて選択」は、送信済み・重複（Drive に既存）とみなせる写真を選びません。手動では選べます（送信時に Drive にまだあれば重複としてスキップされます）。
   - 「送信済み・重複を隠す」（既定オフ）で、それらを一覧から隠します。
   - 前回送信済みなのに、重複確認や送信で取り直した Drive 一覧に見当たらないときは「前回送信済みだが Drive に見当たらない」と表示します。
4. **重複を確認**（任意）: 選択した写真の原本 MD5 を Drive と照合するだけで、送信はしません。キャッシュに MD5 がある写真は原本を書き出しません（iCloud からの取得を省きます）。結果は目安で、送信時にも改めて照合します。
   - **「選んだら自動で重複確認」**（下部のバー、既定オフ。設定は UserDefaults `autoPrecheckOnSelect` に保存）: オンにすると、写真を選ぶたび（クリック・「すべて選択」）に、新しく選んだ写真だけを裏で 1 枚ずつ照合します。このセッションで既に判定済み（送信予定 / Drive に既存、または送信結果あり）の写真は照合しません。キャッシュに MD5 があれば即時、無ければ写真ライブラリ / iCloud から原本を取得して計算します。続けて選んだときは約 0.3 秒待ってまとめて始め、確認待ち・確認中に選択を外した写真は取りやめます。読み込み・ログアウト・送信・手動の「重複を確認」・オフにしたときはすべて止めます。
   - Drive フォルダ一覧はセッション内で使い回し、5 分を過ぎたとき・送信の後・ログアウト後に取り直します（手動の「重複を確認」と送信は従来どおり毎回取り直します）。
   - 結果は手動の重複確認と同じセルのバッジと item-cache.json に入ります。Drive に既存、または選択中の先に選んだ写真と同じ内容と分かった写真は選択から外し、「重複のため選択を外しました: IMG_xxx（ほか n 件）」と通知します（Drive に既存と判定済みの写真は、手動で選び直せばそのまま選べます。選択中の写真と同じ内容の写真は、先の写真が選ばれている間は選び直してもまた外れます）。確認中はバーに「重複を確認中 2/5」とセルに「重複を確認中」を出します。
   - Google に未接続（または写真ライブラリがフルアクセスでない）ときはチェックを押せません。オフのときの動作は従来と同じです。
5. **送信**: 選択が 20 件を超えると件数を示す確認ダイアログを出し、承認後にだけ送ります（`maxItemsPerRun` = 選択件数）。送信は 1 件ずつです。送信中はウィンドウ中央に大きなパネルを出し、一覧は暗くして操作できなくします:
   - 「送信中 3 / 12 枚目（残り 9 枚）」（残り = まだ終わっていない件数から処理中の 1 枚を除いた数）、処理中の写真の大きなサムネイル（約 720px で取り直します）、ファイル名と撮影日時。
   - 段階を大きく表示: 写真ライブラリ / iCloud から原本を取得中 / 重複を確認中 / Google ドライブへ送信中 xx% / Drive で md5 を照合中。送信中は写真ごとの進捗バーと「5.1 / 8.0 MB」。進捗は送ったバイト数で細かく進みます（8 MiB のチャンクの途中でも進みます。再試行で送り直すときも表示は戻しません。アップロードセッションを作り直したときだけ 0 に戻ります）。
   - 全体の進捗バー（終わった件数 / 全件数）、送信済み・重複スキップ・失敗の件数、次の最大 5 枚のサムネイル。
   - 「中止」（Esc、確認なし）を押すと、処理中の 1 枚が止まるまで「中止しています…」を出します。
   - 送信中・手動の重複確認中はウィンドウを閉じられません（閉じるボタンと ⌘W。macOS 15 以降）。終了（⌘Q）しようとすると「送信中です。中止して終了しますか？」（重複確認中は「重複を確認中です。…」）を出し、「中止して終了」なら中止して、記録の書き込みと一時ファイルの削除を最大 15 秒待ってから終了します。「続ける」なら終了しません。自動の重複確認だけが動いているときは確認せずに中止し、同じように後始末を待ってから終了します。
6. **結果**: 終わる（または中止する）と同じパネルが結果に切り替わり、送信済み / 重複スキップ / 失敗（中止したときは未処理も）の件数、失敗一覧とエラー文、「records.jsonl を Finder で表示」、「閉じる」を出します。送信を始められなかったとき（Drive 一覧の取得失敗など）もエラー文と「閉じる」を出します。「閉じる」で一覧に戻ると、セルごとに 送信済み / 重複でスキップ（ツールチップに Drive fileId か先行写真）/ 対象外 / 失敗（エラー文）/ 中止 が残ります。実行後は再送を防ぐため選択を解除します。
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
| `item-cache.json` | 写真ごとの原本 MD5 / SHA-256 / バイト数と前回の結果（`sent` / `duplicateRemote` / `checkedNotOnDrive` / `failed`、Drive fileId、フォルダ ID、日時）。キーは `localIdentifier`（0600、アトミック書き込み） |

### item-cache.json（結果キャッシュ）

- 目的: 一度 MD5 を計算した写真は、重複確認・送信・`scan --hash` で原本を書き出し直さないようにします。また、前回の結果を読み込み直後に表示します。
- 重複判定の正は常に、その都度取り直す Drive の一覧です。キャッシュの MD5 が一覧にあれば書き出さずに重複としてスキップします。一覧に無ければ（前回送信済みでも、Drive から消されていれば）通常どおり書き出して送ります。書き出した MD5 がキャッシュと違えば上書きします。
- 原本ファイル名か UTI が今の写真と違うエントリは無視して上書きします。
- `records.jsonl` の取り込み: 初回は全件、以後は読み込み時・「読み込む」の後・重複確認 / 送信 / `scan` の開始時に、前回の続き（`recordsImportedThrough`: バイト位置 + ファイルの inode / デバイス + 直前の末尾の MD5）から追記分だけを取り込みます。ファイルが縮んだ・置き換わったときは先頭から取り込み直します。変換は 検証済みの `sent` → `sent`、`skipped_duplicate` → `duplicateRemote`、md5 付きの失敗 → md5 と `failed` です。中止は失敗として扱わず、md5 の無い記録で md5 を消しません。自分で送ったファイルが後で重複として見つかっても `sent` のままです。エントリより新しい記録だけを適用するので、取り込み直しても結果は変わりません。
- 更新（ハッシュ・結果の記録）の前と保存の直前に、ディスク上の内容を読み直してフィールド単位でマージします。ハッシュ（md5 / sha256 / byteCount）は `hashedAt`、結果（状態 / fileId / フォルダ）は `statusAt` の新しい方が勝ちます（同時刻は自分の側）。勝った結果が勝ったハッシュとは別の md5 についてのものなら、その結果は捨てます。別のプロセスの取り込み位置（`recordsImportedThrough`）は、そのプロセスのエントリをマージしてから採用します。アプリと CLI が同時に動いても互いの結果を消しにくくしていますが、ロックはしていないので完全ではありません。
- 自動の重複確認も、1 枚ごとに確認の前にディスク上の内容と records.jsonl の追記分を取り込みます。
- 読めないファイルは `item-cache.json.corrupt-<日時>` に退避し、`records.jsonl` から作り直します。
- **リセット**: アプリを終了して `item-cache.json` を削除してください。次回起動時に `records.jsonl` から作り直します（前回の結果を何も使いたくないときは `records.jsonl` も別の場所へ移します）。

- リフレッシュトークンは Keychain だけに保存します（サービス `dev.local.geoframe.uploader`、アカウント `google-refresh-token`、ThisDeviceOnly）。
- アクセストークンはメモリ上にだけ保持します。
- トークン・認可コード・シークレットはログに出しません。

要求スコープは `GoogleAuth.scopes`（`https://www.googleapis.com/auth/drive`）です。

## CLI

必ず `.app` 経由で起動します。写真ライブラリの許可は `.app` に紐づくためです。結果 JSON は `out/<サブコマンド>.json` に、ログは `out/<サブコマンド>.log` に出力されます。

```sh
scripts/cli.sh status
scripts/cli.sh scan --from 2026-11-01 [--to 2026-11-02] [--hash [--no-cache]] [--remote-md5-file path.json]
scripts/cli.sh auth
scripts/cli.sh upload --from 2026-11-01 [--to ...] (--ids ID1,ID2 | --limit N) [--max N]
scripts/cli.sh signout
```

各サブコマンドの動作:

- `status`: 写真ライブラリの許可状態、oauth-client.json の有無と妥当性、Keychain のトークンの有無（中身は読みません）、config、item-cache.json の場所とエントリ数（`itemCacheEntryCount`）を表示します。ダイアログは一切出しません。
- `scan`: 期間内（ローカル時刻の暦日、`--to` 省略時は 1 日だけ）のアセットを、対象/対象外とその理由つきで一覧にします。
  - `--hash` を付けると、対象の原本を書き出して MD5 / SHA-256 を計算します（一時ファイルはすぐ削除）。item-cache.json に MD5 があれば書き出さずにそれを使い、各アイテムの `md5Source`（`cache` / `export`）で区別します。`--no-cache` で常に書き出します。計算したハッシュはキャッシュに書き戻し、Drive の一覧と照合したときは結果も書き戻します。
  - `--remote-md5-file`（md5 文字列の配列、または `rclone lsjson --hash` の出力）を渡すか Drive にサインイン済みのときは、重複判定（`plan`）も付けます。
  - アップロードは決してしません。初回実行時は写真ライブラリの許可ダイアログが出ます。
- `auth`: ブラウザで Google にサインインし、付与されたスコープを表示します（トークンは表示しません）。
- `upload`: 選んだ写真を実際に送ります。
  - `--ids` を指定するとその ID の写真を、`--limit N` を指定すると対象のうち先頭 N 件を送ります。
  - 選択が `--max`（既定 3）を超えると何もせずエラーにします。
  - 結果は records.jsonl にも追記されます。
- `signout`: Keychain のトークンを削除し、ベストエフォートで revoke します。

アプリと CLI は起動時に、強制終了などで消し損ねた原本の一時ディレクトリ（`$TMPDIR/GeoFrameUploader-<UUID>` のうち、更新から 1 時間以上経ったもの）を削除します。自分が所有する実ディレクトリだけが対象で、シンボリックリンクは辿りません。

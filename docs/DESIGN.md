# 技術設計書

GeoFrame Uploader は、Apple Photos の写真原本を一切再エンコードせずに Google Drive「GeoFrame」フォルダへ安全に届ける macOS ネイティブアプリです。UI 非依存のコアロジック（`UploaderCore`）と、それを共有する SwiftUI アプリ / CLI（`GeoFrameUploader`）の 2 層で構成しています。

## 1. ディレクトリとモジュール構成

```text
apps/GeoFrameUploader/
  Package.swift                 SwiftPM（macOS 14+、外部依存なし）
  Info.plist                    バンドル ID: dev.local.geoframe.uploader
  Resources/AppIcon.icon        Icon Composer 形式アイコン（actool でコンパイル）
  Sources/
    UploaderCore/               UI 非依存のコアライブラリ
      AppPaths.swift            Application Support 配下のパス管理・0700 権限保証・OAuth/Config 読込
      PhotoItem.swift           写真メタデータの値型・ローカル日付範囲計算
      PhotoLibrary.swift        PhotoKit 認可状態取得・日付範囲フェッチ・サムネイル生成
      Eligibility.swift         メディア種別 / UTI 判定（純粋関数）と MIME マッピング
      OriginalExporter.swift    PHAssetResource(.photo) の無加工書き出し + 1パス MD5/SHA-256 + EXIF 日時
      OAuthPrimitives.swift     PKCE 生成・認可 URL 構築・コールバック検証・Keychain 保存
      LoopbackServer.swift      127.0.0.1 限定の一時 HTTP 受信（NWListener）
      GoogleAuth.swift          OAuth 2.0 認可・リフレッシュトークン管理・サインアウト
      HTTPSupport.swift         トークン類の伏字化（Redactor）・フォームエンコード
      DriveClient.swift         Drive API v3（files.list ページング / フォルダ解決 / 再開可能アップロード）
      UploadPlanner.swift       重複判定（純粋関数）・RemoteIndex・--remote-md5-file 解析
      UploadCoordinator.swift   逐次アップロード・二重 MD5 検証・records/cache 更新
      DuplicatePrecheck.swift   送信前の重複確認（キャッシュ優先・送信なし）
      AutoPrecheck.swift        選択時の自動重複確認キュー・セッション一覧スナップショット
      SendRunState.swift        送信モーダル用の進行状態ステートマシン（純粋型）
      RecordStore.swift         records.jsonl へのアトミック行追記（0600）
      ResultCache.swift         item-cache.json 管理・records.jsonl 増分取り込み・プロセス間マージ
      UploaderService.swift     GUI と CLI が共有する actor 窓口
    GeoFrameUploader/           実行ターゲット（--cli 引数の有無で CLI / SwiftUI を分岐）
      Entry.swift               @main エントリポイント
      UploaderApp.swift         SwiftUI App・ウィンドウ設定
      AppModel.swift            @MainActor の画面状態・自動重複確認デバウンス・送信制御
      ThumbnailCache.swift      一覧/大型サムネイルのメモリキャッシュ
      CLI.swift                 --cli サブコマンド実装
      Views/                    HeaderView / BannerView / DateFilterView / PhotoGridView / PhotoCell / ActionBarView / SendPanelView / ContentView
  Tests/UploaderCoreTests/      URLProtocol スタブを用いた単体テスト群
```

## 2. 原本抽出と対象形式の判定

### 対象形式判定（`EligibilityClassifier`）
- 受け入れ対象 UTI と送信時 MIME の対応は次の 5 種類のみです（`public.heic` を `public.heif` より先に評価）。
  - `public.jpeg` → `image/jpeg`
  - `public.png` → `image/png`
  - `public.heic` → `image/heic`
  - `public.heif` → `image/heif`
  - `public.tiff` → `image/tiff`
- DNG（`com.adobe.raw-image`）やカメラ RAW（`public.camera-raw-image`）は TIFF 準拠の UTI を持つ場合があるため、受け入れ判定より前に `isRaw(_:)` で明示的に除外します。
- 動画・音声・`.photo` リソースを持たないアセットも対象外として理由文字列を返します。

### 原本バイト列の抽出（`OriginalExporter`）
- `PHAssetResource.assetResources(for: asset)` から **`.photo` リソースだけ** を取得します。編集済み写真であっても `.fullSizePhoto`（編集後レンダリング結果）は使わず、Live Photo であっても `.pairedVideo`（動画部分）は送りません。
- `PHAssetResourceManager.default().requestData(for:options:dataReceivedHandler:completionHandler:)` でチャンクを受信しながら、一時ファイル（`0600`）への書き込みと `Insecure.MD5` / `SHA256` の更新を **1 パス** で同時に行います。
- 書き出し完了後、`CGImageSourceCreateWithURL` を用いて再エンコードせずに EXIF の `DateTimeOriginal` と `OffsetTimeOriginal` だけを読み取ります。
- アップロード（またはハッシュ確認）終了後、一時ファイルは即座に `remove()` されます。

## 3. Google OAuth 2.0 とセキュリティ境界

認証方式の選定経緯は [Drive 接続方式の評価と決定](drive-connection-decision.md) を参照してください。

- **認可フロー（`GoogleAuth` + `LoopbackServer`）**:
  - ユーザー自身の「デスクトップ アプリ」用 OAuth クライアントと PKCE（S256）を使用します。
  - `NWListener` で `127.0.0.1` の空きポート（エフェメラルポート）を 1 回限りリッスンし、取得した `state` を厳密照合して認可コードを受け取ります。
  - 取得したリフレッシュトークンは macOS キーチェーン（`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`、サービス名 `dev.local.geoframe.uploader`）にのみ保存し、アクセストークンはメモリ上にだけ保持します。
- **ログの伏字化（`Redactor`）**:
  - エラーメッセージやログに出力する文字列から Bearer トークンや機密パラメータを除去し、トークン類をディスクへ残さない設計です。
- **ファイル権限**:
  - `~/Library/Application Support/GeoFrameUploader/` は `0700`、`records.jsonl`・`item-cache.json`・書き出し一時ファイル・CLI レポート JSON は `0600` で作成します。

## 4. 再開可能アップロードと二重 MD5 検証

### アップロード仕様（`DriveClient`）
- Drive API v3 の `https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable` に対し、`POST` でセッションを開始し、返却された `Location` ヘッダのスキーム（`https`）とホスト（`www.googleapis.com`）を検証します（それ以外は `untrustedSessionURI` として拒否）。
- ファイル本体は **8 MiB チャンク**（`256 KiB` の倍数）ごとに `PUT` で送信します。
  - 一時エラー（429 / 5xx / ネットワーク断）時は、指数バックオフ（基準 1 秒、最大 32 秒）でリトライしつつ、途中オフセット確認（`Content-Range: bytes */total` → 308 応答の `Range` ヘッダから次オフセット再開）を行います。
  - セッション失効（404 / 410）時はセッションを最初から再作成します（最大 2 回）。
- 常に `files.create` 相当の新規作成のみを行い、既存ファイルの上書き・更新・改名・削除は一切行いません。

### 送信後の二重検証（`UploadCoordinator`）
送信したファイルについて、以下 2 段階の両方がローカルで計算した原本 MD5 と一致したときのみ `sent`（`verified: true`）として確定します。

1. 再開可能アップロード完了レスポンスに含まれる `md5Checksum` の照合。
2. 対象フォルダに対して `files.list` を再実行し（必要に応じてリトライ）、返却されたファイル一覧内に該当 `fileId` と一致する `md5Checksum` が存在することを確認。

## 5. 重複チェックとローカルキャッシュ

### 重複判定の原則
- 重複判定の真実のソース（Source of Truth）は常に **Google Drive フォルダ内の `files.list`（`md5Checksum` 一覧）** です。
- 同一バッチ内で同じ MD5 の写真が複数選ばれた場合は、先頭の 1 枚だけを送信し、2 枚目以降は `skipped_duplicate`（`duplicateOfLocalIdentifier` を記録）とします。

### 自動重複確認（`AutoPrecheckQueue` & `RemoteListingSnapshot`）
- 「選んだら自動で重複確認」がオンの場合、`AppModel` が選択差分から未判定の対象写真を抽出し、連続選択をまとめるため **0.3 秒（300 ms）デバウンス** した上で `AutoPrecheckQueue` により 1 枚ずつ直列確認します。
- 確認中に選択が解除されたアイテムは待ち行列から破棄し、処理中のアイテムが解除された場合はその確認タスクをキャンセルします。
- Drive フォルダ一覧はセッション内で **5 分間（300 秒）** スナップショットとして再利用し、選択のたびに `files.list` を連打しないようにしています（送信完了・ログアウト・手動「重複を確認」時は最新を取得します）。

### `item-cache.json` と `records.jsonl` の連携（`ResultCache`）
- `records.jsonl` は 1 枚処理するごとに `O_WRONLY | O_CREAT | O_APPEND`（`0600`）で 1 行 JSON を追記します。
- `ResultCache` は起動時・読み込み時・重複確認/送信/`scan` の開始時に `refresh()` を呼び、**ウォーターマーク（`byteOffset`・inode・デバイス番号・直前末尾 256 バイトの MD5）** を使って `records.jsonl` の未取り込み追記分だけを取り込みます（ファイルが縮んだ場合や置き換わった場合は先頭から再構築）。
- 既に MD5 がキャッシュされており、かつ `originalFilename` と `uti` が現在のアセットと一致する場合は、原本の書き出し（および iCloud からのダウンロード）を省略して高速に重複判定・確認を行います。
- 保存時は直前にディスク上の `item-cache.json` を読み直してエントリ単位（更新日時の新しい方優先）でマージし、アトミック書き込みを行います。ファイルが破損していた場合は `.corrupt-<timestamp>` へ退避し、`records.jsonl` から自動復旧します。

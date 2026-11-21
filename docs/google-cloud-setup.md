# Google Cloud 側の準備（ユーザー操作・初回のみ）

GeoFrame Uploader が Google Drive API を使うには、**あなた自身の Google Cloud プロジェクトに「デスクトップ アプリ」用の OAuth クライアント**が必要です。これは本人しかできない操作なので、アプリ側では自動化していません。所要時間はおよそ 10〜15 分です。

> 使う Google アカウント: GeoFrame フォルダを持っているアカウント（rclone の `gdrive:` と同じアカウント）。

## 0. 方式の選択（先に決める）

Drive の既存ファイル一覧（重複判定用）を読み、フォルダへ書き込むために、スコープ `https://www.googleapis.com/auth/drive` を使います。これは Google の区分で「制限付き（restricted）」スコープです。公開ステータスによって次の違いがあります。

| 方式 | 7 日でログイン切れ | 「未確認のアプリ」警告 | 備考 |
|---|---|---|---|
| **A. 個人モード（Personal）** 推奨 | しない | 出ない | 作成者アカウント専用。**新規プロジェクト作成時にしか選べない**（後から変更不可）。個人の gmail.com アカウントで選べるかは未確認 |
| B. 外部 + 本番環境（未審査） | しない | 出る（自分で「続行」する） | 自分1人なら審査不要の範囲（未審査アプリは新規ユーザー 100 人まで） |
| C. 外部 + テスト中 | **7 日ごとに再ログインが必要** | 出る | 最も手軽だが運用が面倒 |

まず A を試し、選べなければ B を選んでください。

## 1. プロジェクトを作る

- A（個人モード）の場合: <https://console.cloud.google.com/auth/overview/personal> を開き、画面の案内に従って個人モードのアプリを作成する。この流れでプロジェクト設定と OAuth クライアントが同時に作られる場合は、手順 3 の「種類: デスクトップ アプリ」を確認したうえで手順 4 へ進む。
- B / C の場合: <https://console.cloud.google.com/projectcreate> で新規プロジェクト（例: `geoframe-uploader`）を作成し、上部のプロジェクト選択でそのプロジェクトを選ぶ。

## 2. Google Drive API を有効にする

<https://console.cloud.google.com/flows/enableapi?apiid=drive.googleapis.com> を開き、作成したプロジェクトで「有効にする」を押す。

## 3. 同意画面と OAuth クライアント（Google Auth Platform）

1. **ブランディング**: <https://console.cloud.google.com/auth/branding>。アプリ名 `GeoFrame Uploader`、サポートメール（自分のアドレス）、デベロッパーの連絡先（自分のアドレス）を入れて「作成」。
2. **対象（Audience）**: <https://console.cloud.google.com/auth/audience>
   - B / C: ユーザーの種類「外部」。「テストユーザー」に自分のアカウントを追加して保存。
   - B のみ: 「アプリを公開」→ 公開ステータスを「本番環境」にする（審査の申請はしない）。
3. **データアクセス**: <https://console.cloud.google.com/auth/scopes> →「スコープを追加または削除」→ `.../auth/drive`（Google ドライブのすべてのファイルの表示、編集、作成、削除）を追加して保存。
4. **クライアント**: <https://console.cloud.google.com/auth/clients> →「クライアントを作成」→ アプリケーションの種類 **「デスクトップ アプリ」**、名前は任意（例: `GeoFrame Uploader Mac`）→「作成」。
5. 作成直後のダイアログ（またはクライアント詳細画面）から **JSON をダウンロード**する（`client_secret_xxxx.json`）。

## 4. JSON をアプリの設定場所へ置く

ターミナルで（ファイル名はダウンロードしたものに合わせる）:

```zsh
mkdir -p ~/Library/Application\ Support/GeoFrameUploader
chmod 700 ~/Library/Application\ Support/GeoFrameUploader
mv ~/Downloads/client_secret_*.json ~/Library/Application\ Support/GeoFrameUploader/oauth-client.json
chmod 600 ~/Library/Application\ Support/GeoFrameUploader/oauth-client.json
```

- このファイルは git に入れない（リポジトリ外に置く設計）。Google の説明上、デスクトップ アプリのクライアントシークレットは機密扱いではないが、公開はしないこと。

## 5. アプリでログインする

- GUI: アプリを起動し「Google に接続」を押す → ブラウザで自分のアカウントを選び許可する。
  - B / C では「Google はこのアプリを確認していません」と出る → 自分で作ったアプリなので「詳細」→「GeoFrame Uploader（安全ではないページ）に移動」で続行。
- または CLI: `apps/GeoFrameUploader/scripts/cli.sh auth`
- 取得したリフレッシュトークンは macOS キーチェーン（サービス名 `dev.local.geoframe.uploader`）にだけ保存されます。ログアウトはアプリの「ログアウト」または `scripts/cli.sh signout`。

## 終わったら

ここまで済んだら、エージェントに「OAuth クライアントを置いた」と伝えてください。次の確認を行います: ① `auth`、② 2026-04-19 の 1〜3 枚で実際に送信、③ Drive 側で md5Checksum が一致することの確認。

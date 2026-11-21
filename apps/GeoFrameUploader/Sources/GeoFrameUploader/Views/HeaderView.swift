import SwiftUI
import UploaderCore

/// 写真ライブラリと Google の接続状態。
struct HeaderView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            PhotosStatusView()
                .frame(maxWidth: .infinity, alignment: .leading)
            GoogleStatusView()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
    }
}

private struct StatusCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                content
            }
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
            .padding(4)
        } label: {
            Label(title, systemImage: systemImage).font(.headline)
        }
    }
}

private struct StateLabel: View {
    let text: String
    let color: Color
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).fontWeight(.semibold)
        }
    }
}

struct PhotosStatusView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        StatusCard(title: "写真ライブラリ", systemImage: "photo.on.rectangle") {
            let state = model.status?.photosAuthorization
            switch state {
            case nil:
                StateLabel(text: "確認中…", color: .gray)
            case .authorized?:
                StateLabel(text: "許可済み", color: .green)
            case .notDetermined?, .unknown?:
                StateLabel(text: "未確認", color: .gray)
                HStack {
                    Button("アクセスを許可…") { model.requestPhotosAccess() }
                    Text("「フルアクセス」を許可してください").font(.caption).foregroundStyle(.secondary)
                }
            case .denied?, .restricted?:
                StateLabel(text: "拒否", color: .red)
                settingsGuidance
            case .limited?:
                StateLabel(text: "限定（選択した写真のみ）", color: .orange)
                settingsGuidance
            }
        }
    }

    private var settingsGuidance: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("システム設定 > プライバシーとセキュリティ > 写真 で、このアプリに「フルアクセス」を許可してください。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("システム設定を開く") { model.openPhotosPrivacySettings() }
        }
    }
}

struct GoogleStatusView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        StatusCard(title: "Google ドライブ", systemImage: "externaldrive.connected.to.line.below") {
            if let s = model.status {
                content(s)
            } else {
                StateLabel(text: "確認中…", color: .gray)
            }
        }
    }

    @ViewBuilder
    private func content(_ s: UploaderService.Status) -> some View {
        if !s.oauthClientPresent {
            StateLabel(text: "oauth-client.json 未配置", color: .orange)
            Text((s.appSupportDir as NSString).appendingPathComponent("oauth-client.json"))
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
            HStack {
                Text("配置方法はリポジトリの docs/google-cloud-setup.md を参照してください。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("フォルダを開く") { model.openAppSupportDir() }.controlSize(.small)
            }
        } else if !s.oauthClientValid {
            StateLabel(text: "oauth-client.json が不正です", color: .red)
            Text(s.oauthClientError ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack {
                Text("docs/google-cloud-setup.md を参照してください。").font(.caption).foregroundStyle(.secondary)
                Button("フォルダを開く") { model.openAppSupportDir() }.controlSize(.small)
            }
        } else if model.isSigningIn {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("接続中… ブラウザで Google にサインインしてください")
            }
            Button("キャンセル") { model.cancelSignIn() }
        } else if !s.signedIn {
            StateLabel(text: "未接続", color: .gray)
            Button("Google に接続") { model.signIn() }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy)
        } else {
            HStack {
                StateLabel(text: "接続済み", color: .green)
                Spacer()
                Button("ログアウト") { model.signOut() }
                    .disabled(model.isBusy)
            }
            folderRow(s)
            if let err = s.configError {
                Text("config.json: \(err)").font(.caption).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func folderRow(_ s: UploaderService.Status) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
            Text("送信先: \(s.config.folderName)")
            if let id = model.folderId {
                Text("(\(id))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else if model.isResolvingFolder {
                ProgressView().controlSize(.small)
                Text("フォルダを確認中…").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("未解決").font(.caption).foregroundStyle(.orange)
                Button("再取得") { Task { await model.resolveFolder() } }.controlSize(.small)
            }
        }
    }
}

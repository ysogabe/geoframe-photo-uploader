import CoreGraphics
import Foundation

/// UI（`@MainActor final class UploaderViewModel: ObservableObject`）と CLI が共有する窓口。
/// すべて async。イベントコールバックは任意スレッドから呼ばれるので UI 側で MainActor に移すこと。
public actor UploaderService {
    public struct Status: Codable, Sendable {
        public var photosAuthorization: PhotoAuthState
        public var oauthClientPresent: Bool
        public var oauthClientValid: Bool
        public var oauthClientError: String?
        public var signedIn: Bool
        public var config: AppConfig
        public var configError: String?
        public var appSupportDir: String
        public var recordsFile: String
        public var scopes: [String]
    }

    public let paths: AppPaths
    public let tokenStore: RefreshTokenStore
    private let session: URLSession
    private let log: @Sendable (String) -> Void
    private var auth: GoogleAuth?

    public init(paths: AppPaths = AppPaths(), tokenStore: RefreshTokenStore = KeychainTokenStore(),
                session: URLSession = .shared, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.paths = paths
        self.tokenStore = tokenStore
        self.session = session
        self.log = log
    }

    // MARK: 状態

    /// プロンプトを一切出さない状態確認。
    public func status() -> Status {
        try? paths.ensureBaseDir()
        var clientValid = false
        var clientError: String?
        let present = FileManager.default.fileExists(atPath: paths.oauthClientFile.path)
        if present {
            do { _ = try OAuthClientConfig.load(from: paths.oauthClientFile); clientValid = true } catch {
                clientError = error.localizedDescription
            }
        }
        var cfg = AppConfig()
        var cfgError: String?
        do { cfg = try AppConfig.load(from: paths.configFile) } catch { cfgError = error.localizedDescription }
        return Status(photosAuthorization: PhotoLibrary.currentAuthorization(),
                      oauthClientPresent: present, oauthClientValid: clientValid, oauthClientError: clientError,
                      signedIn: tokenStore.exists(), config: cfg, configError: cfgError,
                      appSupportDir: paths.baseDir.path, recordsFile: paths.recordsFile.path, scopes: GoogleAuth.scopes)
    }

    // MARK: 写真

    public func requestPhotosAccess() async throws { try await PhotoLibrary.ensureAuthorized() }

    public func loadItems(fromDay: String, toDay: String?) async throws -> [PhotoItem] {
        try await PhotoLibrary.ensureAuthorized()
        guard let items = PhotoLibrary.shared.fetchItems(fromDay: fromDay, toDay: toDay) else {
            throw ConfigError.configInvalid("日付は YYYY-MM-DD で指定してください")
        }
        return items
    }

    public func loadItems(start: Date, end: Date) async throws -> [PhotoItem] {
        try await PhotoLibrary.ensureAuthorized()
        return PhotoLibrary.shared.fetchItems(start: start, end: end)
    }

    // MARK: Google

    private func googleAuth() throws -> GoogleAuth {
        if let auth { return auth }
        let client = try OAuthClientConfig.load(from: paths.oauthClientFile)
        let a = GoogleAuth(client: client, store: tokenStore, session: session)
        auth = a
        return a
    }

    public var isSignedIn: Bool { tokenStore.exists() }

    public func signIn() async throws -> SignInResult {
        try paths.ensureBaseDir()
        return try await googleAuth().signIn()
    }

    public func signOut() async {
        if let auth { await auth.signOut() } else { await GoogleAuth.signOut(store: tokenStore, session: session) }
        auth = nil
    }

    public func driveClient() throws -> DriveClient {
        DriveClient(session: session, tokens: try googleAuth(), log: log)
    }

    /// config.json の folderId を使い、無ければ名前で解決して保存。
    public func resolveFolderId() async throws -> String {
        try paths.ensureBaseDir()
        var cfg = try AppConfig.load(from: paths.configFile)
        if let id = cfg.folderId { return id }
        let id = try await driveClient().resolveFolder(name: cfg.folderName)
        cfg.folderId = id
        try cfg.save(to: paths.configFile)
        return id
    }

    public func remoteIndex() async throws -> RemoteIndex {
        let folder = try await resolveFolderId()
        return RemoteIndex(files: try await driveClient().listFolderFiles(folderId: folder))
    }

    // MARK: アップロード

    /// UI は確認ダイアログの後に自分の上限を `maxItemsPerRun` に渡す。
    public func upload(items: [PhotoItem], maxItemsPerRun: Int,
                       onEvent: (@Sendable (UploadEvent) -> Void)? = nil) async throws -> RunSummary {
        guard items.count <= maxItemsPerRun else {
            throw UploadCoordinatorError.tooManyItems(selected: items.count, max: maxItemsPerRun)
        }
        try await PhotoLibrary.ensureAuthorized()
        let folder = try await resolveFolderId()
        let exporter = try OriginalExporter()
        defer { exporter.cleanup() }
        let coordinator = UploadCoordinator(drive: try driveClient(), exporter: exporter,
                                            records: RecordStore(fileURL: paths.recordsFile), log: log)
        return try await coordinator.run(items: items, folderId: folder, maxItemsPerRun: maxItemsPerRun, onEvent: onEvent)
    }

    /// イベントを AsyncStream で受けたい UI 向け。
    public nonisolated func uploadStream(items: [PhotoItem], maxItemsPerRun: Int)
        -> (events: AsyncStream<UploadEvent>, summary: Task<RunSummary, Error>) {
        let (stream, cont) = AsyncStream<UploadEvent>.makeStream()
        let task = Task { () throws -> RunSummary in
            defer { cont.finish() }
            return try await self.upload(items: items, maxItemsPerRun: maxItemsPerRun) { cont.yield($0) }
        }
        return (stream, task)
    }

    /// 送信前の重複確認（アップロードはしない）。原本を書き出して MD5 を計算し、Drive フォルダ一覧と照合する。
    public func precheckDuplicates(items: [PhotoItem],
                                   onProgress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> [PrecheckResult] {
        try await PhotoLibrary.ensureAuthorized()
        let remote = try await remoteIndex()
        let exporter = try OriginalExporter()
        defer { exporter.cleanup() }
        return try await DuplicatePrecheck.run(items: items, exporter: exporter, remote: remote, onProgress: onProgress)
    }

    public func thumbnail(localIdentifier: String, size: CGSize) async -> CGImage? {
        await PhotoLibrary.shared.thumbnailCGImage(for: localIdentifier, size: size)
    }
}

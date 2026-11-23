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
        public var itemCacheFile: String
        public var itemCacheEntryCount: Int
        public var scopes: [String]
    }

    public let paths: AppPaths
    public let tokenStore: RefreshTokenStore
    private let session: URLSession
    private let log: @Sendable (String) -> Void
    private var auth: GoogleAuth?
    private var injectedCache: ResultCache?
    private var injectedQualityCache: QualityCache?
    private var injectedPlaceResolver: PlaceNameResolver?
    /// 自動重複確認で使い回す Drive フォルダ一覧（送信後・ログアウトで捨てる）
    private var listing: RemoteListingSnapshot? { didSet { if listing == nil { listingGeneration &+= 1 } } }
    private var listingGeneration = 0
    private let now: @Sendable () -> Date

    /// `cache` を省略すると `paths.itemCacheFile` を初回利用時に開く（無ければ records.jsonl から作る）。
    public init(paths: AppPaths = AppPaths(), tokenStore: RefreshTokenStore = KeychainTokenStore(),
                session: URLSession = .shared, cache: ResultCache? = nil,
                log: @escaping @Sendable (String) -> Void = { _ in }, now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
        self.paths = paths
        self.tokenStore = tokenStore
        self.session = session
        self.injectedCache = cache
        self.log = log
    }

    // MARK: 結果キャッシュ

    private func refreshedCacheCount() -> Int {
        let c = resultCache()
        c.refresh()
        return c.count
    }

    /// サービスごとに 1 つ（以降はメモリ上の内容を使う）。
    public func resultCache() -> ResultCache {
        if let injectedCache { return injectedCache }
        try? paths.ensureBaseDir()
        let c = ResultCache(fileURL: paths.itemCacheFile, records: RecordStore(fileURL: paths.recordsFile), log: log)
        injectedCache = c
        return c
    }

    /// 読み込んだ写真のうち、キャッシュが有効なもの（通信しない）。records.jsonl の追記分を先に取り込む。
    public func cachedEntries(for items: [PhotoItem]) -> [String: CacheEntry] {
        let c = resultCache()
        c.refresh()
        return c.entries(for: items)
    }

    /// カレンダー表示用の日別送信・確認履歴を返す。撮影日が未保存のエントリがあれば許可済み時に PhotoKit から補完する。
    public func calendarDayHistories(folderId: String?, calendar: Calendar = .current) -> [Date: CalendarDayHistory] {
        let c = resultCache()
        c.refresh()
        let missing = c.missingCreationDateIds()
        if !missing.isEmpty && PhotoLibrary.currentAuthorization() == .authorized {
            let dates = PhotoLibrary.shared.creationDates(for: missing)
            if !dates.isEmpty {
                c.backfillCreationDates(dates)
            }
        }
        return c.dayHistories(forFolder: folderId, calendar: calendar)
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
                      appSupportDir: paths.baseDir.path, recordsFile: paths.recordsFile.path,
                      itemCacheFile: paths.itemCacheFile.path, itemCacheEntryCount: refreshedCacheCount(),
                      scopes: GoogleAuth.scopes)
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
        listing = nil
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
        // 送信で Drive の中身が変わるので、使い回している一覧は捨てる
        listing = nil
        defer { listing = nil }
        let coordinator = UploadCoordinator(drive: try driveClient(), exporter: exporter,
                                            records: RecordStore(fileURL: paths.recordsFile), cache: resultCache(), log: log)
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

    /// 送信前の重複確認（アップロードはしない）。原本の MD5（キャッシュにあれば書き出さない）を Drive フォルダ一覧と照合する。
    public func precheckDuplicates(items: [PhotoItem],
                                   onProgress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> [PrecheckResult] {
        try await PhotoLibrary.ensureAuthorized()
        let folder = try await resolveFolderId()
        let remote = RemoteIndex(files: try await driveClient().listFolderFiles(folderId: folder))
        let exporter = try OriginalExporter()
        defer { exporter.cleanup() }
        return try await DuplicatePrecheck.run(items: items, exporter: exporter, remote: remote, cache: resultCache(),
                                               folderId: folder, onProgress: onProgress)
    }

    public func thumbnail(localIdentifier: String, size: CGSize) async -> CGImage? {
        await PhotoLibrary.shared.thumbnailCGImage(for: localIdentifier, size: size)
    }

    // MARK: 品質解析・類似グルーピング・地名解決

    public func qualityCache() -> QualityCache {
        if let injectedQualityCache { return injectedQualityCache }
        try? paths.ensureBaseDir()
        let qc = QualityCache(fileURL: paths.qualityCacheFile, log: log)
        injectedQualityCache = qc
        return qc
    }

    public func cachedQuality(for items: [PhotoItem]) -> [String: QualityMetrics] {
        qualityCache().metrics(for: items)
    }

    /// 512px サムネイルを取得して pHash と画質指標を算出する（GUI の ThumbnailCache には載せない）。
    public func analyzeQuality(for item: PhotoItem) async -> QualityMetrics? {
        guard !Task.isCancelled else { return nil }
        guard let cg = await PhotoLibrary.shared.analysisCGImage(
            for: item.localIdentifier,
            maxDimension: ImageQualityAnalyzer.metricMaxPx
        ) else {
            return nil
        }
        guard !Task.isCancelled else { return nil }
        return ImageQualityAnalyzer.analyze(cg)
    }

    public func saveQualityBatch(_ pairs: [(item: PhotoItem, metrics: QualityMetrics)]) {
        qualityCache().recordBatch(pairs)
    }

    public func placeResolver() -> PlaceNameResolver {
        if let injectedPlaceResolver { return injectedPlaceResolver }
        try? paths.ensureBaseDir()
        let resolver = PlaceNameResolver(fileURL: paths.placeCacheFile, log: log)
        injectedPlaceResolver = resolver
        return resolver
    }

    public func cachedPlaceName(for location: PhotoLocation) async -> String? {
        await placeResolver().cachedName(for: location)
    }

    public func resolvePlaceName(for location: PhotoLocation) async -> String? {
        await placeResolver().resolve(location: location)
    }

    public func resolvePlaceOutcome(for location: PhotoLocation) async -> GeocodingResult {
        await placeResolver().resolveOutcome(location: location)
    }

    public func cancelPlaceResolution() async {
        await injectedPlaceResolver?.cancelAll()
    }

    // MARK: 自動重複確認

    /// セッション内で使い回す Drive フォルダ一覧。同じフォルダで 5 分以内に取ったものがあればそれを、無ければ取り直す。
    public func sessionRemoteIndex(maxAge: TimeInterval = RemoteListingSnapshot.defaultMaxAge) async throws
        -> (folderId: String, remote: RemoteIndex) {
        let folder = try await resolveFolderId()
        if let l = listing, l.isUsable(folderId: folder, now: now(), maxAge: maxAge) { return (folder, l.index) }
        let gen = listingGeneration
        let index = RemoteIndex(files: try await driveClient().listFolderFiles(folderId: folder))
        // 取得中に送信・ログアウトで捨てられていたら覚えない（古い一覧を使い回さない）
        if gen == listingGeneration {
            listing = RemoteListingSnapshot(folderId: folder, index: index, fetchedAt: now())
        }
        return (folder, index)
    }

    /// 使い回している Drive 一覧を捨てる（次の自動確認で取り直す）。
    public func invalidateRemoteListing() { listing = nil }

    /// 選んだ写真 1 枚の重複確認（選んだら自動で重複確認）。キャッシュの MD5 が有効なら書き出さない。
    /// `priorSelected` は MD5 が分かっている他の選択中の写真（選択内の重複の判定用）。
    /// Drive 一覧の取得・認証の失敗は投げる。原本の取得失敗は `.notHashed` の結果で返す。
    public func autoPrecheck(item: PhotoItem, priorSelected: [PlanInput]) async throws -> PrecheckResult {
        try await PhotoLibrary.ensureAuthorized()
        let (folder, remote) = try await sessionRemoteIndex()
        try Task.checkCancellation()
        let exporter = try OriginalExporter()
        defer { exporter.cleanup() }
        return try await DuplicatePrecheck.checkOne(item: item, priorSelected: priorSelected, exporter: exporter,
                                                    remote: remote, cache: resultCache(), folderId: folder)
    }
}


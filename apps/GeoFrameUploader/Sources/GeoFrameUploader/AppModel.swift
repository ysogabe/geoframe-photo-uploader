import AppKit
import SwiftUI
import UploaderCore

enum GroupingMode: String, CaseIterable, Identifiable {
    case sectioned = "場所・時間枠"
    case flat = "フラット一覧"
    var id: Self { self }
}

/// 送信中のアイテムの段階（UI 表示用。進捗は整数 % に丸めて再描画を抑える）。
enum LivePhase: Equatable {
    case exporting
    case checkingDuplicate
    case uploading(percent: Int)
    case verifying

    var label: String {
        switch self {
        case .exporting: return "原本を取得中"
        case .checkingDuplicate: return "重複を確認中"
        case .uploading(let p): return "送信中 \(p)%"
        case .verifying: return "検証中"
        }
    }
}

struct Banner: Identifiable, Equatable {
    enum Kind { case error, warning, info }
    let id = UUID()
    var kind: Kind
    var message: String
}

struct RunProgress: Equatable {
    enum Kind { case upload, precheck }
    var kind: Kind
    /// 完了したアイテム数
    var done: Int
    /// 処理中のアイテム（1 始まり、0 なら未開始）
    var current: Int
    var total: Int
}

@MainActor
final class AppModel: ObservableObject {
    static let confirmThreshold = 20

    let service: UploaderService
    let thumbnails: ThumbnailCache

    // 状態
    @Published private(set) var status: UploaderService.Status?
    @Published private(set) var isSigningIn = false
    @Published private(set) var folderId: String?
    @Published private(set) var isResolvingFolder = false

    // 日付（期間を標準とし、同日指定で 1 日分。既定は直近 7 日間）
    @Published var fromDate: Date
    @Published var toDate: Date

    // 一覧
    @Published private(set) var items: [PhotoItem] = []
    @Published private(set) var hasLoaded = false
    @Published private(set) var isLoading = false
    @Published private(set) var selection: Set<String> = [] {
        didSet { if selection != oldValue { selectionDidChange(from: oldValue) } }
    }
    /// 読み込み時点の item-cache.json（前回までの結果）。読み込み直すまで固定する
    @Published private(set) var cachedEntries: [String: CacheEntry] = [:]
    /// 「送信済み・重複を隠す」
    @Published var hideDone = false {
        didSet {
            if hideDone { pruneHiddenSelection() }
            invalidateShiftAnchorIfNeeded()
        }
    }

    /// 隠れている（送信済み・重複とみなせる）写真を選択から外す。
    private func pruneHiddenSelection() {
        let hidden = Set(items.filter { isDone($0) }.map(\.id))
        if !hidden.isDisjoint(with: selection) { selection.subtract(hidden) }
    }

    // 実行
    @Published private(set) var livePhases: [String: LivePhase] = [:]
    @Published private(set) var results: [String: ItemResult] = [:]
    @Published private(set) var prechecks: [String: PrecheckResult] = [:]
    @Published private(set) var progress: RunProgress?
    @Published private(set) var isSending = false
    @Published private(set) var isPrechecking = false
    @Published private(set) var isCancelling = false
    @Published private(set) var lastSummary: RunSummary?
    @Published private(set) var lastRunItems: [PhotoItem] = []

    // 選んだら自動で重複確認
    static let autoPrecheckKey = "autoPrecheckOnSelect"
    /// 「選んだら自動で重複確認」（UserDefaults に保存、既定オフ）
    @Published var autoPrecheckEnabled: Bool = UserDefaults.standard.bool(forKey: AppModel.autoPrecheckKey) {
        didSet {
            guard autoPrecheckEnabled != oldValue else { return }
            UserDefaults.standard.set(autoPrecheckEnabled, forKey: Self.autoPrecheckKey)
            if autoPrecheckEnabled { selectionDidChange(from: []) } else { cancelAutoPrecheck() }
        }
    }
    /// 自動確認の進捗（「重複を確認中 2/5」。何もしていなければ nil）
    @Published private(set) var autoProgress: (current: Int, total: Int)?
    /// 自動確認で処理中の写真（セルに「重複を確認中」を出す）
    @Published private(set) var autoCheckingId: String?
    private var autoQueue = AutoPrecheckQueue()
    private var autoGeneration = 0
    private var autoDebounceTask: Task<Void, Never>?
    private var autoWorkerTask: Task<Void, Never>?
    private var autoItemTask: Task<PrecheckResult, Error>?
    /// このまとまりで重複のため選択から外した写真の名前（バナー用）
    private var autoDeselectedNames: [String] = []
    static let autoDebounceNanoseconds: UInt64 = 300_000_000

    // 送信パネル
    /// 送信パネルを出しているか（送信中と、終わった後の結果表示。「閉じる」まで）
    @Published private(set) var showSendPanel = false
    @Published private(set) var sendRun: SendRunState?
    /// 送信が始められなかった・途中で止まったときのエラー（パネルに出す）
    @Published private(set) var runError: String?
    /// 直前の送信を中止したか（パネルの結果表示用）
    @Published private(set) var runWasCancelled = false

    // グルーピング・品質解析・地名解決（v0.2）
    static let groupingModeKey = "groupingMode"
    static let bundleSimilarKey = "bundleSimilarPhotos"
    static let timeGapMinutesKey = "sectionTimeGapMinutes"
    static let distanceMetersKey = "sectionDistanceMeters"
    static let geocodeEnabledKey = "sectionGeocodeEnabled"

    @Published var groupingMode: GroupingMode = GroupingMode(
        rawValue: UserDefaults.standard.string(forKey: AppModel.groupingModeKey) ?? ""
    ) ?? .sectioned {
        didSet {
            guard groupingMode != oldValue else { return }
            UserDefaults.standard.set(groupingMode.rawValue, forKey: Self.groupingModeKey)
            recomputeGroupings()
        }
    }

    @Published private(set) var calendarHistory: [Date: CalendarDayHistory] = [:]

    @Published var bundleSimilar: Bool = (UserDefaults.standard.object(forKey: AppModel.bundleSimilarKey) as? Bool) ?? true {
        didSet {
            guard bundleSimilar != oldValue else { return }
            UserDefaults.standard.set(bundleSimilar, forKey: Self.bundleSimilarKey)
        }
    }

    @Published var timeGapMinutes: Int = {
        let v = UserDefaults.standard.integer(forKey: AppModel.timeGapMinutesKey)
        return [15, 30, 60].contains(v) ? v : 30
    }() {
        didSet {
            guard timeGapMinutes != oldValue else { return }
            UserDefaults.standard.set(timeGapMinutes, forKey: Self.timeGapMinutesKey)
            collapsedSectionIds = []
            recomputeSections()
            recomputeGroupings()
            schedulePlaceResolution(generation: analysisGeneration)
        }
    }

    @Published var distanceThresholdMeters: Int = {
        let v = UserDefaults.standard.integer(forKey: AppModel.distanceMetersKey)
        return [100, 300, 1000].contains(v) ? v : 300
    }() {
        didSet {
            guard distanceThresholdMeters != oldValue else { return }
            UserDefaults.standard.set(distanceThresholdMeters, forKey: Self.distanceMetersKey)
            collapsedSectionIds = []
            recomputeSections()
            recomputeGroupings()
            schedulePlaceResolution(generation: analysisGeneration)
        }
    }

    @Published var geocodeEnabled: Bool = (UserDefaults.standard.object(forKey: AppModel.geocodeEnabledKey) as? Bool) ?? true {
        didSet {
            guard geocodeEnabled != oldValue else { return }
            UserDefaults.standard.set(geocodeEnabled, forKey: Self.geocodeEnabledKey)
            if geocodeEnabled {
                schedulePlaceResolution(generation: analysisGeneration)
            } else {
                placeDebounceTask?.cancel()
                placeResolutionTask?.cancel()
                Task { await service.cancelPlaceResolution() }
            }
        }
    }

    @Published private(set) var sections: [PhotoSection] = []
    @Published private(set) var sectionGroupings: [String: SectionGroupingResult] = [:]
    @Published private(set) var qualityMetrics: [String: QualityMetrics] = [:]
    @Published private(set) var analysisProgress: (done: Int, total: Int)?
    @Published var collapsedSectionIds: Set<String> = []
    @Published private(set) var placeNames: [String: String] = [:]
    @Published var comparingCluster: SimilarityCluster?
    @Published private(set) var comparingEditableIds: [String] = []
    private var lastClickedId: String?

    private var loadGeneration = 0
    private var isTerminating = false
    private var analysisGeneration = 0
    private var analysisTask: Task<Void, Never>?
    private var placeDebounceTask: Task<Void, Never>?
    private var placeResolutionTask: Task<Void, Never>?

    // 確認ダイアログ（20 件超）
    @Published var showSendConfirm = false
    @Published private(set) var pendingSend: [PhotoItem] = []

    @Published var banner: Banner?

    private var signInTask: Task<Void, Never>?
    private var signInCancelRequested = false
    private var folderResolveAttempted = false
    private var uploadSummaryTask: Task<RunSummary, Error>?
    private var precheckTask: Task<Void, Never>?
    private var cancelRequested = false
    private var bannerDismissTask: Task<Void, Never>?

    init(service: UploaderService = UploaderService()) {
        let initial = DateRangePreset.last7Days.dateRange()
        self.fromDate = initial.from
        self.toDate = initial.to
        self.service = service
        self.thumbnails = ThumbnailCache(service: service)
    }

    // MARK: 派生値

    var isBusy: Bool { isSending || isPrechecking || isLoading || showSendPanel }
    var isAutoPrechecking: Bool { autoProgress != nil }
    var photosAuthorized: Bool { status?.photosAuthorization == .authorized }
    var googleReady: Bool {
        guard let s = status else { return false }
        return s.oauthClientValid && s.signedIn
    }
    var eligibleCount: Int { items.filter { $0.eligibility.isEligible }.count }
    var ineligibleCount: Int { items.count - eligibleCount }
    var selectedItems: [PhotoItem] { items.filter { selection.contains($0.id) } }
    var visibleItems: [PhotoItem] { hideDone ? items.filter { !isDone($0) } : items }
    var hiddenCount: Int { items.count - visibleItems.count }
    var previouslySentCount: Int { items.filter { cachedStatus(for: $0)?.lastStatus == .sent }.count }
    var isAnalysisComplete: Bool { hasLoaded && analysisProgress == nil }
    var showComparePanel: Bool { comparingCluster != nil && !showSendPanel }
    var isMultiDayRange: Bool { !Calendar.current.isDate(fromDate, inSameDayAs: toDate) }
    var selectedDayCount: Int { LocalTime.inclusiveDayCount(from: fromDate, to: toDate) }

    func setDateRange(from: Date, to: Date) {
        let cal = Calendar.current
        fromDate = cal.startOfDay(for: min(from, to))
        toDate = cal.startOfDay(for: max(from, to))
    }

    func applyDatePreset(_ preset: DateRangePreset) {
        let r = preset.dateRange()
        setDateRange(from: r.from, to: r.to)
    }

    var sectionOptions: SectionOptions {
        SectionOptions(
            timeGapSeconds: TimeInterval(timeGapMinutes * 60),
            distanceThresholdMeters: Double(distanceThresholdMeters)
        )
    }

    var similarClusterCount: Int {
        sections.reduce(0) { $0 + (sectionGroupings[$1.id]?.clusters.count ?? 0) }
    }

    var recommendedAllIds: Set<String> {
        var out = Set<String>()
        for sec in sections {
            let grp = sectionGroupings[sec.id] ?? .empty
            out.formUnion(SelectionPlanner.recommendedToSelect(items: sec.items, grouping: grp, isDone: isDone))
        }
        return out
    }

    func visibleItems(in section: PhotoSection) -> [PhotoItem] {
        hideDone ? section.items.filter { !isDone($0) } : section.items
    }

    func grouping(for sectionId: String) -> SectionGroupingResult {
        sectionGroupings[sectionId] ?? .empty
    }

    func ranking(for itemId: String, in sectionId: String?) -> RankedMember? {
        guard bundleSimilar, let sectionId else { return nil }
        return sectionGroupings[sectionId]?.clusterByItemId[itemId]?.rankings[itemId]
    }

    func standaloneIssues(for itemId: String, in sectionId: String?) -> [String]? {
        guard let sectionId else { return nil }
        return sectionGroupings[sectionId]?.standaloneIssues[itemId]
    }

    func selectedCount(in section: PhotoSection) -> Int {
        section.items.reduce(0) { $0 + (selection.contains($1.id) ? 1 : 0) }
    }

    func recommendedIds(in section: PhotoSection) -> Set<String> {
        SelectionPlanner.recommendedToSelect(items: section.items, grouping: grouping(for: section.id), isDone: isDone)
    }

    func toggleSectionCollapsed(_ sectionId: String) {
        if collapsedSectionIds.contains(sectionId) {
            collapsedSectionIds.remove(sectionId)
        } else {
            collapsedSectionIds.insert(sectionId)
        }
        invalidateShiftAnchorIfNeeded()
    }

    /// 実際のグリッド描画順（類似クラスタ束ね反映済み）と一致する、選択可能な表示中 ID 一覧。
    var orderedVisibleSelectableIds: [String] {
        sections.flatMap { sec -> [String] in
            if groupingMode == .sectioned && collapsedSectionIds.contains(sec.id) { return [] }
            let vis = visibleItems(in: sec)
            let chunks = SelectionPlanner.displayChunks(
                items: vis,
                grouping: grouping(for: sec.id),
                bundleSimilar: bundleSimilar
            )
            return SelectionPlanner.orderedSelectableIds(from: chunks) { isSelectable($0) }
        }
    }

    private func invalidateShiftAnchorIfNeeded() {
        guard let anchor = lastClickedId else { return }
        if !orderedVisibleSelectableIds.contains(anchor) {
            lastClickedId = nil
        }
    }

    /// 現在の送信先フォルダについての前回の結果（無ければ nil）。
    func cachedStatus(for item: PhotoItem) -> CacheEntry? {
        guard let e = cachedEntries[item.id], e.lastStatus != nil,
              e.statusApplies(toFolder: folderId ?? status?.config.folderId) else { return nil }
        return e
    }

    /// Drive に載っている（送信済み・重複）とみなせるか。今回の結果 → 重複確認 → 前回の結果の順に見る。
    /// 「送信済み・重複を隠す」と「すべて選択」の両方で使う。
    func isDone(_ item: PhotoItem) -> Bool {
        if let r = results[item.id] { return r.status == .sent || r.status == .skippedDuplicate }
        if let p = prechecks[item.id] {
            if case .duplicateRemote = p.decision { return true }
            if p.decision != .notHashed { return false }
        }
        switch cachedStatus(for: item)?.lastStatus {
        case .sent?, .duplicateRemote?: return true
        default: return false
        }
    }

    /// 前回送信済みなのに、今回取り直した Drive 一覧に見当たらなかったときの注意書き。
    func cacheWarning(for item: PhotoItem) -> String? {
        guard cachedStatus(for: item)?.lastStatus == .sent else { return nil }
        if let r = results[item.id] {
            switch r.status {
            case .sent: return "前回送信済みだが Drive に見当たらないため再送しました"
            case .failed where !r.wasCancelled && r.md5 != nil: return "前回送信済みだが Drive に見当たらない"
            default: return nil
            }
        }
        if let p = prechecks[item.id] {
            switch p.decision {
            case .toUpload, .duplicateInBatch: return "前回送信済みだが Drive に見当たらない"
            default: return nil
            }
        }
        return nil
    }
    var canSend: Bool { !isBusy && !selection.isEmpty && googleReady && photosAuthorized && !isSigningIn }
    var canPrecheck: Bool { canSend }
    var recordsFile: String? { status?.recordsFile }

    /// 送信中・直前の送信のアイテム。
    func runItem(for localIdentifier: String) -> PhotoItem? {
        lastRunItems.first(where: { $0.localIdentifier == localIdentifier })
            ?? items.first(where: { $0.localIdentifier == localIdentifier })
    }

    func displayName(for localIdentifier: String) -> String {
        let all = items + lastRunItems
        return all.first(where: { $0.localIdentifier == localIdentifier })?.driveName ?? localIdentifier
    }

    // MARK: バナー

    func showBanner(_ kind: Banner.Kind, _ message: String) {
        let b = Banner(kind: kind, message: message)
        banner = b
        bannerDismissTask?.cancel()
        guard kind == .info else { return }
        bannerDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled, let self, self.banner?.id == b.id else { return }
            self.banner = nil
        }
    }

    func showError(_ prefix: String, _ error: Error) {
        showBanner(.error, "\(prefix): \(Redactor.redact(error.localizedDescription))")
    }

    func dismissBanner() {
        bannerDismissTask?.cancel()
        banner = nil
    }

    // MARK: 状態確認

    /// ダイアログを出さない状態確認。アクティブ化のたびに呼ぶ。
    func refreshStatus() async {
        let s = await service.status()
        status = s
        if !s.signedIn || !s.oauthClientValid {
            cancelAutoPrecheck()
            folderId = nil
            folderResolveAttempted = false
            await refreshCalendarHistory()
            return
        }
        if let id = s.config.folderId { folderId = id }
        if folderId == nil && !folderResolveAttempted && !isSigningIn {
            await resolveFolder()
        }
        await refreshCalendarHistory()
    }

    func refreshCalendarHistory() async {
        let targetFolder = folderId ?? status?.config.folderId
        let histories = await service.calendarDayHistories(folderId: targetFolder)
        if !isTerminating {
            calendarHistory = histories
        }
    }

    private func refreshCalendarHistoryAsync() {
        Task { [weak self] in
            await self?.refreshCalendarHistory()
        }
    }

    func resolveFolder() async {
        guard !isResolvingFolder else { return }
        folderResolveAttempted = true
        isResolvingFolder = true
        defer { isResolvingFolder = false }
        do {
            folderId = try await service.resolveFolderId()
        } catch {
            showError("フォルダ「\(status?.config.folderName ?? "GeoFrame")」を解決できませんでした", error)
        }
    }

    // MARK: 写真ライブラリ

    func requestPhotosAccess() {
        Task {
            do {
                try await service.requestPhotosAccess()
            } catch let e as PhotoLibraryError {
                switch e {
                case .notAuthorized, .limitedAccess: break   // ヘッダーで案内する
                default: showError("写真ライブラリ", e)
                }
            } catch {
                showError("写真ライブラリ", error)
            }
            await refreshStatus()
        }
    }

    func openPhotosPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Google

    func signIn() {
        guard !isSigningIn else { return }
        isSigningIn = true
        signInCancelRequested = false
        signInTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.service.signIn()
                self.folderResolveAttempted = false
                self.isSigningIn = false
                await self.refreshStatus()
                if self.folderId != nil { self.showBanner(.info, "Google に接続しました") }
            } catch {
                self.isSigningIn = false
                if !self.signInCancelRequested && !Task.isCancelled {
                    self.showError("Google への接続に失敗しました", error)
                }
                await self.refreshStatus()
            }
        }
    }

    func cancelSignIn() {
        signInCancelRequested = true
        signInTask?.cancel()
    }

    func signOut() {
        Task {
            cancelAutoPrecheck()
            await service.signOut()
            cancelAutoPrecheck()
            folderId = nil
            prechecks = [:]
            folderResolveAttempted = false
            await refreshStatus()
            showBanner(.info, "ログアウトしました")
        }
    }

    func openAppSupportDir() {
        guard let dir = status?.appSupportDir else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: dir, isDirectory: true))
    }

    // MARK: 読み込み

    func load() {
        guard !isBusy, !isTerminating else { return }
        let range = LocalTime.dayRange(from: fromDate, to: toDate)
        cancelAutoPrecheck()
        cancelBackgroundAnalysis()
        loadGeneration &+= 1
        let loadGen = loadGeneration
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                let loaded = try await service.loadItems(start: range.start, end: range.end)
                guard !isTerminating, loadGeneration == loadGen else { return }
                cachedEntries = await service.cachedEntries(for: loaded)
                let cachedQ = await service.cachedQuality(for: loaded)
                guard !isTerminating, loadGeneration == loadGen else { return }
                items = loaded
                qualityMetrics = cachedQ
                hasLoaded = true
                cancelAutoPrecheck()
                selection = []
                lastClickedId = nil
                collapsedSectionIds = []
                closeComparison()
                results = [:]
                prechecks = [:]
                livePhases = [:]
                lastSummary = nil
                lastRunItems = []
                recomputeSections()
                recomputeGroupings()
                startBackgroundQualityAnalysis(generation: analysisGeneration, items: loaded, cached: cachedQ)
                schedulePlaceResolution(generation: analysisGeneration)
            } catch {
                if !isTerminating && loadGeneration == loadGen {
                    showError("写真を読み込めませんでした", error)
                }
            }
            if !isTerminating {
                await refreshStatus()
            }
        }
    }

    // MARK: 選択

    func isSelectable(_ item: PhotoItem) -> Bool { item.eligibility.isEligible && !isBusy }

    func toggle(_ item: PhotoItem, shiftPressed: Bool = false) {
        guard isSelectable(item) else { return }
        if shiftPressed {
            let ordered = orderedVisibleSelectableIds
            let anchorValid = lastClickedId.map { ordered.contains($0) } ?? false
            let anchorState = anchorValid ? selection.contains(lastClickedId!) : true
            let next = SelectionPlanner.shiftRange(
                orderedSelectableIds: ordered,
                anchorId: lastClickedId,
                targetId: item.id,
                anchorTargetState: anchorState,
                currentSelection: selection
            )
            selection = next
            if !anchorValid { lastClickedId = item.id }
            return
        }
        if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
        lastClickedId = item.id
    }

    func selectAll() {
        guard !isBusy else { return }
        // 送信済み・重複（Drive に既存）とみなせるものは選ばない（手動では選べる）
        selection = Set(visibleItems.filter { $0.eligibility.isEligible && !isDone($0) }.map(\.id))
        lastClickedId = nil
    }

    func deselectAll() {
        guard !isBusy else { return }
        selection = []
        lastClickedId = nil
    }

    func selectFavorites() {
        guard !isBusy else { return }
        selection = Set(visibleItems.filter { $0.eligibility.isEligible && $0.isFavorite && !isDone($0) }.map(\.id))
        lastClickedId = nil
        notifyLargeAutoPrecheckIfNeeded(count: selection.count)
    }

    func selectRecommendedAll() {
        guard !isBusy, isAnalysisComplete else { return }
        let rec = recommendedAllIds
        selection = rec
        lastClickedId = nil
        notifyLargeAutoPrecheckIfNeeded(count: rec.count)
    }

    func selectRecommended(in section: PhotoSection) {
        guard !isBusy, isAnalysisComplete else { return }
        let ids = recommendedIds(in: section)
        let addedCount = ids.subtracting(selection).count
        selection.formUnion(ids)
        notifyLargeAutoPrecheckIfNeeded(count: addedCount)
    }

    func selectAll(in section: PhotoSection) {
        guard !isBusy else { return }
        let ids = Set(visibleItems(in: section).filter { $0.eligibility.isEligible && !isDone($0) }.map(\.id))
        let addedCount = ids.subtracting(selection).count
        selection.formUnion(ids)
        notifyLargeAutoPrecheckIfNeeded(count: addedCount)
    }

    func deselectAll(in section: PhotoSection) {
        guard !isBusy else { return }
        selection.subtract(section.items.map(\.id))
    }

    func editableIds(for cluster: SimilarityCluster, visibleMembers: [PhotoItem]) -> [String] {
        let visibleSet = Set(visibleMembers.map(\.id))
        return cluster.rankedOrder.filter { id in
            guard visibleSet.contains(id), let item = items.first(where: { $0.id == id }) else { return false }
            return isSelectable(item) && (!hideDone || !isDone(item))
        }
    }

    func openComparison(cluster: SimilarityCluster, editableIds: [String]) {
        guard !isBusy, !editableIds.isEmpty else { return }
        comparingEditableIds = editableIds
        comparingCluster = cluster
    }

    func closeComparison() {
        comparingCluster = nil
        comparingEditableIds = []
    }

    func applyClusterComparison(cluster: SimilarityCluster, editableIds: [String], selectedIds: Set<String>) {
        guard !isBusy else { return }
        let validEditable = Set(editableIds.filter { id in
            guard let item = items.first(where: { $0.id == id }) else { return false }
            return isSelectable(item) && (!hideDone || !isDone(item))
        })
        var next = selection
        for id in validEditable {
            if selectedIds.contains(id) { next.insert(id) } else { next.remove(id) }
        }
        selection = next
        closeComparison()
    }

    private func notifyLargeAutoPrecheckIfNeeded(count: Int) {
        if autoPrecheckEnabled && canAutoPrecheck && count > Self.confirmThreshold {
            showBanner(.info, "\(count) 件を選択しました。自動重複確認を順次実行します（時間がかかる場合はオフにできます）。")
        }
    }

    // MARK: セクション・類似グルーピング・地名解決

    private func recomputeSections() {
        sections = PhotoSectioner.section(items: items, options: sectionOptions)
    }

    /// 表示モード（フラット / セクション）に関わらず、常に場所・時間枠単位で類似判定と推奨順位を保つ。
    private func recomputeGroupings() {
        var map: [String: SectionGroupingResult] = [:]
        for sec in sections {
            map[sec.id] = SimilarityGrouper.group(
                sectionId: sec.id,
                sectionItems: sec.items,
                metricsById: qualityMetrics
            )
        }
        sectionGroupings = map
    }

    private func cancelBackgroundAnalysis() {
        analysisGeneration &+= 1
        analysisTask?.cancel()
        analysisTask = nil
        placeDebounceTask?.cancel()
        placeDebounceTask = nil
        placeResolutionTask?.cancel()
        placeResolutionTask = nil
        analysisProgress = nil
        Task { await service.cancelPlaceResolution() }
    }

    private func startBackgroundQualityAnalysis(generation gen: Int, items: [PhotoItem],
                                                cached: [String: QualityMetrics]) {
        let targets = items.filter { $0.eligibility.isEligible && cached[$0.localIdentifier] == nil }
        guard !targets.isEmpty else {
            analysisProgress = nil
            return
        }
        let total = targets.count
        analysisProgress = (0, total)
        let svc = service
        analysisTask = Task { [weak self] in
            var done = 0
            var pendingSave: [(item: PhotoItem, metrics: QualityMetrics)] = []
            var nextIdx = 0
            let maxConcurrent = 4

            await withTaskGroup(of: (PhotoItem, QualityMetrics?).self) { group in
                while nextIdx < min(maxConcurrent, total) {
                    let it = targets[nextIdx]
                    nextIdx += 1
                    group.addTask { (it, await svc.analyzeQuality(for: it)) }
                }

                while let (item, metrics) = await group.next() {
                    if Task.isCancelled { break }
                    done += 1
                    if let metrics {
                        pendingSave.append((item, metrics))
                        await MainActor.run { [weak self] in
                            guard let self, self.analysisGeneration == gen else { return }
                            self.qualityMetrics[item.localIdentifier] = metrics
                        }
                    }
                    let currentDone = done
                    await MainActor.run { [weak self] in
                        guard let self, self.analysisGeneration == gen else { return }
                        self.analysisProgress = (currentDone, total)
                        if currentDone % 8 == 0 { self.recomputeGroupings() }
                    }
                    if pendingSave.count >= 20 {
                        let batch = pendingSave
                        pendingSave = []
                        await svc.saveQualityBatch(batch)
                    }
                    if nextIdx < total && !Task.isCancelled {
                        let nextItem = targets[nextIdx]
                        nextIdx += 1
                        group.addTask { (nextItem, await svc.analyzeQuality(for: nextItem)) }
                    }
                }
            }

            if !pendingSave.isEmpty {
                await svc.saveQualityBatch(pendingSave)
            }
            await MainActor.run { [weak self] in
                guard let self, self.analysisGeneration == gen else { return }
                self.analysisProgress = nil
                self.analysisTask = nil
                self.recomputeGroupings()
            }
        }
    }

    private func schedulePlaceResolution(generation gen: Int) {
        placeDebounceTask?.cancel()
        placeResolutionTask?.cancel()
        guard geocodeEnabled, !sections.isEmpty else { return }

        var uniqueCoords: [(key: String, loc: PhotoLocation)] = []
        var seen = Set<String>()
        for sec in sections {
            guard let key = sec.locationKey, let loc = sec.representativeLocation,
                  !seen.contains(key), placeNames[key] == nil else { continue }
            seen.insert(key)
            uniqueCoords.append((key, loc))
        }
        guard !uniqueCoords.isEmpty else { return }

        let svc = service
        placeDebounceTask = Task { [weak self] in
            // 閾値変更の連打時は 200ms 待ってから問い合わせる
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.analysisGeneration == gen else { return }
                self.placeResolutionTask = Task { [weak self] in
                    for (key, loc) in uniqueCoords {
                        if Task.isCancelled { return }
                        let outcome = await svc.resolvePlaceOutcome(for: loc)
                        switch outcome {
                        case .resolved(let name):
                            await MainActor.run { [weak self] in
                                guard let self, self.analysisGeneration == gen else { return }
                                self.placeNames[key] = name
                            }
                        case .notFound:
                            continue
                        case .failed, .cancelled:
                            return
                        }
                    }
                }
            }
        }
    }

    // MARK: 重複確認（送信しない）

    func precheck() {
        let snapshot = selectedItems
        guard canPrecheck, !snapshot.isEmpty else { return }
        cancelAutoPrecheck()
        isPrechecking = true
        cancelRequested = false
        isCancelling = false
        for it in snapshot { prechecks[it.id] = nil }
        progress = RunProgress(kind: .precheck, done: 0, current: 0, total: snapshot.count)
        precheckTask = Task { [weak self] in
            guard let self else { return }
            do {
                let r = try await self.service.precheckDuplicates(items: snapshot) { done, total in
                    Task { @MainActor in self.updatePrecheckProgress(done: done, total: total) }
                }
                for x in r { self.prechecks[x.localIdentifier] = x }
                if self.hideDone { self.pruneHiddenSelection() }
                let toUpload = r.filter { $0.decision == .toUpload }.count
                let dup = r.filter {
                    switch $0.decision {
                    case .duplicateRemote, .duplicateInBatch: return true
                    default: return false
                    }
                }.count
                let unknown = r.filter { $0.decision == .notHashed }.count
                var msg = "重複確認（目安）: 送信予定 \(toUpload) 件 / 重複の見込み \(dup) 件"
                if unknown > 0 { msg += " / 判定できず \(unknown) 件" }
                msg += "。送信時にも改めて照合します。"
                self.showBanner(unknown > 0 ? .warning : .info, msg)
            } catch {
                if self.cancelRequested || Task.isCancelled {
                    self.showBanner(.info, "重複確認を中止しました")
                } else {
                    self.showError("重複確認に失敗しました", error)
                }
            }
            self.isPrechecking = false
            self.isCancelling = false
            self.progress = nil
            self.precheckTask = nil
            await self.refreshCalendarHistory()
        }
    }

    private func updatePrecheckProgress(done: Int, total: Int) {
        guard isPrechecking, var p = progress, p.kind == .precheck else { return }
        guard done >= p.done else { return }
        p.done = done
        p.current = min(done + 1, total)
        p.total = total
        progress = p
    }

    // MARK: 送信

    /// 「送信」ボタン。20 件を超えるときは確認ダイアログを出し、ユーザーの承認後にだけ送る。
    func requestSend() {
        let snapshot = selectedItems
        guard canSend, !snapshot.isEmpty else { return }
        if snapshot.count > Self.confirmThreshold {
            pendingSend = snapshot
            showSendConfirm = true
        } else {
            startUpload(snapshot)
        }
    }

    func confirmPendingSend(_ items: [PhotoItem]) {
        showSendConfirm = false
        pendingSend = []
        startUpload(items)
    }

    func cancelPendingSend() {
        showSendConfirm = false
        pendingSend = []
    }

    private func startUpload(_ snapshot: [PhotoItem]) {
        guard canSend, !snapshot.isEmpty else { return }
        cancelAutoPrecheck()
        closeComparison()
        isSending = true
        showSendPanel = true
        runError = nil
        runWasCancelled = false
        sendRun = SendRunState(order: snapshot.map(\.id))
        cancelRequested = false
        isCancelling = false
        lastSummary = nil
        lastRunItems = snapshot
        for it in snapshot {
            results[it.id] = nil
            livePhases[it.id] = nil
        }
        progress = RunProgress(kind: .upload, done: 0, current: 0, total: snapshot.count)
        // 上限はユーザーが承認した件数そのもの
        let (events, summaryTask) = service.uploadStream(items: snapshot, maxItemsPerRun: snapshot.count)
        uploadSummaryTask = summaryTask
        Task { [weak self] in
            // AsyncStream を MainActor 上で順に消費する（イベント順を保つ）
            for await ev in events { self?.apply(ev) }
            do {
                let s = try await summaryTask.value
                self?.finishRun(s)
            } catch {
                self?.failRun(error)
            }
        }
    }

    private func apply(_ ev: UploadEvent) {
        let id = ev.localIdentifier
        if var r = sendRun, r.apply(ev) { sendRun = r }
        if var p = progress, p.kind == .upload {
            p.current = ev.index + 1
            p.total = ev.total
            if case .finished = ev.phase { p.done = ev.index + 1 }
            if p != progress { progress = p }
        }
        switch ev.phase {
        case .exporting: livePhases[id] = .exporting
        case .checkingDuplicate: livePhases[id] = .checkingDuplicate
        case .uploading(let f):
            let pct = max(0, min(100, Int((f * 100).rounded(.down))))
            if livePhases[id] != .uploading(percent: pct) { livePhases[id] = .uploading(percent: pct) }
        case .verifying: livePhases[id] = .verifying
        case .finished(let r):
            livePhases[id] = nil
            results[id] = r
        }
    }

    private func finishRun(_ s: RunSummary) {
        runWasCancelled = s.cancelled || cancelRequested
        for r in s.results { results[r.localIdentifier] = r }
        lastSummary = s
        endRun()
        if s.cancelled || cancelRequested {
            showBanner(.info, "送信を中止しました（処理済み \(s.results.filter { !$0.wasCancelled }.count) 件）")
        } else if s.failedCount > 0 {
            showBanner(.warning, "送信が完了しました。失敗が \(s.failedCount) 件あります（再送せず内容を確認してください）")
        } else {
            showBanner(.info, "送信が完了しました")
        }
    }

    private func failRun(_ error: Error) {
        let wasCancel = cancelRequested
        runWasCancelled = wasCancel
        endRun()
        if wasCancel {
            runError = "送信を中止しました"
            showBanner(.info, "送信を中止しました")
        } else {
            runError = "送信できませんでした: \(Redactor.redact(error.localizedDescription))"
            showError("送信できませんでした", error)
        }
    }

    private func endRun() {
        livePhases = [:]
        progress = nil
        isSending = false
        isCancelling = false
        uploadSummaryTask = nil
        // 「アップロード済みだが未検証」の失敗を誤って再送しないよう、選択は解除する
        selection = []
        refreshCalendarHistoryAsync()
    }

    /// 「中止」: 実行中の送信または重複確認を止める。
    func cancelRun() {
        cancelRequested = true
        isCancelling = true
        uploadSummaryTask?.cancel()
        precheckTask?.cancel()
    }

    // MARK: 終了

    /// 終了・ウィンドウを閉じる前に確認が要る処理（送信・手動の重複確認）。
    var needsQuitConfirmation: Bool { isSending || isPrechecking }

    /// 終了前に止めて待つ処理（自動の重複確認を含む。一時ファイルの削除まで待つ）。
    var hasActiveWork: Bool {
        needsQuitConfirmation || uploadSummaryTask != nil || precheckTask != nil
            || autoItemTask != nil || autoWorkerTask != nil
    }

    /// 終了確認の文言。
    var quitConfirmationMessage: String {
        isSending ? "送信中です。中止して終了しますか？" : "重複を確認中です。中止して終了しますか？"
    }

    func cancelBackgroundWorkForImmediateTerminate() {
        isTerminating = true
        loadGeneration &+= 1
        cancelBackgroundAnalysis()
    }

    /// 終了のため、実行中の送信・重複確認を中止し、終わる（記録の書き込みと一時ファイルの削除）まで最大 `timeout` 秒待つ。
    /// 時間内に終わったら真。
    @discardableResult
    func stopForTermination(timeout: TimeInterval = 15) async -> Bool {
        isTerminating = true
        loadGeneration &+= 1
        let upload = uploadSummaryTask
        let pre = precheckTask
        let autoItem = autoItemTask
        let autoWorker = autoWorkerTask
        if upload != nil || pre != nil { cancelRun() }
        cancelAutoPrecheck()
        cancelBackgroundAnalysis()
        let finished = await Self.wait(timeout: timeout) {
            _ = try? await upload?.value
            await pre?.value
            _ = try? await autoItem?.value
            await autoWorker?.value
        }
        if !finished { NSLog("GeoFrameUploader: 終了待ちが \(Int(timeout)) 秒を超えたため、そのまま終了します") }
        return finished
    }

    /// `work` が終わるか `timeout` 秒経つまで待つ（`Task.value` の待ちは中止で抜けないので、先に来た方で再開する）。
    private static func wait(timeout: TimeInterval, _ work: @escaping @Sendable () async -> Void) async -> Bool {
        let once = ResumeOnce()
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            once.set(cont)
            Task.detached {
                await work()
                once.resume(true)
            }
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                once.resume(false)
            }
        }
    }

    // MARK: 記録

    func revealRecords() {
        guard let path = recordsFile else { return }
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    /// 送信パネルの「閉じる」（送信中は閉じない）。
    func closeSendPanel() {
        guard !isSending else { return }
        showSendPanel = false
        sendRun = nil
        runError = nil
    }

    // MARK: 選んだら自動で重複確認

    /// このセッションの Drive 一覧で判定済みの写真。
    private var settledIds: Set<String> {
        Set(items.lazy.map(\.id).filter {
            AutoPrecheckQueue.isSettled(precheck: self.prechecks[$0], result: self.results[$0])
        })
    }

    var canAutoPrecheck: Bool { googleReady && photosAuthorized && !isSigningIn }

    private func selectionDidChange(from old: Set<String>) {
        guard autoPrecheckEnabled else { return }
        guard canAutoPrecheck, !isSending, !isPrechecking, !isLoading else {
            if !autoQueue.isIdle { cancelAutoPrecheck() }
            return
        }
        let added = AutoPrecheckQueue.candidates(items: items, oldSelection: old, newSelection: selection,
                                                 settled: settledIds)
        if autoQueue.selectionChanged(selection: selection, added: added) {
            // 処理中の写真が選択から外れた
            autoItemTask?.cancel()
        }
        updateAutoProgress()
        guard !autoQueue.isIdle, autoWorkerTask == nil else { return }
        // 続けて選んだときはまとめて始める
        autoDebounceTask?.cancel()
        let gen = autoGeneration
        autoDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.autoDebounceNanoseconds)
            guard !Task.isCancelled, let self, self.autoGeneration == gen else { return }
            self.autoDebounceTask = nil
            self.startAutoWorker()
        }
    }

    private func startAutoWorker() {
        guard autoWorkerTask == nil, !autoQueue.isIdle else { return }
        let gen = autoGeneration
        autoWorkerTask = Task { [weak self] in
            await self?.runAutoWorker(generation: gen)
        }
    }

    private func runAutoWorker(generation gen: Int) async {
        defer { if autoGeneration == gen { autoWorkerTask = nil } }
        while autoGeneration == gen, let id = autoQueue.next() {
            updateAutoProgress()
            guard let item = items.first(where: { $0.id == id }), selection.contains(id) else {
                finishAutoItem(id, counted: false)
                continue
            }
            // 既に MD5 が分かっている他の選択中の写真（表示順）。同じ MD5 なら先に選ばれていた方を残す
            let prior: [PlanInput] = items.compactMap { it in
                guard it.id != id, selection.contains(it.id),
                      let md5 = prechecks[it.id]?.md5 ?? results[it.id]?.md5 else { return nil }
                return PlanInput(localIdentifier: it.id, eligibility: it.eligibility, md5: md5)
            }
            let svc = service
            let t = Task { try await svc.autoPrecheck(item: item, priorSelected: prior) }
            autoItemTask = t
            do {
                let r = try await t.value
                guard autoGeneration == gen else { return }
                autoItemTask = nil
                if !selection.contains(id) {
                    // 確認中に外された（ハッシュはキャッシュに残る）
                    finishAutoItem(id, counted: false)
                    continue
                }
                prechecks[id] = r
                if AutoPrecheckQueue.shouldDeselect(r.decision) {
                    autoDeselectedNames.append(item.driveName)
                    selection.remove(id)
                } else if hideDone {
                    pruneHiddenSelection()
                }
                finishAutoItem(id, counted: true)
            } catch {
                guard autoGeneration == gen else { return }
                autoItemTask = nil
                if error is CancellationError || Task.isCancelled || (error as? URLError)?.code == .cancelled {
                    finishAutoItem(id, counted: false)
                    continue
                }
                // Drive 一覧・認証の失敗。残りも同じ理由で失敗するので止める
                showError("自動の重複確認に失敗しました", error)
                cancelAutoPrecheck()
                return
            }
        }
    }

    private func finishAutoItem(_ id: String, counted: Bool) {
        if autoQueue.finish(id, counted: counted) {
            if let msg = AutoPrecheckText.deselectedBanner(names: autoDeselectedNames) { showBanner(.info, msg) }
            autoDeselectedNames = []
        }
        if counted { refreshCalendarHistoryAsync() }
        updateAutoProgress()
    }

    private func updateAutoProgress() {
        if autoCheckingId != autoQueue.inFlight { autoCheckingId = autoQueue.inFlight }
        let p = autoQueue.progress
        if p?.current != autoProgress?.current || p?.total != autoProgress?.total { autoProgress = p }
    }

    /// 自動確認をすべて止める（読み込み・ログアウト・送信・手動の重複確認・オフ）。
    func cancelAutoPrecheck() {
        autoGeneration &+= 1
        autoDebounceTask?.cancel()
        autoDebounceTask = nil
        autoItemTask?.cancel()
        autoItemTask = nil
        autoWorkerTask?.cancel()
        autoWorkerTask = nil
        autoQueue.reset()
        autoDeselectedNames = []
        if autoProgress != nil { autoProgress = nil }
    }
}

/// 継続を 1 回だけ再開する。
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<Bool, Never>?
    private var result: Bool?

    func set(_ c: CheckedContinuation<Bool, Never>) {
        lock.lock()
        if let r = result { lock.unlock(); c.resume(returning: r); return }
        cont = c
        lock.unlock()
    }

    func resume(_ value: Bool) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value
        let c = cont
        cont = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}

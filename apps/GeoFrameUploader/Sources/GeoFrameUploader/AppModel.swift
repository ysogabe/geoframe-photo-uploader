import AppKit
import SwiftUI
import UploaderCore

enum DateMode: String, CaseIterable, Identifiable {
    case single = "単日"
    case range = "期間"
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

    // 日付
    @Published var dateMode: DateMode = .single
    @Published var fromDate = Date()
    @Published var toDate = Date()

    // 一覧
    @Published private(set) var items: [PhotoItem] = []
    @Published private(set) var hasLoaded = false
    @Published private(set) var isLoading = false
    @Published private(set) var selection: Set<String> = []

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
        self.service = service
        self.thumbnails = ThumbnailCache(service: service)
    }

    // MARK: 派生値

    var isBusy: Bool { isSending || isPrechecking || isLoading }
    var photosAuthorized: Bool { status?.photosAuthorization == .authorized }
    var googleReady: Bool {
        guard let s = status else { return false }
        return s.oauthClientValid && s.signedIn
    }
    var eligibleCount: Int { items.filter { $0.eligibility.isEligible }.count }
    var ineligibleCount: Int { items.count - eligibleCount }
    var selectedItems: [PhotoItem] { items.filter { selection.contains($0.id) } }
    var canSend: Bool { !isBusy && !selection.isEmpty && googleReady && photosAuthorized && !isSigningIn }
    var canPrecheck: Bool { canSend }
    var recordsFile: String? { status?.recordsFile }

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
            folderId = nil
            folderResolveAttempted = false
            return
        }
        if let id = s.config.folderId { folderId = id }
        if folderId == nil && !folderResolveAttempted && !isSigningIn {
            await resolveFolder()
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
            await service.signOut()
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
        guard !isBusy else { return }
        let to = dateMode == .single ? fromDate : toDate
        let range = LocalTime.dayRange(from: fromDate, to: to)
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                let loaded = try await service.loadItems(start: range.start, end: range.end)
                items = loaded
                hasLoaded = true
                selection = []
                results = [:]
                prechecks = [:]
                livePhases = [:]
                lastSummary = nil
                lastRunItems = []
            } catch {
                showError("写真を読み込めませんでした", error)
            }
            await refreshStatus()
        }
    }

    // MARK: 選択

    func isSelectable(_ item: PhotoItem) -> Bool { item.eligibility.isEligible && !isBusy }

    func toggle(_ item: PhotoItem) {
        guard isSelectable(item) else { return }
        if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
    }

    func selectAll() {
        guard !isBusy else { return }
        selection = Set(items.filter { $0.eligibility.isEligible }.map(\.id))
    }

    func deselectAll() {
        guard !isBusy else { return }
        selection = []
    }

    // MARK: 重複確認（送信しない）

    func precheck() {
        let snapshot = selectedItems
        guard canPrecheck, !snapshot.isEmpty else { return }
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
        isSending = true
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
        endRun()
        if wasCancel {
            showBanner(.info, "送信を中止しました")
        } else {
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
    }

    /// 「中止」: 実行中の送信または重複確認を止める。
    func cancelRun() {
        cancelRequested = true
        isCancelling = true
        uploadSummaryTask?.cancel()
        precheckTask?.cancel()
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

    func dismissSummary() { lastSummary = nil }
}

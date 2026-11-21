import AppKit
import SwiftUI
import UploaderCore

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HeaderView()
            if let banner = model.banner {
                BannerView(banner: banner) { model.dismissBanner() }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            DateFilterView()
            Divider()
            PhotoGridView()
            if let summary = model.lastSummary {
                Divider()
                ResultSummaryView(summary: summary)
            }
            Divider()
            ActionBarView()
        }
        .animation(.easeInOut(duration: 0.2), value: model.banner)
        .task { await model.refreshStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refreshStatus() }
        }
        .alert("\(model.pendingSend.count) 件を送信します", isPresented: $model.showSendConfirm,
               presenting: model.pendingSend) { items in
            Button("\(items.count) 件を送信") { model.confirmPendingSend(items) }
            Button("キャンセル", role: .cancel) { model.cancelPendingSend() }
        } message: { items in
            Text("選択が \(AppModel.confirmThreshold) 件を超えています。\(items.count) 件の原本をそのまま Google ドライブ「\(model.status?.config.folderName ?? "GeoFrame")」へ順に送信します。")
        }
    }
}

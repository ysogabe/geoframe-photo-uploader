import AppKit
import SwiftUI
import UploaderCore

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            mainContent
                .disabled(model.showSendPanel || model.showComparePanel)
                .accessibilityHidden(model.showSendPanel || model.showComparePanel)
            if model.showSendPanel {
                // 一覧を触れないように覆う（送信中・結果表示中）
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {}
                    .transition(.opacity)
                SendPanelView()
                    .padding(24)
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
                    .zIndex(1)
            } else if model.showComparePanel, let cluster = model.comparingCluster {
                Color.black.opacity(0.42)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { model.closeComparison() }
                    .transition(.opacity)
                SimilarCompareView(cluster: cluster, editableIds: model.comparingEditableIds)
                    .padding(20)
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: model.showSendPanel)
        .animation(.easeInOut(duration: 0.15), value: model.showComparePanel)
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
        .sheet(item: $model.locationPickerRequest) { req in
            LocationPickerView(request: req)
                .environmentObject(model)
        }
    }

    private var mainContent: some View {
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
            Divider()
            ActionBarView()
        }
        .animation(.easeInOut(duration: 0.2), value: model.banner)
        .alert("位置情報がない写真が \(model.pendingMissingLocationItems.count) 件含まれています",
               isPresented: $model.showMissingLocationSendConfirm,
               presenting: model.pendingSend) { items in
            Button("位置を設定する…") { model.openLocationPickerFromSendWarning() }
            Button("このまま \(items.count) 件を送信") { model.confirmPendingSend(items) }
            Button("キャンセル", role: .cancel) { model.cancelPendingSend() }
        } message: { items in
            Text("選択中の \(items.count) 件のうち \(model.pendingMissingLocationItems.count) 件に位置情報がありません。GEOFRAME では位置情報がない写真は表示されないため、必要であれば送信前に位置を補完できます。")
        }
    }
}

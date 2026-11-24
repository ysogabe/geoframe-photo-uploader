import CoreLocation
import MapKit
import SwiftUI
import UploaderCore

/// 位置情報がない写真に対して位置を補完するモーダルシート（既存位置は上書きしない）。
struct LocationPickerView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let request: LocationPickerRequest

    @State private var pickedLocation: PhotoLocation?
    @State private var pickedSource: LocationSupplementSource = .uploaderManual
    @State private var pickedPlaceName: String?
    @State private var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 35.681236, longitude: 139.767125),
            span: MKCoordinateSpan(latitudeDelta: 1.5, longitudeDelta: 1.5)
        )
    )

    @State private var searchQuery = ""
    @State private var searchResults: [PlaceSearchHit] = []
    @State private var isSearching = false
    @State private var searchError: String?

    @State private var coordInput = ""
    @State private var coordError: String?

    @State private var writeBackToPhotos = false
    @State private var isApplying = false
    @State private var initialized = false

    private struct PlaceSearchHit: Identifiable {
        let id = UUID()
        let title: String
        let subtitle: String
        let location: PhotoLocation
    }

    private var candidates: [LocationCandidate] {
        model.locationCandidates(for: request.assignableItems, preferredSectionId: request.preferredSectionId)
    }

    private var hasAnyExistingOverride: Bool {
        request.assignableItems.contains { model.locationOverride(for: $0) != nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                leftSidebar
                    .frame(width: 310)
                Divider()
                mapPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(width: 860, height: 590)
        .onAppear {
            guard !initialized else { return }
            initialized = true
            configureInitialState()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("位置情報を補完（対象 \(request.assignableItems.count) 枚）")
                    .font(.title3.weight(.semibold))
                Text("既存の位置情報（原本 EXIF / 写真アプリ）は上書きしません。位置情報がない写真にのみ適用します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if request.skippedExistingCount > 0 {
                Text("既存位置あり \(request.skippedExistingCount) 枚を除外済み")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.14), in: Capsule())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var leftSidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                candidateSection
                Divider()
                searchSection
                Divider()
                coordinateSection
            }
            .padding(14)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
    }

    private var candidateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("1. 同日・近接セクションから選ぶ")
                .font(.subheadline.weight(.semibold))
            if candidates.isEmpty {
                Text("読み込み範囲内に位置情報付きのセクションがありません。地名検索・地図クリック・座標入力をご利用ください。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(candidates) { c in
                        let selected = pickedLocation == c.location
                        Button {
                            selectLocation(c.location, source: .uploaderBorrowed, placeName: c.title, span: 0.012)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: selected ? "checkmark.circle.fill" : "mappin.and.ellipse")
                                    .foregroundStyle(selected ? Color.accentColor : Color.red)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(c.title)
                                        .font(.callout.weight(.medium))
                                        .lineLimit(1)
                                    Text(c.subtitle)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(selected ? Color.accentColor.opacity(0.14) : Color(nsColor: .windowBackgroundColor))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 7)
                                    .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.22))
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var searchSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("2. 地名・施設名を検索")
                .font(.subheadline.weight(.semibold))
            HStack(spacing: 6) {
                TextField("例: 東京駅、上高地", text: $searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { runPlaceSearch() }
                Button("検索") { runPlaceSearch() }
                    .disabled(isSearching || searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if isSearching {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("検索中…").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let searchError {
                Text(searchError).font(.caption).foregroundStyle(.orange)
            }
            if !searchResults.isEmpty {
                VStack(spacing: 4) {
                    ForEach(searchResults) { hit in
                        Button {
                            selectLocation(hit.location, source: .uploaderManual, placeName: hit.title, span: 0.012)
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(hit.title)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                if !hit.subtitle.isEmpty {
                                    Text(hit.subtitle)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.2)))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var coordinateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("3. 緯度・経度を直接入力")
                .font(.subheadline.weight(.semibold))
            HStack(spacing: 6) {
                TextField("例: 35.681236, 139.767125", text: $coordInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { applyManualCoordInput() }
                Button("反映") { applyManualCoordInput() }
            }
            if let coordError {
                Text(coordError)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                Text("Google マップの座標や @lat,lon URL も貼り付けできます")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var mapPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "hand.tap")
                    .foregroundStyle(.secondary)
                Text("地図上をクリックしてピン位置を指定できます")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let loc = pickedLocation {
                    Text(String(format: "%.6f, %.6f", loc.lat, loc.lon))
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.14), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                } else {
                    Text("未選択")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .windowBackgroundColor))

            MapReader { proxy in
                Map(position: $cameraPosition) {
                    ForEach(Array(candidates.prefix(15))) { cand in
                        Marker(cand.title, coordinate: CLLocationCoordinate2D(latitude: cand.location.lat, longitude: cand.location.lon))
                            .tint(.red)
                    }
                    if let picked = pickedLocation {
                        Marker(pickedPlaceName ?? "選択した位置",
                               coordinate: CLLocationCoordinate2D(latitude: picked.lat, longitude: picked.lon))
                            .tint(.blue)
                    }
                }
                .mapStyle(.standard)
                .onTapGesture { point in
                    if let coord = proxy.convert(point, from: .local) {
                        let loc = PhotoLocation(lat: coord.latitude, lon: coord.longitude)
                        if PhotoSectioner.isValidCoordinate(loc) {
                            selectLocation(loc, source: .uploaderManual, placeName: nil, recenter: false)
                        }
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Apple Photos にも位置情報を書き戻す", isOn: $writeBackToPhotos)
                    .toggleStyle(.checkbox)
                Text("位置情報がない写真にのみ書き込みます（既存位置は上書きしません）。iCloud 写真で他端末にも反映されます。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if hasAnyExistingOverride {
                Button("補完をクリア") {
                    isApplying = true
                    Task {
                        await model.clearLocationOverrides(for: request.assignableItems)
                        isApplying = false
                        dismiss()
                    }
                }
                .disabled(isApplying)
            }
            Button("キャンセル") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(isApplying)

            Button {
                guard let loc = pickedLocation else { return }
                isApplying = true
                Task {
                    await model.applyLocationSupplement(
                        items: request.assignableItems,
                        location: loc,
                        source: pickedSource,
                        placeName: pickedPlaceName,
                        writeBackToPhotos: writeBackToPhotos
                    )
                    isApplying = false
                    dismiss()
                }
            } label: {
                if isApplying {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("適用中…")
                    }
                } else {
                    Text("この位置を適用（\(request.assignableItems.count) 件）")
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(pickedLocation == nil || isApplying)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func configureInitialState() {
        let existingOverrides = request.assignableItems.compactMap { model.locationOverride(for: $0) }
        if existingOverrides.count == request.assignableItems.count,
           let first = existingOverrides.first,
           existingOverrides.allSatisfy({ $0.location == first.location }) {
            selectLocation(first.location, source: first.source, placeName: first.placeName, span: 0.01)
            return
        }
        if let firstCand = candidates.first {
            cameraPosition = .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: firstCand.location.lat, longitude: firstCand.location.lon),
                span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
            ))
        }
    }

    private func selectLocation(
        _ loc: PhotoLocation,
        source: LocationSupplementSource,
        placeName: String?,
        span: CLLocationDegrees = 0.015,
        recenter: Bool = true
    ) {
        pickedLocation = loc
        pickedSource = source
        pickedPlaceName = placeName
        coordError = nil
        coordInput = "\(DriveLocationProperties.formatCoordinate(loc.lat)), \(DriveLocationProperties.formatCoordinate(loc.lon))"
        if recenter {
            cameraPosition = .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: loc.lat, longitude: loc.lon),
                span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span)
            ))
        }
    }

    private func applyManualCoordInput() {
        guard let loc = DriveLocationProperties.parseCoordinateString(coordInput) else {
            coordError = "緯度, 経度 の形式で有効な範囲（-90〜90, -180〜180）を入力してください"
            return
        }
        selectLocation(loc, source: .uploaderManual, placeName: nil, span: 0.012)
    }

    private func runPlaceSearch() {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        isSearching = true
        searchError = nil
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = query
        Task {
            do {
                let resp = try await MKLocalSearch(request: req).start()
                let hits = resp.mapItems.prefix(6).compactMap { item -> PlaceSearchHit? in
                    let c = item.placemark.coordinate
                    let loc = PhotoLocation(lat: c.latitude, lon: c.longitude)
                    guard PhotoSectioner.isValidCoordinate(loc) else { return nil }
                    let title = item.name ?? item.placemark.title ?? query
                    let subtitle = item.placemark.title ?? ""
                    return PlaceSearchHit(title: title, subtitle: subtitle == title ? "" : subtitle, location: loc)
                }
                searchResults = hits
                if hits.isEmpty {
                    searchError = "該当する場所が見つかりませんでした"
                }
            } catch {
                searchResults = []
                searchError = "検索に失敗しました: \(error.localizedDescription)"
            }
            isSearching = false
        }
    }
}

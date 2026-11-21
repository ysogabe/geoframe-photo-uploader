import AppKit
import SwiftUI
import UploaderCore

/// 1 枚分のセル。表示に必要な値だけを受け取る。
struct PhotoCell: View {
    let item: PhotoItem
    let isSelected: Bool
    let isSelectable: Bool
    let live: LivePhase?
    let result: ItemResult?
    let precheck: PrecheckResult?
    let duplicateNote: String?
    let thumbnails: ThumbnailCache
    let onToggle: () -> Void

    @State private var image: NSImage?

    private var eligible: Bool { item.eligibility.isEligible }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            thumbnail
            Text(item.originalFilename ?? item.localIdentifier)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(item.originalFilename ?? item.localIdentifier)
            HStack(spacing: 4) {
                Text(Self.timeText(item.creationDate))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                FormatBadge(text: Self.formatLabel(item))
                Spacer(minLength: 0)
                markers
            }
            if let reason = item.eligibility.reason {
                Text("対象外: \(reason)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(reason)
            }
            if let r = result, r.status == .failed, !r.wasCancelled, let err = r.error {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .help(err)
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .opacity(eligible ? 1 : 0.45)
        .contentShape(Rectangle())
        .onTapGesture { if isSelectable { onToggle() } }
        .task(id: item.id) {
            if let hit = thumbnails.cached(item.id) { image = hit; return }
            let img = await thumbnails.image(for: item.id)
            if !Task.isCancelled { image = img }
        }
    }

    // MARK: サムネイル

    private var thumbnail: some View {
        Color(nsColor: .quaternaryLabelColor)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: item.mediaKind == .video ? "video" : "photo")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .topLeading) { checkbox }
            .overlay(alignment: .bottom) { statusOverlay }
    }

    @ViewBuilder
    private var checkbox: some View {
        if eligible {
            Button(action: onToggle) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.9),
                                     isSelected ? Color.accentColor : Color.black.opacity(0.35))
                    .shadow(radius: 1)
            }
            .buttonStyle(.plain)
            .disabled(!isSelectable)
            .padding(6)
            .help(isSelected ? "選択を解除" : "選択")
        }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        if let live {
            LivePhaseBadge(phase: live).padding(6)
        } else if let result {
            ResultBadge(result: result, duplicateNote: duplicateNote).padding(6)
        } else if let precheck {
            PrecheckBadge(precheck: precheck, duplicateNote: duplicateNote).padding(6)
        }
    }

    @ViewBuilder
    private var markers: some View {
        HStack(spacing: 3) {
            if item.isFavorite {
                Image(systemName: "star.fill").foregroundStyle(.yellow).help("お気に入り")
            }
            if item.burstIdentifier != nil {
                Image(systemName: "square.stack.3d.down.right").help("バースト")
            }
            if item.isLivePhoto {
                Image(systemName: "livephoto").help("Live Photo（静止画のみ送信）")
            }
            if let loc = item.location {
                Image(systemName: "mappin.and.ellipse")
                    .foregroundStyle(.red)
                    .help(String(format: "位置情報あり（%.5f, %.5f）", loc.lat, loc.lon))
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    // MARK: 書式

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    static func timeText(_ date: Date?) -> String {
        guard let date else { return "--:--" }
        return timeFormatter.string(from: date)
    }

    static func formatLabel(_ item: PhotoItem) -> String {
        switch item.mediaKind {
        case .video: return "動画"
        case .audio: return "音声"
        case .image, .unknown: break
        }
        if let name = item.originalFilename {
            let ext = (name as NSString).pathExtension.uppercased()
            if !ext.isEmpty { return ext == "JPG" ? "JPEG" : ext }
        }
        switch item.uti {
        case "public.jpeg"?: return "JPEG"
        case "public.heic"?: return "HEIC"
        case "public.heif"?: return "HEIF"
        case "public.png"?: return "PNG"
        case "public.tiff"?: return "TIFF"
        case "com.adobe.raw-image"?: return "DNG"
        case let u?: return u.split(separator: ".").last.map { $0.uppercased() } ?? "?"
        case nil: return "?"
        }
    }
}

// MARK: - バッジ

struct FormatBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.18), in: RoundedRectangle(cornerRadius: 3))
    }
}

struct StatusBadge: View {
    let text: String
    let systemImage: String
    let color: Color
    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .foregroundStyle(.white)
            .background(color, in: Capsule())
            .shadow(radius: 1)
    }
}

struct LivePhaseBadge: View {
    let phase: LivePhase
    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text(phase.label).font(.caption2.weight(.semibold)).monospacedDigit()
            }
            if case .uploading(let p) = phase {
                ProgressView(value: Double(p), total: 100).progressViewStyle(.linear)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }
}

struct ResultBadge: View {
    let result: ItemResult
    let duplicateNote: String?

    var body: some View {
        switch result.status {
        case .sent:
            StatusBadge(text: result.verified ? "送信済み" : "送信済み（未検証）", systemImage: "checkmark.seal.fill",
                        color: .green)
                .help("検証済み。Drive fileId: \(result.driveFileId ?? "-")")
        case .skippedDuplicate:
            StatusBadge(text: "重複でスキップ", systemImage: "equal.circle.fill", color: .gray)
                .help(duplicateNote ?? "既存ファイルと同一")
        case .skippedIneligible:
            StatusBadge(text: "対象外", systemImage: "nosign", color: .gray)
                .help(result.error ?? "")
        case .failed:
            if result.wasCancelled {
                StatusBadge(text: "中止", systemImage: "stop.circle.fill", color: .orange)
                    .help("中止により処理しませんでした")
            } else {
                StatusBadge(text: "失敗", systemImage: "xmark.octagon.fill", color: .red)
                    .help(result.error ?? "失敗")
            }
        }
    }
}

/// 事前確認の結果（目安。送信の可否には使わない）。
struct PrecheckBadge: View {
    let precheck: PrecheckResult
    let duplicateNote: String?

    var body: some View {
        switch precheck.decision {
        case .toUpload:
            StatusBadge(text: "送信予定（目安）", systemImage: "arrow.up.circle", color: .blue.opacity(0.85))
                .help("事前確認では Drive に同じ内容のファイルはありませんでした")
        case .duplicateRemote, .duplicateInBatch:
            StatusBadge(text: "重複の見込み", systemImage: "equal.circle", color: .gray.opacity(0.9))
                .help(duplicateNote ?? "重複の見込み")
        case .notHashed:
            StatusBadge(text: "判定できず", systemImage: "questionmark.circle", color: .orange)
                .help(precheck.error ?? "原本の MD5 を計算できませんでした")
        case .ineligible:
            EmptyView()
        }
    }
}

import SwiftUI
import UploaderCore

/// 期間標準のツールバー（案A）と、2ヶ月見開き・大判レンジカレンダー（案B）ポップオーバー。
struct DateFilterView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showCalendar = false

    private var activePreset: DateRangePreset? {
        DateRangePreset.matching(from: model.fromDate, to: model.toDate)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    showCalendar.toggle()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "calendar")
                            .foregroundStyle(.tint)
                        Text(Self.rangeButtonText(from: model.fromDate, to: model.toDate))
                            .font(.system(size: 13.5, weight: .semibold).monospacedDigit())
                        Text("\(model.selectedDayCount)日間")
                            .font(.caption.weight(.bold).monospacedDigit())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.16), in: Capsule())
                            .foregroundStyle(.tint)
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(minHeight: 32)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(showCalendar ? Color.accentColor : Color.secondary.opacity(0.35),
                                          lineWidth: showCalendar ? 1.5 : 1)
                    )
                }
                .buttonStyle(.plain)
                .help("クリックして大きな2ヶ月カレンダー（ローカル送信・確認履歴付き）から期間を選択")
                .popover(isPresented: $showCalendar, arrowEdge: .bottom) {
                    RangeCalendarPopover(isPresented: $showCalendar)
                        .environmentObject(model)
                }

                HStack(spacing: 4) {
                    ForEach(DateRangePreset.toolbarPresets) { preset in
                        let selected = activePreset == preset
                        Button {
                            model.applyDatePreset(preset)
                        } label: {
                            Text(preset.shortLabel)
                                .font(.callout.weight(selected ? .semibold : .regular))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(selected ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.28), lineWidth: 1)
                                )
                                .foregroundStyle(selected ? Color.white : Color.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Spacer()

                Button {
                    model.load()
                } label: {
                    if model.isLoading {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("読み込み中…") }
                    } else {
                        Label("読み込む", systemImage: "arrow.down.circle")
                    }
                }
                .keyboardShortcut("r", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy)
            }

            if model.hasLoaded {
                HStack(spacing: 10) {
                    Picker("", selection: $model.groupingMode) {
                        ForEach(GroupingMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 196)

                    if model.groupingMode == .sectioned {
                        Menu {
                            ForEach([15, 30, 60], id: \.self) { m in
                                Button { model.timeGapMinutes = m } label: {
                                    HStack {
                                        Text("\(m) 分以上空いたら分割")
                                        if model.timeGapMinutes == m { Image(systemName: "checkmark") }
                                    }
                                }
                            }
                            Divider()
                            ForEach([100, 300, 1000], id: \.self) { d in
                                Button { model.distanceThresholdMeters = d } label: {
                                    HStack {
                                        Text(d >= 1000 ? "\(d / 1000) km 以上移動で分割" : "\(d) m 以上移動で分割")
                                        if model.distanceThresholdMeters == d { Image(systemName: "checkmark") }
                                    }
                                }
                            }
                        } label: {
                            Label("\(model.timeGapMinutes)分 / \(model.distanceThresholdMeters >= 1000 ? "1km" : "\(model.distanceThresholdMeters)m")",
                                  systemImage: "slider.horizontal.3")
                        }
                        .controlSize(.small)
                        .help("場所・時間枠を区切る時間差と移動距離のしきい値")

                        Toggle("地名を表示", isOn: $model.geocodeEnabled)
                            .toggleStyle(.checkbox)
                            .fixedSize()
                            .help("セクションの代表座標（約100m単位）を Apple のジオコーディングで地名に変換します")
                    }

                    Toggle("似た写真を束ねる", isOn: $model.bundleSimilar)
                        .toggleStyle(.checkbox)
                        .fixedSize()
                        .help("同じバーストや 3 分以内・pHash 距離 12 以下の似た写真をまとめて表示します")

                    Toggle("位置なしのみ", isOn: $model.onlyMissingLocation)
                        .toggleStyle(.checkbox)
                        .fixedSize()
                        .disabled(model.missingLocationCount == 0 && !model.onlyMissingLocation)
                        .help("位置情報がない対象写真だけを表示します")

                    Spacer()

                    if let ap = model.analysisProgress {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("品質解析中 \(ap.done)/\(ap.total)")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button {
                        model.selectFavorites()
                    } label: {
                        Label("お気に入りのみ", systemImage: "star")
                    }
                    .controlSize(.small)
                    .disabled(model.isBusy || model.eligibleCount == 0)

                    Button {
                        model.selectRecommendedAll()
                    } label: {
                        let count = model.recommendedAllIds.count
                        Label(model.isAnalysisComplete ? "推奨を自動選択 (\(count))" : "推奨を自動選択",
                              systemImage: "sparkles")
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(model.isBusy || !model.isAnalysisComplete || model.recommendedAllIds.isEmpty)
                    .help(model.isAnalysisComplete
                          ? "各類似グループの最良（お気に入り最優先・鮮明度/露出スコア順）1枚と単独写真をまとめて選択します（手動選択は置き換えます）"
                          : "品質解析の完了後に使えます")
                }

                Text("全 \(model.items.count) 件 / 対象 \(model.eligibleCount) 件 / 対象外 \(model.ineligibleCount) 件"
                     + " / 前回送信済み \(model.previouslySentCount) 件"
                     + (model.missingLocationCount > 0 ? " / 位置なし \(model.missingLocationCount) 件" : "")
                     + (model.supplementedLocationCount > 0 ? " / 位置補完 \(model.supplementedLocationCount) 件" : "")
                     + (model.similarClusterCount > 0 ? " / 類似 \(model.similarClusterCount) グループ" : "")
                     + (model.hiddenCount > 0 ? "（\(model.hiddenCount) 件を非表示）" : ""))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    static let fullDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy/MM/dd (E)"
        return f
    }()

    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "MM/dd (E)"
        return f
    }()

    private static let yearMonthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy年 M月"
        return f
    }()

    static func rangeButtonText(from: Date, to: Date) -> String {
        let s = min(from, to)
        let e = max(from, to)
        let cal = Calendar.current
        if cal.isDate(s, inSameDayAs: e) {
            return fullDateFormatter.string(from: s)
        }
        let sameYear = cal.component(.year, from: s) == cal.component(.year, from: e)
        let endStr = sameYear ? shortDateFormatter.string(from: e) : fullDateFormatter.string(from: e)
        return "\(fullDateFormatter.string(from: s)) 〜 \(endStr)"
    }

    static func monthTitle(_ date: Date) -> String {
        yearMonthFormatter.string(from: date)
    }
}

// MARK: - 2ヶ月見開き・大判レンジカレンダー ポップオーバー

private struct MonthHistorySummary: Identifiable {
    let monthStart: Date
    let sent: Int
    let checked: Int
    let duplicate: Int
    let failed: Int
    var id: Date { monthStart }

    var menuTitle: String {
        var parts: [String] = []
        if sent > 0 { parts.append("送信 \(sent)") }
        if checked > 0 { parts.append("確認 \(checked)") }
        if duplicate > 0 { parts.append("既存 \(duplicate)") }
        if failed > 0 { parts.append("失敗 \(failed)") }
        let suffix = parts.isEmpty ? "" : "（\(parts.joined(separator: " / "))）"
        return "\(DateFilterView.monthTitle(monthStart))\(suffix)"
    }
}

private struct RangeCalendarPopover: View {
    @EnvironmentObject private var model: AppModel
    @Binding var isPresented: Bool

    @State private var rightMonth: Date = LocalTime.startOfMonth(for: Date())
    @State private var pendingStart: Date?
    @State private var hoveredDate: Date?

    private var leftMonth: Date {
        LocalTime.addingMonths(-1, to: rightMonth)
    }

    private var activePreset: DateRangePreset? {
        DateRangePreset.matching(from: model.fromDate, to: model.toDate)
    }

    private var monthsWithHistory: [MonthHistorySummary] {
        let cal = Calendar.current
        var grouped: [Date: (sent: Int, checked: Int, dup: Int, failed: Int)] = [:]
        for (day, h) in model.calendarHistory where h.totalCount > 0 {
            let ms = LocalTime.startOfMonth(for: day, calendar: cal)
            var cur = grouped[ms] ?? (0, 0, 0, 0)
            cur.sent += h.sentCount
            cur.checked += h.checkedCount
            cur.dup += h.duplicateCount
            cur.failed += h.failedCount
            grouped[ms] = cur
        }
        return grouped.map { ms, counts in
            MonthHistorySummary(
                monthStart: ms,
                sent: counts.sent,
                checked: counts.checked,
                duplicate: counts.dup,
                failed: counts.failed
            )
        }
        .sorted { $0.monthStart > $1.monthStart }
    }

    private var displayBounds: (start: Date, end: Date, isPreview: Bool) {
        if let start = pendingStart {
            if let hover = hoveredDate {
                return (min(start, hover), max(start, hover), true)
            }
            return (start, start, true)
        }
        let s = Calendar.current.startOfDay(for: min(model.fromDate, model.toDate))
        let e = Calendar.current.startOfDay(for: max(model.fromDate, model.toDate))
        return (s, e, false)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                presetSidebar
                Divider()
                calendarMain
            }
            Divider()
            footer
        }
        .frame(width: 856)
        .onAppear {
            pendingStart = nil
            hoveredDate = nil
            rightMonth = LocalTime.startOfMonth(for: max(model.fromDate, model.toDate))
            Task { await model.refreshCalendarHistory() }
        }
    }

    private var presetSidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("クイック選択")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)

            ForEach(DateRangePreset.allCases) { preset in
                let selected = pendingStart == nil && activePreset == preset
                Button {
                    pendingStart = nil
                    hoveredDate = nil
                    model.applyDatePreset(preset)
                    rightMonth = LocalTime.startOfMonth(for: model.toDate)
                } label: {
                    HStack {
                        Text(preset.sidebarLabel)
                            .font(.callout.weight(selected ? .semibold : .regular))
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(selected ? Color.accentColor : Color.clear)
                    )
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 138)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
    }

    private var calendarMain: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Button {
                    rightMonth = LocalTime.addingMonths(-12, to: rightMonth)
                } label: {
                    Image(systemName: "chevron.left.2")
                }
                .controlSize(.small)
                .help("前年へ")

                Button {
                    rightMonth = LocalTime.addingMonths(-1, to: rightMonth)
                } label: {
                    Label("前月", systemImage: "chevron.left")
                }
                .controlSize(.small)

                Spacer()

                Menu {
                    ForEach(monthsWithHistory) { item in
                        Button(item.menuTitle) {
                            rightMonth = item.monthStart
                        }
                    }
                } label: {
                    Label("履歴のある月 (\(monthsWithHistory.count))", systemImage: "clock.arrow.circlepath")
                }
                .controlSize(.small)
                .disabled(monthsWithHistory.isEmpty)
                .help("ローカルに送信・確認履歴がある月へ直接移動します")

                Button("今月") {
                    rightMonth = LocalTime.startOfMonth(for: Date())
                }
                .controlSize(.small)

                Spacer()

                Button {
                    rightMonth = LocalTime.addingMonths(1, to: rightMonth)
                } label: {
                    HStack(spacing: 4) {
                        Text("翌月")
                        Image(systemName: "chevron.right")
                    }
                }
                .controlSize(.small)

                Button {
                    rightMonth = LocalTime.addingMonths(12, to: rightMonth)
                } label: {
                    Image(systemName: "chevron.right.2")
                }
                .controlSize(.small)
                .help("翌年へ")
            }

            HStack(alignment: .top, spacing: 20) {
                MonthGridView(
                    monthDate: leftMonth,
                    bounds: displayBounds,
                    historyByDay: model.calendarHistory,
                    onSelectDay: handleDayClick,
                    onHoverDay: { date, hovering in
                        if hovering {
                            hoveredDate = date
                        } else if hoveredDate == date {
                            hoveredDate = nil
                        }
                    }
                )
                MonthGridView(
                    monthDate: rightMonth,
                    bounds: displayBounds,
                    historyByDay: model.calendarHistory,
                    onSelectDay: handleDayClick,
                    onHoverDay: { date, hovering in
                        if hovering {
                            hoveredDate = date
                        } else if hoveredDate == date {
                            hoveredDate = nil
                        }
                    }
                )
            }

            historyLegend
        }
        .padding(16)
    }

    private var historyLegend: some View {
        HStack(spacing: 14) {
            legendDot(color: .green, label: "送信済み")
            legendDot(color: .teal, label: "確認済み・未送信")
            legendDot(color: .secondary, label: "Drive既存重複")
            legendDot(color: .orange, label: "前回失敗")
            Spacer()
            Text("数字は履歴件数（ホバーで詳細）")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 2)
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        let bounds = displayBounds
        let days = LocalTime.inclusiveDayCount(from: bounds.start, to: bounds.end)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(pendingStart != nil
                     ? "終了日をクリックしてください（同じ日をクリックすると単日になります）"
                     : "1クリック目: 開始日 ／ 2クリック目: 終了日（同日クリックで単日）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(DateFilterView.rangeButtonText(from: bounds.start, to: bounds.end))（\(days)日間）")
                    .font(.callout.weight(.semibold).monospacedDigit())
            }
            Spacer()
            Button("閉じる") {
                isPresented = false
            }
            .keyboardShortcut(.cancelAction)
            Button("この期間で読み込む") {
                isPresented = false
                model.load()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(model.isBusy)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func handleDayClick(_ day: Date) {
        let normalized = Calendar.current.startOfDay(for: day)
        if let start = pendingStart {
            model.setDateRange(from: start, to: normalized)
            pendingStart = nil
            hoveredDate = nil
        } else {
            pendingStart = normalized
            model.setDateRange(from: normalized, to: normalized)
        }
    }
}

private struct MonthGridView: View {
    let monthDate: Date
    let bounds: (start: Date, end: Date, isPreview: Bool)
    let historyByDay: [Date: CalendarDayHistory]
    let onSelectDay: (Date) -> Void
    let onHoverDay: (Date, Bool) -> Void

    private static let weekdayHeaders = ["日", "月", "火", "水", "木", "金", "土"]
    private static let columns = Array(repeating: GridItem(.fixed(42), spacing: 4), count: 7)

    private var cells: [CalendarDayCell] {
        LocalTime.monthGrid(forMonth: monthDate)
    }

    var body: some View {
        VStack(spacing: 8) {
            Text(DateFilterView.monthTitle(monthDate))
                .font(.headline.weight(.bold))
                .frame(maxWidth: .infinity, alignment: .center)

            LazyVGrid(columns: Self.columns, spacing: 4) {
                ForEach(0..<7, id: \.self) { idx in
                    Text(Self.weekdayHeaders[idx])
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(idx == 0 ? Color.red.opacity(0.85) : (idx == 6 ? Color.blue.opacity(0.85) : Color.secondary))
                        .frame(width: 42, height: 20)
                }

                ForEach(cells) { cell in
                    DayCellButton(
                        cell: cell,
                        bounds: bounds,
                        history: cell.isCurrentMonth ? historyByDay[cell.date] : nil,
                        onSelect: { onSelectDay(cell.date) },
                        onHover: { hovering in onHoverDay(cell.date, hovering) }
                    )
                }
            }
        }
        .frame(width: 318)
    }
}

private struct DayCellButton: View {
    let cell: CalendarDayCell
    let bounds: (start: Date, end: Date, isPreview: Bool)
    let history: CalendarDayHistory?
    let onSelect: () -> Void
    let onHover: (Bool) -> Void

    private var cal: Calendar { Calendar.current }
    private var isToday: Bool { cal.isDateInToday(cell.date) }
    private var isStart: Bool { cell.isCurrentMonth && cal.isDate(cell.date, inSameDayAs: bounds.start) }
    private var isEnd: Bool { cell.isCurrentMonth && cal.isDate(cell.date, inSameDayAs: bounds.end) }
    private var isEdge: Bool { isStart || isEnd }
    private var isBetween: Bool {
        cell.isCurrentMonth && !isEdge && cell.date > bounds.start && cell.date < bounds.end
    }

    var body: some View {
        Button(action: onSelect) {
            ZStack {
                if isEdge {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.accentColor)
                } else if isBetween {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.accentColor.opacity(bounds.isPreview ? 0.16 : 0.24))
                }

                VStack(spacing: 2) {
                    Text("\(cell.dayNumber)")
                        .font(.system(size: 14, weight: isEdge ? .bold : .semibold).monospacedDigit())
                        .foregroundStyle(textColor)
                    historyIndicator
                        .frame(height: 11)
                }

                if isToday && !isEdge {
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(Color.accentColor.opacity(0.85), lineWidth: 1.5)
                }
            }
            .frame(width: 42, height: 42)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(cell.isCurrentMonth ? 1.0 : 0.32)
        .help(tooltipText)
        .onHover(perform: onHover)
    }

    @ViewBuilder
    private var historyIndicator: some View {
        if let h = history, h.totalCount > 0 {
            let primaryCount = h.hasSent ? h.sentCount : h.totalCount
            HStack(spacing: 2) {
                if h.hasSent {
                    Circle().fill(isEdge ? Color.white : Color.green).frame(width: 5, height: 5)
                }
                if h.hasChecked {
                    Circle().fill(isEdge ? Color.white.opacity(0.85) : Color.teal).frame(width: 5, height: 5)
                }
                if h.hasDuplicate {
                    Circle().fill(isEdge ? Color.white.opacity(0.7) : Color.secondary).frame(width: 5, height: 5)
                }
                if h.hasFailed {
                    Circle().fill(isEdge ? Color.yellow : Color.orange).frame(width: 5, height: 5)
                }
                Text("\(primaryCount)")
                    .font(.system(size: 9.5, weight: .bold).monospacedDigit())
                    .foregroundStyle(isEdge ? Color.white : (h.hasSent ? Color.green : Color.secondary))
            }
        } else {
            EmptyView()
        }
    }

    private var tooltipText: String {
        guard cell.isCurrentMonth, let h = history, h.totalCount > 0 else { return "" }
        var lines = [DateFilterView.fullDateFormatter.string(from: cell.date)]
        if h.sentCount > 0 { lines.append("送信済み: \(h.sentCount)件") }
        if h.checkedCount > 0 { lines.append("確認済み・未送信: \(h.checkedCount)件") }
        if h.duplicateCount > 0 { lines.append("Drive既存重複: \(h.duplicateCount)件") }
        if h.failedCount > 0 { lines.append("前回失敗: \(h.failedCount)件") }
        return lines.joined(separator: "\n")
    }

    private var textColor: Color {
        if isEdge { return .white }
        if !cell.isCurrentMonth { return .secondary }
        if cell.weekday == 1 { return .red.opacity(0.9) }
        if cell.weekday == 7 { return .blue.opacity(0.9) }
        return .primary
    }
}

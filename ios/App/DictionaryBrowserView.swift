import SwiftUI

/// 字典瀏覽頁（Typeless 的 dictionary tabs）：全部／自動加入／手動加入三分頁＋搜尋。
/// 「自動加入」＝CorrectionLearner 從「語音貼上後手動改字」學到的；有來源標記的才算，
/// **舊資料沒有標記的一律算手動**（沿用設定頁既有的 `LearnedVocabulary.autoLearned` 判準）。
struct DictionaryBrowserView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case all, auto, manual
        var id: String { rawValue }
        var source: DictionarySource.Tab {
            switch self {
            case .all: return .all
            case .auto: return .auto
            case .manual: return .manual
            }
        }
        var label: String {
            switch self {
            case .all: return String(localized: "全部")
            case .auto: return String(localized: "自動加入")
            case .manual: return String(localized: "手動加入")
            }
        }
    }

    @State private var dictionary: [String: String] = DictionaryStore.shared.dictionary
    @State private var tab: Tab = .all
    @State private var query = ""

    private var autoLearned: Set<String> { LearnedVocabulary.autoLearned }

    /// 分頁＋搜尋的規則在 `DictionarySource.filter`（單一正本、有單元測試）。
    private var visible: [(source: String, output: String)] {
        let entries: [(source: String, output: String)] = dictionary
            .map { (source: $0.key, output: $0.value) }
            .sorted { $0.source.localizedStandardCompare($1.source) == .orderedAscending }
        return DictionarySource.filter(entries, tab: tab.source, autoLearned: autoLearned, query: query)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .accessibilityIdentifier("dictionaryTabs")

            if visible.isEmpty {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: "character.book.closed",
                    description: Text(emptyHint)
                )
                Spacer()
            } else {
                List {
                    ForEach(visible, id: \.source) { entry in
                        row(entry)
                    }
                }
                .listStyle(.plain)
            }
        }
        .background(Aurora.Backdrop())
        .searchable(text: $query, prompt: String(localized: "搜尋字典"))
        .navigationTitle("字典")
        .onAppear { dictionary = DictionaryStore.shared.dictionary }
    }

    private var emptyTitle: String {
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return String(localized: "找不到符合的詞") }
        switch tab {
        case .all: return String(localized: "還沒有加入任何詞")
        case .auto: return String(localized: "還沒有自動學到的詞")
        case .manual: return String(localized: "還沒有手動加入的詞")
        }
    }

    private var emptyHint: String {
        switch tab {
        case .all: return String(localized: "到設定 → 個人字典加入詞彙，語音辨識會優先聽成它們。")
        case .auto: return String(localized: "用鍵盤貼上語音後改錯字，Type 會自己學會那組修正並放在這裡。")
        case .manual: return String(localized: "自己加入的詞與替換規則在這裡；設定頁可以新增。")
        }
    }

    private func row(_ entry: (source: String, output: String)) -> some View {
        HStack {
            Text(entry.source)
            if entry.source != entry.output {
                Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                Text(entry.output)
            } else {
                Text("詞彙")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Aurora.orange)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Aurora.orange.opacity(0.12)))
            }
            if autoLearned.contains(entry.source) {
                Text("自動")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
            }
            Spacer()
            Button {
                TapPulse.shared.fire()
                remove(entry.source)
            } label: {
                Image(systemName: "trash").foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("刪除")
        }
    }

    /// 刪掉。自動學到的詞另外記進「已忽略」清單——同一組修正不會馬上又被學回來。
    /// 邏輯放在 `LearnedVocabulary.removeFromDictionary`，設定頁共用同一份。
    private func remove(_ source: String) {
        LearnedVocabulary.removeFromDictionary(source)
        DictionaryCloud.sync()
        dictionary = DictionaryStore.shared.dictionary
    }
}
import SwiftUI

/// 歷史列表（對齊 Typeless 歷史）：分日區段、搜尋、只看星標；每筆可複製／星標／刪除。
struct HistoryListView: View {
    @State private var records: [DictationRecord] = []
    @State private var copiedID: UUID?
    @State private var query = ""
    @State private var starredOnly = false
    @State private var retention = RetentionSettings.policy
    @State private var confirmDeleteAll = false
    /// 檔案裡的**真實總筆數**（沒被期限／搜尋／星標過濾）。
    /// 「全部刪除」刪的是整份檔案，確認框要報這個數，不是畫面上看到的那幾筆。
    @State private var storedCount = 0

    private var visible: [DictationRecord] {
        HistoryGrouping.filter(records, query: query, starredOnly: starredOnly)
    }

    private var sections: [HistorySection] {
        HistoryGrouping.sections(visible)
    }

    var body: some View {
        NavigationStack {
            Group {
                if records.isEmpty {
                    ContentUnavailableView {
                        Label("還沒有紀錄", image: "OrbGlyph")
                    } description: {
                        Text("到「聽寫」點光球講一句話，這裡就會出現。")
                    }
                } else if visible.isEmpty {
                    // 不用 ContentUnavailableView.search：它跟系統語言走（模擬器英文），app 文案全中文。
                    ContentUnavailableView(
                        starredOnly && query.isEmpty ? String(localized: "還沒有星標") : String(localized: "找不到「\(query)」"),
                        systemImage: starredOnly && query.isEmpty ? "star" : "magnifyingglass",
                        description: Text(starredOnly ? String(localized: "點右上角的星星可以回到全部。") : String(localized: "換個字試試；raw 逐字稿也會被搜到。"))
                    )
                } else {
                    list
                }
            }
            .background(Aurora.Backdrop())
            .scrollContentBackground(.hidden)
            .navigationTitle("歷史")
            .searchable(text: $query, prompt: "搜尋歷史")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            TapPulse.shared.fire()
                            purgeExpired()
                        } label: {
                            Label(String(localized: "刪除超過期限的"), systemImage: "clock.arrow.circlepath")
                        }
                        .disabled(retention == .forever || retention == .none || records.isEmpty)

                        Button(role: .destructive) {
                            TapPulse.shared.fire()
                            confirmDeleteAll = true
                        } label: {
                            Label(String(localized: "全部刪除"), systemImage: "trash")
                        }
                        .disabled(records.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel(String(localized: "歷史操作"))
                    .accessibilityIdentifier("historyActions")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        TapPulse.shared.fire()
                        starredOnly.toggle()
                    } label: {
                        Image(systemName: starredOnly ? "star.fill" : "star")
                    }
                    .tint(Aurora.orange)
                    .accessibilityLabel(starredOnly ? String(localized: "顯示全部") : String(localized: "只看星標"))
                    .accessibilityIdentifier("starredOnly")
                }
            }
            .confirmationDialog(
                // 報**檔案裡的總筆數**：`records` 是過濾後的，用它會少報。
                String(localized: "確定要刪掉全部 \(storedCount) 筆歷史嗎？"),
                isPresented: $confirmDeleteAll, titleVisibility: .visible
            ) {
                Button(String(localized: "全部刪除"), role: .destructive) { deleteAll() }
                Button(String(localized: "取消"), role: .cancel) {}
            } message: {
                // 星號不會被保留——要講清楚，不要讓人以為星號有特權。
                Text(String(localized: "有星號的也會一起刪掉。使用數據（每日字數與時長）不受影響。"))
            }
            .onAppear {
                retention = RetentionSettings.policy
                reload()
            }
        }
    }

    private var list: some View {
        List {
            ForEach(sections) { section in
                Section {
                    ForEach(section.records) { record in
                        row(record)
                    }
                } header: {
                    Text(section.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .textCase(nil)
                }
            }
        }
    }

    private func row(_ record: DictationRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(record.date.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // 鍵盤打的字現在也會寫回歷史（D8-4），標一下來源。
                if record.source == .keyboard {
                    Label("鍵盤", systemImage: "keyboard")
                        .font(.caption2)
                        .foregroundStyle(Aurora.orange)
                }
                // 「說出要怎麼改」的結果：raw 是指示，cleaned 是改寫後。
                if record.isEdit {
                    Label("改寫", systemImage: "wand.and.stars")
                        .font(.caption2)
                        .foregroundStyle(Aurora.violet)
                }
                Spacer()
                Button {
                    TapPulse.shared.fire()
                    var r = record
                    r.starred.toggle()
                    update(r)
                } label: {
                    Image(systemName: record.starred ? "star.fill" : "star")
                        .foregroundStyle(Aurora.orange)
                }
                .buttonStyle(.borderless)
                Button {
                    TapPulse.shared.fire()
                    UIPasteboard.general.string = record.cleaned
                    copiedID = record.id
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copiedID = nil }
                } label: {
                    Image(systemName: copiedID == record.id ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
            }
            // 使用者的內容（不是介面文案）：在地化 UI 測試靠這個 identifier 把它排除在檢查外。
            Text(record.cleaned)
                .textSelection(.enabled)
                .accessibilityIdentifier("historyRecordText")
            if record.isEdit {
                Text(record.raw)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("historyRecordText")
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                TapPulse.shared.fire()
                delete(record)
            } label: {
                Label("刪除", systemImage: "trash")
            }
        }
    }

    /// 讀檔在背景佇列（history.json 可以有 500 筆，不該在主執行緒上解碼），回來再更新畫面。
    private func reload() {
        let policy = retention
        HistoryIO.shared.readAsync { all in
            storedCount = all.count
            records = RetentionPolicy.filter(all, policy: policy)
        }
    }

    /// 對**整份檔案**做讀-改-寫。畫面上的 `records` 是過濾後的，直接存回去會把
    /// 被搜尋／期限／星標濾掉的紀錄一起刪掉（除錯：同一個 bug 的另外兩條路徑）。
    private func mutateFile(_ body: @escaping (inout [DictationRecord]) -> Void) {
        let policy = retention
        HistoryIO.shared.mutateAsync { all in
            body(&all)
        } didFinish: { all in
            storedCount = all.count
            records = RetentionPolicy.filter(all, policy: policy)
        }
    }

    private func update(_ record: DictationRecord) {
        mutateFile { all in
            guard let idx = all.firstIndex(where: { $0.id == record.id }) else { return }
            all[idx] = record
        }
    }

    private func delete(_ record: DictationRecord) {
        mutateFile { all in all.removeAll { $0.id == record.id } }
    }

    /// 刪掉超過保留期限的（星號不例外，跟期限走）。每日計數不受影響。
    private func purgeExpired() {
        let policy = retention
        mutateFile { all in
            all = RetentionPolicy.filter(all, policy: policy)
        }
    }

    /// 全部刪除：只動歷史，每日計數留著。
    private func deleteAll() {
        mutateFile { all in all = [] }
    }
}

/// 歷史檔的讀寫排到**序列背景佇列**，離開主執行緒。
/// 鍵盤 extension 那邊交付時的寫入也走同一條思路（RULE-common 第 7 點）。
final class HistoryIO: @unchecked Sendable {
    nonisolated(unsafe) static let shared = HistoryIO()

    private let queue = DispatchQueue(label: "utuvo.type.ios.history.io", qos: .userInitiated)

    /// 讀整份歷史，回主執行緒交付結果。
    func readAsync(_ completion: @escaping @MainActor ([DictationRecord]) -> Void) {
        queue.async {
            let all = HistoryStore.shared.load()
            DispatchQueue.main.async { completion(all) }
        }
    }

    /// 讀-改-寫（跨 process 協調在 `HistoryStore.withExclusiveAccess` 裡），完成後回主執行緒。
    func mutateAsync(_ body: @escaping (inout [DictationRecord]) -> Void,
                     didFinish: @escaping @MainActor ([DictationRecord]) -> Void) {
        let store = HistoryStore.shared
        queue.async {
            store.withExclusiveAccess { all in
                body(&all)
            }
            let all = store.load()
            DispatchQueue.main.async { didFinish(all) }
        }
    }
}

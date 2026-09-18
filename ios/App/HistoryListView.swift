import SwiftUI

/// 歷史列表（對齊 Typeless 歷史）：分日區段、搜尋、只看星標；每筆可複製／星標／刪除。
struct HistoryListView: View {
    @State private var records: [DictationRecord] = []
    @State private var copiedID: UUID?
    @State private var query = ""
    @State private var starredOnly = false

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
                        starredOnly && query.isEmpty ? "還沒有星標" : "找不到「\(query)」",
                        systemImage: starredOnly && query.isEmpty ? "star" : "magnifyingglass",
                        description: Text(starredOnly ? "點右上角的星星可以回到全部。" : "換個字試試；raw 逐字稿也會被搜到。")
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
                    Button {
                        starredOnly.toggle()
                    } label: {
                        Image(systemName: starredOnly ? "star.fill" : "star")
                    }
                    .tint(Aurora.orange)
                    .accessibilityLabel(starredOnly ? "顯示全部" : "只看星標")
                    .accessibilityIdentifier("starredOnly")
                }
            }
            .onAppear { records = HistoryStore.shared.load() }
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
                    var r = record
                    r.starred.toggle()
                    update(r)
                } label: {
                    Image(systemName: record.starred ? "star.fill" : "star")
                        .foregroundStyle(Aurora.orange)
                }
                .buttonStyle(.borderless)
                Button {
                    UIPasteboard.general.string = record.cleaned
                    copiedID = record.id
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copiedID = nil }
                } label: {
                    Image(systemName: copiedID == record.id ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
            }
            Text(record.cleaned)
                .textSelection(.enabled)
            if record.isEdit {
                Text(record.raw)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                delete(record)
            } label: {
                Label("刪除", systemImage: "trash")
            }
        }
    }

    private func update(_ record: DictationRecord) {
        guard let idx = records.firstIndex(where: { $0.id == record.id }) else { return }
        records[idx] = record
        HistoryStore.shared.save(records)
    }

    private func delete(_ record: DictationRecord) {
        records.removeAll { $0.id == record.id }
        HistoryStore.shared.save(records)
    }
}

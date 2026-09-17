import SwiftUI

/// 歷史列表：最近在前、可複製／星標／刪除。對齊 macOS 歷史的核心操作。
struct HistoryListView: View {
    @State private var records: [DictationRecord] = []
    @State private var copiedID: UUID?

    var body: some View {
        NavigationStack {
            Group {
                if records.isEmpty {
                    ContentUnavailableView(
                        "還沒有紀錄",
                        systemImage: "mic",
                        description: Text("到「聽寫」講一句話，這裡就會出現。")
                    )
                } else {
                    list
                }
            }
            .background(Aurora.Backdrop())
            .scrollContentBackground(.hidden)
            .navigationTitle("歷史")
            .onAppear { records = HistoryStore.shared.load() }
        }
    }

    private var list: some View {
        List {
            ForEach(records) { record in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(record.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        // 鍵盤打的字現在也會寫回歷史（D8-4），標一下來源。
                        if record.source == .keyboard {
                            Label("鍵盤", systemImage: "keyboard")
                                .font(.caption2)
                                .foregroundStyle(Aurora.orange)
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
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        delete(record)
                    } label: {
                        Label("刪除", systemImage: "trash")
                    }
                }
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

import SwiftUI

/// 詞庫包與匯入（像搜狗細胞詞庫）：開關內建詞庫、開關可選專業詞庫、貼上詞彙清單匯入個人字典。
///
/// 2026-09-20 runtime 票：catalog 六包（資訊／醫療／財經／法律／工程／音樂音訊）來自
/// `Bundle.main/vocabulary/catalog.json`，預設全關，使用者明確開啟才生效。
/// 點任一包可進明細：實際唯一詞數、摘要、來源、授權、版本、搜尋（結果上限 100）、來源 URL。
struct VocabularyPacksScreen: View {
    @State private var enabled: Set<String>
    @State private var importText = ""
    @State private var message: String?

    init() {
        _enabled = State(initialValue: Set(VocabularyPacks.all.filter(VocabularyPacks.isEnabled).map(\.id)
            + VocabularyPacks.enabledCatalogPacks().map(\.id)))
    }

    var body: some View {
        Form {
            builtInSection
            catalogSection
            importSection
        }
        .navigationTitle("詞庫包與匯入")
        .onAppear {
            // 進入頁面時重新載入一次（catalog.json 由 data writer 更新後重啟 app 即可拿到）
            VocabularyPacks.loadCatalog()
            enabled = Set(VocabularyPacks.all.filter(VocabularyPacks.isEnabled).map(\.id)
                + VocabularyPacks.enabledCatalogPacks().map(\.id))
        }
    }

    @ViewBuilder
    private var builtInSection: some View {
        Section {
            ForEach(VocabularyPacks.all) { pack in
                packToggleRow(id: pack.id, name: pack.name, summary: pack.summary, on: pack.defaultOn,
                              count: pack.terms.count)
            }
        } header: {
            Text("內建詞庫")
        } footer: {
            Text("開著的詞庫會讓辨識更容易聽對這些詞；有開智慧整理時，聽錯的（例如 Jeman）也會被改成正確寫法（Gemini）。")
        }
    }

    @ViewBuilder
    private var catalogSection: some View {
        let packs = VocabularyPacks.catalog.packs
        if !packs.isEmpty {
            Section {
                ForEach(packs) { pack in
                    // UI-FINDINGS：NavigationLink 與 Toggle 分開——點列說明進明細、撥開關只切換，
                    // 兩個行為不互相吃掉；accessibility id 綁在真正的 switch 上。
                    HStack(spacing: 8) {
                        NavigationLink {
                            PackDetailsScreen(pack: pack)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pack.displayName)
                                Text("\(pack.displayTermCount)・\(pack.displaySummary)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        catalogToggle(id: pack.id)
                    }
                }
            } header: {
                Text(String(localized: "可選專業詞庫（離線內附，開啟使用）"))
            } footer: {
                Text(String(localized: "預設全部關閉；開啟後清單與提示詞才會包含這些詞。"))
            }
        }
    }

    /// catalog 六包的開關（只綁 switch 本體，UI 測試 query 得到）。
    private func catalogToggle(id: String) -> some View {
        Toggle(String(localized: "開啟"), isOn: Binding(
            get: { enabled.contains(id) },
            set: { newOn in
                if let catalogPack = VocabularyPacks.catalog.packs.first(where: { $0.id == id }) {
                    VocabularyPacks.setCatalogEnabled(catalogPack, newOn)
                }
                if newOn { enabled.insert(id) } else { enabled.remove(id) }
            }))
        .labelsHidden()
        .fixedSize()
        .accessibilityIdentifier("pack:\(id)")
        .accessibilityLabel(String(localized: "開啟詞庫"))
    }

    private func packToggleRow(id: String, name: String, summary: String, on defaultOn: Bool, count: Int? = nil) -> some View {
        Toggle(isOn: Binding(
            get: { enabled.contains(id) },
            set: { newOn in
                if let builtin = VocabularyPacks.all.first(where: { $0.id == id }) {
                    VocabularyPacks.setEnabled(builtin, newOn)
                } else if let catalogPack = VocabularyPacks.catalog.packs.first(where: { $0.id == id }) {
                    VocabularyPacks.setCatalogEnabled(catalogPack, newOn)
                }
                if newOn { enabled.insert(id) } else { enabled.remove(id) }
            })) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name)
                    if let count {
                        Text(String(localized: "\(count) 詞"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if defaultOn {
                        Text("預設").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("pack:\(id)")
    }

    @ViewBuilder
    private var importSection: some View {
        Section {
            TextEditor(text: $importText)
                .frame(minHeight: 120)
                .font(.body.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("vocabImport")
            Button("匯入到個人字典") {
                let n = VocabularyPacks.importLines(importText)
                message = String(localized: "已加入 \(n) 筆。")
                if n > 0 { importText = "" }
            }
            .disabled(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
        } header: {
            Text("匯入詞彙")
        } footer: {
            Text("一行一個詞（例如 Perplexity）；要替換就寫「聽到→改成」（例如 cloud code→Claude Code）。可以把其他輸入法匯出的詞庫或朋友分享的清單直接貼進來。")
        }
    }
}

/// 單一 catalog 詞庫的明細頁：唯一詞數、摘要、來源、授權、版本、搜尋（上限 100）、來源 URL。
struct PackDetailsScreen: View {
    /// 進頁時的 metadata pack；打開頁面後立即補載【這一包】的完整詞表（UI-FINDINGS：
    /// 不管開／關都要能預覽整包，不能只搜得到 31–40 個 seed）。
    @State private var loadedPack: VocabularyCatalog.Pack
    @State private var query: String = ""
    @State private var enabled: Bool

    init(pack: VocabularyCatalog.Pack) {
        _loadedPack = State(initialValue: pack)
        _enabled = State(initialValue: VocabularyPacks.enabledCatalogPacks().contains { $0.id == pack.id })
    }

    private var pack: VocabularyCatalog.Pack { loadedPack }

    private var uniqueTermCount: Int {
        // 來自 catalog.json metadata 的 termCount；data writer 端已去重並把數字寫進 metadata。
        // 沒載入 terms 時仍給誠實的 metadata 數字。
        pack.termCount
    }

    private var matches: [String] {
        VocabularySelector.search(query, in: pack, limit: 100)
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $enabled) {
                    Text(enabled ? String(localized: "已開啟") : String(localized: "關閉"))
                }
                .accessibilityIdentifier("packToggle:\(pack.id)")
                .accessibilityLabel(pack.displayName)
                .onChange(of: enabled) { _, newValue in
                    VocabularyPacks.setCatalogEnabled(pack, newValue)
                }
                LabeledContent(String(localized: "實際唯一詞數")) { Text("\(uniqueTermCount)") }
                if !pack.summary.isEmpty {
                    LabeledContent(String(localized: "說明")) {
                        Text(pack.displaySummary).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(pack.displayName)
            } footer: {
                Text(String(localized: "開啟後，這個詞庫的詞會被當作辨識提示詞與智慧整理的專有名詞（依本句相關度篩入）。"))
            }

            Section {
                TextField(String(localized: "搜尋詞目"), text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("packSearch:\(pack.id)")
                if !query.isEmpty {
                    Text("顯示前 \(matches.count) 筆（共 \(uniqueTermCount) 筆）")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text(String(localized: "瀏覽詞目"))
            } footer: {
                if query.isEmpty {
                    Text(String(localized: "輸入詞目片段可即時過濾；結果上限 100 筆。"))
                }
            }

            if !query.isEmpty {
                Section {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(matches.enumerated()), id: \.offset) { _, term in
                            Text(term)
                                .font(.body.monospaced())
                                .accessibilityIdentifier("packTerm:\(pack.id):\(term)")
                        }
                    }
                }
            }

            Section {
                if !pack.sourceName.isEmpty {
                    LabeledContent(String(localized: "資料來源")) {
                        if let url = URL(string: pack.sourceURL), !pack.sourceURL.isEmpty {
                            Link(pack.sourceName, destination: url)
                                .accessibilityIdentifier("packSource:\(pack.id)")
                        } else {
                            Text(pack.sourceName)
                        }
                    }
                }
                if !pack.licenseName.isEmpty {
                    LabeledContent(String(localized: "授權")) {
                        if let url = URL(string: pack.licenseURL), !pack.licenseURL.isEmpty {
                            Link(pack.licenseName, destination: url)
                        } else {
                            Text(pack.licenseName)
                        }
                    }
                }
                if !pack.attribution.isEmpty {
                    LabeledContent(String(localized: "出處與整理")) {
                        Text(pack.attribution).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if !pack.version.isEmpty {
                    LabeledContent(String(localized: "版本")) { Text(pack.version) }
                }
            } header: {
                Text(String(localized: "出處與授權"))
            }
        }
        .navigationTitle(pack.displayName)
        .accessibilityIdentifier("packDetails:\(pack.id)")
        .task {
            // UI-FINDINGS：進明細頁就載這一包的完整詞表（與開／關無關，也不啟用任何包）。
            // 只載這一包，不掃其他 enabled 包；BundlePackTermsSource 內建快取，重複進頁不重讀。
            if let full = VocabularyPacks.catalogPackWithTermsLoaded(id: pack.id) {
                loadedPack = full
            }
        }
    }
}
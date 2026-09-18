import SwiftUI

/// 設定：辨識隱私、個人字典（與鍵盤共享）、雲端翻譯 key、關於。
struct SettingsScreen: View {
    @State private var dictionary: [String: String] = DictionaryStore.shared.dictionary
    @State private var newSource = ""
    @State private var newOutput = ""
    // 2026-09-11：key 不再回顯，欄位只用來輸入新值；實際值存 Keychain。
    @State private var hasStoredKey = IOSSecretStore.hasKey()
    @AppStorage(DictationModel.onDeviceOnlyKey) private var onDeviceOnly = false
    @State private var dictionaryMode: DictionaryMode = .vocabulary
    private enum DictionaryMode { case vocabulary, replacement }
    @AppStorage(KeyboardPresence.hantInputKey, store: KeyboardPresence.defaults) private var hantInput = "zhuyin"

    var body: some View {
        NavigationStack {
            Form {
                Section("鍵盤") {
                    Text("設定 → 一般 → 鍵盤 → 鍵盤 → 加入新鍵盤 → UTUVO Type，再打開「允許完整存取」。之後在任何輸入框按 🌐 切到 UTUVO Type。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    } label: {
                        Label("打開設定", systemImage: "arrow.up.forward.app")
                    }
                    LabeledContent("鍵盤狀態", value: KeyboardPresence.seen ? String(localized: "已出現過") : String(localized: "還沒啟用"))
                    Text("有選取文字時，鍵盤的光球會變成「說出要怎麼改」（轉成薰衣草色）；長按光球滑到語言、放開就翻譯。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Picker("「繁」鍵盤輸入法", selection: $hantInput) {
                        Text("注音").tag("zhuyin")
                        Text("拼音").tag("pinyin")
                    }
                    NavigationLink {
                        TranslationLanguagesView()
                    } label: {
                        LabeledContent("鍵盤翻譯語言", value: QuickPickStore.targets().map(\.displayName).joined(separator: "、"))
                    }
                }

                Section("辨識與隱私") {
                    Toggle("只用裝置端辨識", isOn: $onDeviceOnly)
                    Text(onDeviceOnly
                         ? String(localized: "音訊永遠不離開這台裝置。遇到不支援裝置端辨識的語言或機型時，會直接拒絕錄音並告訴你，不會偷偷改用雲端。")
                         : String(localized: "裝置端優先。不支援時會改用 Apple 伺服器辨識（音訊會離開裝置），聽寫畫面上會標示是哪一種。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    // 兩種用法（2026-09-18：只有「替換」用起來很怪）：
                    // ・新增詞彙：只填一個詞（人名、術語），交給語音辨識當提示（contextualStrings），比較容易聽對。
                    // ・替換：聽到 A 一律改成 B。資料格式不變：詞彙就是 A→A。
                    Picker("字典用法", selection: $dictionaryMode) {
                        Text("新增詞彙").tag(DictionaryMode.vocabulary)
                        Text("替換").tag(DictionaryMode.replacement)
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        TextField(dictionaryMode == .vocabulary ? "要加入的詞" : "聽到的詞", text: $newSource)
                            .accessibilityIdentifier("dictionaryTerm")
                            // 不要讓 iOS 當成帳號欄（跳 Passwords 列、換回系統鍵盤）。
                            .textContentType(nil)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        if dictionaryMode == .replacement {
                            Image(systemName: "arrow.right")
                                .foregroundStyle(.secondary)
                            TextField("改成", text: $newOutput)
                                .accessibilityIdentifier("dictionaryOutput")
                        }
                        Button("加入") {
                            let source = newSource.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !source.isEmpty else { return }
                            let output = newOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                            DictionaryStore.shared.addTerm(source: source, output: dictionaryMode == .vocabulary ? "" : output)
                            dictionary = DictionaryStore.shared.dictionary
                            newSource = ""
                            newOutput = ""
                        }
                        .disabled(newSource.trimmingCharacters(in: .whitespaces).isEmpty
                                  || (dictionaryMode == .replacement && newOutput.trimmingCharacters(in: .whitespaces).isEmpty))
                    }
                    ForEach(sortedDictionary, id: \.key) { entry in
                        HStack {
                            if entry.key == entry.value {
                                Text(entry.key)
                                Text("詞彙")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Aurora.orange)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Aurora.orange.opacity(0.12)))
                            } else {
                                Text(entry.key)
                                Image(systemName: "arrow.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(entry.value)
                            }
                            Spacer()
                            Button {
                                DictionaryStore.shared.removeTerm(source: entry.key)
                                dictionary = DictionaryStore.shared.dictionary
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("刪除")
                        }
                    }
                } header: {
                    Text("個人字典")
                } footer: {
                    Text(dictionaryMode == .vocabulary
                         ? "加入常講的專有名詞、術語（例：Atmos、Tonmeister），辨識時會優先聽成這些詞。app 與鍵盤共用同一份。"
                         : "聽到左邊的詞一律改成右邊（例：「pik」→「Pik」）。app 與鍵盤共用同一份。")
                }

                Section("改寫與翻譯引擎") {
                    LabeledContent("目前", value: OnDeviceAssistant.currentEngine().badge)
                    Text("iOS 26 的 Apple Intelligence 會在裝置端改寫與翻譯，文字不離機；沒有的話才用下面你自己的雲端 key。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("雲端翻譯（選配）") {
                    // key 輸入在子頁：密碼欄跟字典輸入欄放在同一個表單，iOS 會當成「帳號＋密碼」登入表單，
                    // 字典欄跳 Passwords 列（2026-09-18 實測）。
                    NavigationLink {
                        CloudKeyScreen()
                    } label: {
                        LabeledContent("DashScope API Key", value: hasStoredKey ? String(localized: "已設定") : String(localized: "未設定"))
                    }
                }

                Section("關於") {
                    LabeledContent("版本", value: "0.2.0 (iOS)")
                    LabeledContent("辨識引擎", value: String(localized: "Apple Speech（裝置端優先）"))
                    LabeledContent("文字清理", value: "UTUVOTypeCore deterministic normalizer")
                    LabeledContent("鍵盤", value: String(localized: "同一套清理＋字典，寫回歷史"))
                }
            }
            .navigationTitle("設定")
            .onAppear { hasStoredKey = IOSSecretStore.hasKey() }
        }
    }

    /// 詞彙排前面、替換排後面，各自照字母排。
    private var sortedDictionary: [(key: String, value: String)] {
        dictionary.sorted { a, b in
            let av = a.key == a.value, bv = b.key == b.value
            return av != bv ? av : a.key < b.key
        }
    }
}

/// 雲端翻譯 key（選配）：獨立子頁。值只存 Keychain、不回顯。
private struct CloudKeyScreen: View {
    @State private var apiKeyDraft = ""
    @State private var apiKeyMessage: String?
    @State private var apiKeyMessageIsError = false
    @State private var hasStoredKey = IOSSecretStore.hasKey()

    var body: some View {
        Form {
            Section {
            SecureField(hasStoredKey ? String(localized: "輸入新的 key 以取代") : "DashScope API Key", text: $apiKeyDraft)
            HStack {
                Button("儲存") {
                    let error = IOSSecretStore.save(apiKeyDraft)
                    apiKeyMessageIsError = error != nil
                    apiKeyMessage = error ?? String(localized: "已存進 Keychain。")
                    if error == nil { apiKeyDraft = "" }
                    hasStoredKey = IOSSecretStore.hasKey()
                }
                .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
                Button("清除", role: .destructive) {
                    let error = IOSSecretStore.delete()
                    apiKeyMessageIsError = error != nil
                    apiKeyMessage = error ?? String(localized: "已從 Keychain 刪除。")
                    apiKeyDraft = ""
                    hasStoredKey = IOSSecretStore.hasKey()
                }
                .disabled(!hasStoredKey)
            }
            .buttonStyle(.borderless)
            Label(
                hasStoredKey ? String(localized: "Keychain 已存一把 key（不顯示內容）。") : String(localized: "尚未設定；留空＝完全本機，不連任何雲端。"),
                systemImage: hasStoredKey ? "checkmark.seal.fill" : "circle.dashed"
            )
            .font(.caption)
            .foregroundStyle(hasStoredKey ? .green : .secondary)
            if let apiKeyMessage {
                Text(apiKeyMessage)
                    .font(.caption)
                    .foregroundStyle(apiKeyMessageIsError ? .red : .secondary)
            }
            }
        }
        .navigationTitle("雲端翻譯（選配）")
    }
}

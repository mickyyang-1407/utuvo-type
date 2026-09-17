import SwiftUI

/// 設定：辨識隱私、個人字典（與鍵盤共享）、雲端翻譯 key、關於。
struct SettingsScreen: View {
    @State private var dictionary: [String: String] = DictionaryStore.shared.dictionary
    @State private var newSource = ""
    @State private var newOutput = ""
    // 2026-09-11：key 不再回顯，欄位只用來輸入新值；實際值存 Keychain。
    @State private var apiKeyDraft = ""
    @State private var apiKeyMessage: String?
    @State private var apiKeyMessageIsError = false
    @State private var hasStoredKey = IOSSecretStore.hasKey()
    @AppStorage(DictationModel.onDeviceOnlyKey) private var onDeviceOnly = false

    var body: some View {
        NavigationStack {
            Form {
                Section("辨識與隱私") {
                    Toggle("只用裝置端辨識", isOn: $onDeviceOnly)
                    Text(onDeviceOnly
                         ? "音訊永遠不離開這台裝置。遇到不支援裝置端辨識的語言或機型時，會直接拒絕錄音並告訴你，不會偷偷改用雲端。"
                         : "裝置端優先。不支援時會改用 Apple 伺服器辨識（音訊會離開裝置），聽寫畫面上會標示是哪一種。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("個人字典") {
                    HStack {
                        TextField("要替換的詞", text: $newSource)
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.secondary)
                        TextField("替換成", text: $newOutput)
                        Button("新增") {
                            guard !newSource.isEmpty else { return }
                            DictionaryStore.shared.addTerm(source: newSource, output: newOutput)
                            dictionary = DictionaryStore.shared.dictionary
                            newSource = ""
                            newOutput = ""
                        }
                        .disabled(newSource.isEmpty)
                    }
                    ForEach(sortedDictionary, id: \.key) { entry in
                        HStack {
                            Text(entry.key)
                            Image(systemName: "arrow.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(entry.value)
                            Spacer()
                            Button {
                                DictionaryStore.shared.removeTerm(source: entry.key)
                                dictionary = DictionaryStore.shared.dictionary
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    if dictionary.isEmpty {
                        Text("例：「pik」→「Pik」。聽寫時自動替換；app 與鍵盤共用同一份。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("雲端翻譯（選配）") {
                    SecureField(hasStoredKey ? "輸入新的 key 以取代" : "DashScope API Key", text: $apiKeyDraft)
                    HStack {
                        Button("儲存") {
                            let error = IOSSecretStore.save(apiKeyDraft)
                            apiKeyMessageIsError = error != nil
                            apiKeyMessage = error ?? "已存進 Keychain。"
                            if error == nil { apiKeyDraft = "" }
                            hasStoredKey = IOSSecretStore.hasKey()
                        }
                        .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Spacer()
                        Button("清除", role: .destructive) {
                            let error = IOSSecretStore.delete()
                            apiKeyMessageIsError = error != nil
                            apiKeyMessage = error ?? "已從 Keychain 刪除。"
                            apiKeyDraft = ""
                            hasStoredKey = IOSSecretStore.hasKey()
                        }
                        .disabled(!hasStoredKey)
                    }
                    .buttonStyle(.borderless)
                    Label(
                        hasStoredKey ? "Keychain 已存一把 key（不顯示內容）。" : "尚未設定；留空＝完全本機，不連任何雲端。",
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

                Section("關於") {
                    LabeledContent("版本", value: "0.1.0 (iOS)")
                    LabeledContent("辨識引擎", value: "Apple Speech（裝置端優先）")
                    LabeledContent("文字清理", value: "UTUVOTypeCore deterministic normalizer")
                    LabeledContent("鍵盤", value: "同一套清理＋字典，寫回歷史")
                }
            }
            .navigationTitle("設定")
            .onAppear { hasStoredKey = IOSSecretStore.hasKey() }
        }
    }

    private var sortedDictionary: [(key: String, value: String)] {
        dictionary.sorted { $0.key < $1.key }
    }
}

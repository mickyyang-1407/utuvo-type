import SwiftUI
import UTUVOTypeCore
import UniformTypeIdentifiers

/// 設定：辨識隱私、個人字典（與鍵盤共享）、雲端翻譯 key、關於。
struct SettingsScreen: View {
    @State private var dictionary: [String: String] = DictionaryStore.shared.dictionary
    @State private var exporting = false
    @State private var importing = false
    @State private var exportDocument: DictionaryFile?
    @State private var dictionaryMessage: String?
    @State private var newSource = ""
    @State private var newOutput = ""
    // 2026-09-11：key 不再回顯，欄位只用來輸入新值；實際值存 Keychain。
    @State private var hasStoredKey = IOSSecretStore.hasKey()
    @AppStorage(DictationModel.onDeviceOnlyKey) private var onDeviceOnly = false
    @AppStorage(DictationModel.preferCloudKey) private var preferCloud = false
    @State private var dictionaryMode: DictionaryMode = .vocabulary
    private var autoLearned: Set<String> { LearnedVocabulary.autoLearned }
    private enum DictionaryMode { case vocabulary, replacement }
    @AppStorage(KeyboardPresence.hantInputKey, store: KeyboardPresence.defaults) private var hantInput = "zhuyin"
    @AppStorage(VoiceBridge.sessionMinutesKey) private var sessionMinutes = 3

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        UsageGuideScreen()
                    } label: {
                        Label("使用教學：怎麼設定、怎麼用鍵盤講話", systemImage: "questionmark.circle")
                    }
                }

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
                    Picker("鍵盤語音保持開啟", selection: $sessionMinutes) {
                        ForEach(VoiceBridge.sessionMinuteChoices, id: \.self) { minutes in
                            Text(minutes < 60 ? String(localized: "\(minutes) 分鐘") : String(localized: "1 小時")).tag(minutes)
                        }
                    }
                    Text("鍵盤第一次講話會跳到 UTUVO Type 開麥克風，之後在這段時間內都不用再跳。時間越長越少跳；期間麥克風保持開啟（狀態列有橘點），但只有你點光球時才會處理聲音。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("有選取文字時，鍵盤的光球會變成「說出要怎麼改」（轉成薰衣草色）；長按光球滑到語言、放開就翻譯。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Picker("「繁」鍵盤輸入法", selection: $hantInput) {
                        Text("注音").tag("zhuyin")
                        Text("拼音").tag("pinyin")
                    }
                    // 打字手感（2026-09-20）：按下去就震（不是放開才震）。放子頁，設定根頁不要再變長。
                    NavigationLink {
                        KeyFeedbackScreen()
                    } label: {
                        Label("打字手感", systemImage: "hand.tap")
                    }
                    .accessibilityIdentifier("keyFeedbackRow")
                    NavigationLink {
                        TranslationLanguagesView()
                    } label: {
                        LabeledContent("鍵盤翻譯語言", value: QuickPickStore.targets().map(\.displayName).joined(separator: "、"))
                    }
                }

                LocalASRSection()

                Section("辨識與隱私") {
                    Toggle("允許 Apple 雲端辨識", isOn: $preferCloud)
                        .disabled(onDeviceOnly)
                    Text(onDeviceOnly
                         ? String(localized: "只用裝置端辨識目前已開啟；音訊不會送到 Apple，雲端偏好暫停。")
                         : (preferCloud
                         ? String(localized: "開啟後允許 Apple Speech 使用雲端辨識，音訊可能送到 Apple 伺服器；辨識文字之後才會送到你選擇的智慧整理服務。")
                            : String(localized: "關閉時會優先用裝置端辨識；裝置端不可用時才依語言設定改用雲端。")))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("只用裝置端辨識", isOn: $onDeviceOnly)
                    Text(onDeviceOnly
                         ? String(localized: "音訊永遠不離開這台裝置。遇到不支援裝置端辨識的語言或機型時，會直接拒絕錄音並告訴你，不會偷偷改用雲端。")
                         : String(localized: "裝置端優先；裝置端不可用時 Apple Speech 可能改用伺服器辨識。聽寫畫面會標示目前允許的路徑。"))
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
                            DictionaryCloud.sync()
                            dictionary = DictionaryStore.shared.dictionary
                            newSource = ""
                            newOutput = ""
                        }
                        .disabled(newSource.trimmingCharacters(in: .whitespaces).isEmpty
                                  || (dictionaryMode == .replacement && newOutput.trimmingCharacters(in: .whitespaces).isEmpty))
                    }
                    NavigationLink {
                        VocabularyPacksScreen()
                            .onDisappear { DictionaryCloud.sync(); dictionary = DictionaryStore.shared.dictionary }
                    } label: {
                        Label("詞庫包與匯入", systemImage: "books.vertical")
                    }
                    .accessibilityIdentifier("vocabularyPacksRow")
                    // 跟 Android、Mac 互通的字典檔；iPhone↔Mac 另外會經 iCloud 自動同步。
                    HStack {
                        Button {
                            exportDocument = DictionaryFile(data: DictionaryStore.shared.exportData())
                            exporting = true
                        } label: { Label("匯出字典檔", systemImage: "square.and.arrow.up") }
                        .accessibilityIdentifier("dictExport")
                        Spacer()
                        Button { importing = true } label: { Label("匯入字典檔", systemImage: "square.and.arrow.down") }
                            .accessibilityIdentifier("dictImport")
                    }
                    .buttonStyle(.borderless)
                    if let dictionaryMessage {
                        Text(dictionaryMessage).font(.footnote).foregroundStyle(.secondary)
                            .accessibilityIdentifier("dictIoMessage")
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
                                if autoLearned.contains(entry.key) {
                                    // 鍵盤從「語音貼上後手動改字」自動學到的（CorrectionLearner）
                                    Text("自動")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(Color.secondary.opacity(0.12)))
                                }
                            }
                            Spacer()
                            Button {
                                DictionaryStore.shared.removeTerm(source: entry.key)
                                LearnedVocabulary.unmark(entry.key)
                                DictionaryCloud.sync()
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
                    + Text(" ")
                    + Text("登入同一個 iCloud 的 Mac 會自動同步；Android 用匯出／匯入字典檔。兩邊都改過的詞留最後改的那個。")
                }

                Section("改寫與翻譯引擎") {
                    LabeledContent("目前", value: OnDeviceAssistant.currentEngine().badge)
                    Text("iOS 26 的 Apple Intelligence 會在裝置端改寫與翻譯，文字不離機；沒有的話才用下面你自己的雲端 key。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    NavigationLink {
                        SmartCleanupScreen()
                    } label: {
                        LabeledContent("智慧整理", value: SmartCleanup.usesOnDevice ? String(localized: "Apple Intelligence・裝置端")
                                                        : SmartCleanup.isEnabled ? String(localized: "已開啟") : String(localized: "未設定"))
                    }
                    .accessibilityIdentifier("smartCleanupRow")
                } header: {
                    Text("智慧整理（選配）")
                } footer: {
                    Text("整理服務會收到辨識文字，以及你在整理設定中明確開啟的欄位脈絡；原始錄音不會轉送到整理服務。")
                }

                Section("阿里雲百鍊（選配）") {
                    // key 輸入在子頁：密碼欄跟字典輸入欄放在同一個表單，iOS 會當成「帳號＋密碼」登入表單，
                    // 字典欄跳 Passwords 列（2026-09-18 實測）。
                    NavigationLink {
                        CloudKeyScreen()
                    } label: {
                        LabeledContent("阿里雲百鍊 key", value: hasStoredKey ? String(localized: "已設定") : String(localized: "未設定"))
                    }
                    Text("這一把 key 同時供雲端翻譯與智慧整理使用。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("關於") {
                    LabeledContent("版本", value: "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—") (iOS)")
                    LabeledContent("辨識引擎", value: String(localized: "Apple Speech（裝置端優先）"))
                    LabeledContent("文字清理", value: "UTUVOTypeCore deterministic normalizer")
                    LabeledContent("鍵盤", value: String(localized: "同一套清理＋字典，寫回歷史"))
                }
            }
            .navigationTitle("設定")
            .onAppear { hasStoredKey = IOSSecretStore.hasKey(); dictionary = DictionaryStore.shared.dictionary }
            .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .json,
                          defaultFilename: "UTUVO Type 字典") { result in
                if case .success = result {
                    dictionaryMessage = String(localized: "已匯出 \(dictionary.count) 個詞。")
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .plainText, .data]) { result in
                dictionaryMessage = importDictionary(result)
                dictionary = DictionaryStore.shared.dictionary
            }
        }
    }

    private func importDictionary(_ result: Result<URL, Error>) -> String {
        guard case .success(let url) = result else { return String(localized: "沒有讀到檔案。") }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let incoming = try DictionarySync.decode(Data(contentsOf: url))
            let changed = DictionaryStore.shared.merge(incoming)
            DictionaryCloud.sync()
            return String(localized: "已合併，\(changed) 個詞有變動。")
        } catch DictionarySync.DecodeError.newerVersion {
            return String(localized: "這個字典檔來自較新版本的 UTUVO Type，請先更新。")
        } catch {
            return String(localized: "這不是 UTUVO Type 的字典檔。")
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

/// 阿里雲百鍊 key（選配）：翻譯與智慧整理共用。值只存 Keychain、不回顯。
struct CloudKeyScreen: View {
    @State private var apiKeyDraft = ""
    @State private var apiKeyMessage: String?
    @State private var apiKeyMessageIsError = false
    @State private var hasStoredKey = IOSSecretStore.hasKey()

    var body: some View {
        Form {
            Section {
            SecureField(hasStoredKey ? String(localized: "輸入新的 key 以取代") : "阿里雲百鍊 API key", text: $apiKeyDraft)
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
            Text("同一把 key 可供雲端翻譯與智慧整理使用；未設定時兩者都不會連線。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let apiKeyMessage {
                Text(apiKeyMessage)
                    .font(.caption)
                    .foregroundStyle(apiKeyMessageIsError ? .red : .secondary)
            }
            }
        }
        .navigationTitle("阿里雲百鍊（選配）")
    }
}

/// 匯出用的字典檔（JSON，格式見 core DictionarySync）。
struct DictionaryFile: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

/// 打字手感（2026-09-20 Micky：「鍵盤輸入的手感不是很好，可不可以有 haptic」）。
struct KeyFeedbackScreen: View {
    @AppStorage(KeyFeedback.strengthKey, store: KeyFeedback.defaults) private var strength = KeyFeedback.Strength.medium.rawValue
    @AppStorage(KeyFeedback.soundKey, store: KeyFeedback.defaults) private var sound = true

    var body: some View {
        Form {
            Section {
                Picker("按鍵震動", selection: $strength) {
                    Text("關").tag(KeyFeedback.Strength.off.rawValue)
                    Text("輕").tag(KeyFeedback.Strength.light.rawValue)
                    Text("中").tag(KeyFeedback.Strength.medium.rawValue)
                    Text("強").tag(KeyFeedback.Strength.strong.rawValue)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("hapticStrength")
                Toggle("按鍵聲音", isOn: $sound)
                    .accessibilityIdentifier("keySound")
            } footer: {
                Text("按下去的當下就震（不是放開才震），選字、切換鍵盤也有。震動需要在系統設定打開「允許完整存取」（跟語音一樣），按鍵聲音不用；手機靜音或系統把觸覺回饋關掉時都不會有。")
            }
        }
        .navigationTitle("打字手感")
    }
}

/// 本機高準確度辨識（Qwen3-ASR）：下載／狀態／刪除。模型只在使用者按下載後才下載（約 712 MB）。
struct LocalASRSection: View {
    @ObservedObject private var asr = LocalQwenASR.shared

    var body: some View {
        Section {
            switch asr.state {
            case .unsupported:
                LabeledContent("高準確度辨識", value: String(localized: "需要實機"))
            case .notDownloaded, .failed:
                Button {
                    Task { await asr.download() }
                } label: {
                    Label(String(localized: "下載高準確度辨識模型（約 \(LocalQwenASR.downloadMB) MB）"), systemImage: "arrow.down.circle")
                }
                if case .failed(let message) = asr.state {
                    Text(String(localized: "下載沒有完成：\(message)")).font(.caption).foregroundStyle(.red)
                }
            case .downloading(let progress):
                ProgressView(value: progress) {
                    Text(String(localized: "下載中… \(Int(progress * 100))%"))
                }
            case .ready:
                LabeledContent("高準確度辨識", value: String(localized: "已啟用・裝置端"))
                Button(String(localized: "刪除模型（釋放約 \(LocalQwenASR.downloadMB) MB）"), role: .destructive) {
                    Task { await asr.delete() }
                }
            }
        } header: {
            Text("高準確度辨識")
        } footer: {
            Text("用 Qwen3-ASR 在這支手機上重新辨識你講完的整段話，並參考你的字典，專有名詞與整體錯字明顯減少（實測錯字約少六成）。音訊不離開手機。目前只用在 UTUVO Type App 內的聽寫；鍵盤聽寫時 App 在背景，iOS 不允許背景使用 GPU，鍵盤仍用 Apple 辨識。建議連上 Wi-Fi 再下載。")
        }
    }
}

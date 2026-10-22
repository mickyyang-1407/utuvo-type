import Observation
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
    @State private var processingMode = DictationRouteSettings.mode
    @State private var dictionaryMode: DictionaryMode = .vocabulary
    private var autoLearned: Set<String> { LearnedVocabulary.autoLearned }
    private enum DictionaryMode { case vocabulary, replacement }
    @AppStorage(KeyboardPresence.hantInputKey, store: KeyboardPresence.defaults) private var hantInput = "zhuyin"
    @AppStorage(VoiceBridge.sessionMinutesKey) private var sessionMinutes = 3
    @AppStorage(UIFeedback.enabledKey, store: KeyFeedback.defaults) private var uiHaptics = true
    /// 個人字典的詞一多，設定頁就長到找不到下面的東西（10-07 Micky）：清單預設收起來。
    ///
    /// 2026-10-13 修復：這裡原本是 `@AppStorage`（展開狀態永久寫進 UserDefaults）。後果有兩個，
    /// 都是真的產品問題、不是測試問題：
    /// ①只要展開過一次，之後**每次啟動**設定頁都維持展開——10-07「讓設定頁短一點」的需求等於失效。
    /// ②展開狀態下設定頁會直接列出使用者自己存的詞（人名、專有詞），這些是使用者資料，
    ///    卻出現在一個跟字典內容無關的一般設定頁上（分頁瀏覽已經在「瀏覽字典」那一頁了）。
    /// 展開是「現在想看一下」這種一次性的畫面狀態，不是設定，所以不落地。
    @State private var dictionaryListExpanded = false

    // 歷史保留期限：改短要先確認（會刪歷史）。選「永遠」或往長改＝不用問，直接設。
    @State private var retention: RetentionPolicy = RetentionSettings.policy
    @State private var pendingRetention: RetentionPolicy = RetentionSettings.policy
    @State private var pendingPurgeCount = 0
    @State private var confirmRetention = false
    @State private var confirmClearUsage = false
    /// 只給 DEBUG 截圖用的導覽路徑（`utuvo.type.ios.debugDictionary`）。
    @State private var debugPath: [Int] = []

    /// 改期限：會刪東西（變短、含星號）才問；不刪的直接寫。
    private func requestRetentionChange(_ next: RetentionPolicy) {
        guard next != retention else { return }
        TapPulse.shared.fire()
        let all = HistoryStore.shared.load()
        let purgeCount = RetentionPolicy.expiredCount(all, policy: next)
        // .none 與縮短期限都會刪東西 → 確認。永遠／放長／不變 → 直接寫。
        if next == .none || purgeCount > 0 {
            pendingRetention = next
            pendingPurgeCount = purgeCount
            confirmRetention = true
        } else {
            RetentionSettings.policy = next
            retention = next
        }
    }

    private func applyRetentionChange() {
        RetentionSettings.policy = pendingRetention
        retention = pendingRetention
        HistoryStore.shared.save(RetentionPolicy.filter(HistoryStore.shared.load(), policy: pendingRetention))
    }

    var body: some View {
        NavigationStack(path: $debugPath) {
            ScrollViewReader { proxy in
            Form {
                // 幫我加油放最上面、醒目（10-07 Micky：「請把咖啡放到最上面、醒目的位置」）。
                Section {
                    NavigationLink {
                        TipJarScreen()
                            .pushHaptic()
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "cup.and.saucer.fill")
                                .font(.title2)
                                .foregroundStyle(.white)
                                .frame(width: 48, height: 48)
                                .background(Circle().fill(Aurora.orange))
                            VStack(alignment: .leading, spacing: 3) {
                                Text("幫我加油")
                                    .font(.headline)
                                Text("UTUVO Type 免費，喜歡的話可以請我喝杯咖啡。")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .accessibilityIdentifier("tipJarRow")
                    .listRowBackground(Aurora.orange.opacity(0.12))
                }

                Section {
                    NavigationLink {
                        UsageGuideScreen()
                            .pushHaptic()
                    } label: {
                        Label("使用教學：怎麼設定、怎麼用鍵盤講話", systemImage: "questionmark.circle")
                    }
                }

                // 歷史保留期限（Typeless 的 history retention）：改短會刪掉超過期限的歷史，
                // 所以要確認；每日計數（使用數據）不受影響。
                Section {
                    Picker("歷史保留期限", selection: Binding(
                        get: { retention },
                        set: { requestRetentionChange($0) }
                    )) {
                        ForEach(RetentionPolicy.allCases, id: \.self) { p in
                            Text(RetentionPolicy.label(p)).tag(p)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("retentionPicker")
                    Button(role: .destructive) {
                        TapPulse.shared.fire()
                        confirmClearUsage = true
                    } label: {
                        Label("清除使用數據", systemImage: "chart.bar.xaxis")
                    }
                    .accessibilityIdentifier("clearUsageRow")
                } header: {
                    Text("歷史與使用數據")
                } footer: {
                    Text("選「不保留」之後就不再寫入歷史紀錄，但使用數據照算。保留期限只管歷史（星號也會跟著被刪），首頁的字數與時長來自另外計的每日數字，刪歷史不會少。")
                }
                .confirmationDialog(
                    String(localized: "改成「\(RetentionPolicy.label(pendingRetention))」會刪掉 \(pendingPurgeCount) 筆歷史。"),
                    isPresented: $confirmRetention, titleVisibility: .visible
                ) {
                    Button(String(localized: "刪掉並改成這個期限"), role: .destructive) { applyRetentionChange() }
                    Button(String(localized: "取消"), role: .cancel) {}
                } message: {
                    Text(String(localized: "有星號的紀錄也會跟著被刪。使用數據不受影響。"))
                }
                .confirmationDialog(String(localized: "要清除所有使用數據嗎？"), isPresented: $confirmClearUsage, titleVisibility: .visible) {
                    Button(String(localized: "清除"), role: .destructive) {
                        DailyUsageStore.shared.reset()
                        retention = RetentionSettings.policy
                    }
                    Button(String(localized: "取消"), role: .cancel) {}
                } message: {
                    Text(String(localized: "會清掉所有每日字數與時長、連續天數與熱圖。歷史紀錄不受影響。"))
                }

                // 震動放根頁看得到的地方（10-07 Micky：「沒有看到哪裡可以設定震動」——原本藏在 鍵盤 → 打字手感）。
                Section {
                    Toggle(isOn: $uiHaptics) {
                        Label("介面震動", systemImage: "iphone.radiowaves.left.and.right")
                    }
                    .accessibilityIdentifier("uiHaptics")
                    .feedbackOnChange(of: uiHaptics)
                    NavigationLink {
                        KeyFeedbackScreen()
                            .pushHaptic()
                    } label: {
                        Label("打字手感：按鍵震動、按鍵聲音", systemImage: "hand.tap")
                    }
                    .accessibilityIdentifier("keyFeedbackRow")
                } header: {
                    Text("震動與手感")
                } footer: {
                    Text("點光球開始／停止、切換語言與鍵盤版面、App 裡切換任何設定時輕震一下。打字按鍵的震動在「打字手感」裡調。")
                }

                Section("鍵盤") {
                    Text("設定 → 一般 → 鍵盤 → 鍵盤 → 新增鍵盤 → UTUVO Type，再打開「允許完整取用」。之後在任何輸入框按 🌐 切到 UTUVO Type。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button {
                        TapPulse.shared.fire()
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
                    .feedbackOnChange(of: sessionMinutes)
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
                    .feedbackOnChange(of: hantInput)
                    NavigationLink {
                        TranslationLanguagesView()
                            .pushHaptic()
                    } label: {
                        LabeledContent("鍵盤翻譯語言", value: QuickPickStore.targets().map(\.displayName).joined(separator: "、"))
                    }
                }

                // 語言變體（工單 ios-C 第 1 點）：影響整理後的用字拼寫，**不換辨識模型**。
                Section {
                    Picker("英文用字", selection: variantBinding(.englishUS)) {
                        ForEach(DictationLanguage.englishUS.variants, id: \.self) { v in
                            Text(v.displayName(traditional: true)).tag(v)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("englishVariantPicker")
                    Picker("繁體中文用字", selection: variantBinding(.traditionalChinese)) {
                        ForEach(DictationLanguage.traditionalChinese.variants, id: \.self) { v in
                            Text(v.displayName(traditional: true)).tag(v)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("hantVariantPicker")
                    Picker("簡體中文用字", selection: variantBinding(.simplifiedChinese)) {
                        ForEach(DictationLanguage.simplifiedChinese.variants, id: \.self) { v in
                            Text(v.displayName(traditional: true)).tag(v)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("hansVariantPicker")
                } header: {
                    Text("聽寫語言變體")
                } footer: {
                    Text("只影響整理後的用字與拼寫（英文 color／colour、繁中台灣／香港用字），不會換掉辨識模型，語言照樣是你選的那個。日文、韓文沒有可選的變體。")
                }

                LocalASRSection()

                // 介面語言與外觀（工單 ios-C 第 2 點）。
                Section {
                    Picker("介面語言", selection: Binding(
                        get: { interfaceLanguage },
                        set: { applyInterfaceLanguage($0) }
                    )) {
                        ForEach(InterfaceLanguage.allCases) { l in
                            Text(l.displayName(traditional: true)).tag(l)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("interfaceLanguagePicker")
                    .feedbackOnChange(of: interfaceLanguage)
                    if interfaceLanguageNeedsRestart {
                        Label(String(localized: "已切換，重開 UTUVO Type 後才會生效。"), systemImage: "arrow.clockwise")
                            .font(.footnote)
                            .foregroundStyle(Aurora.orange)
                            .accessibilityIdentifier("interfaceLanguageRestartHint")
                    } else {
                        Text(String(localized: "切換後需要完全關掉再開 UTUVO Type 才會生效（iOS 的規則）。鍵盤也會跟著這個設定；選「跟隨系統」時，鍵盤跟著你的聽寫語言。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Picker("外觀", selection: Binding(
                        get: { appearance },
                        set: { applyAppearance($0) }
                    )) {
                        ForEach(AppearancePreference.allCases) { a in
                            Text(a.displayName(traditional: true)).tag(a)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("appearancePicker")
                    .feedbackOnChange(of: appearance)
                } header: {
                    Text("介面語言與外觀")
                } footer: {
                    Text("外觀會連鍵盤一起變（鍵盤跟著同一個設定走）。介面語言也會套到鍵盤；選「跟隨系統」時，鍵盤跟著你的聽寫語言。")
                }

                // 小聲說話（工單 ios-C 第 4 點）。
                Section {
                    Toggle(isOn: $quietMode) {
                        Label("小聲說話", systemImage: "waveform")
                    }
                    .accessibilityIdentifier("quietModeToggle")
                    .feedbackOnChange(of: quietMode)
                } header: {
                    Text("麥克風")
                } footer: {
                    Text("打開後會把錄到的聲音先放大（數位增益，約 +8 dB，放大後會限幅避免破音），同時把「這段算靜音」的判斷放寬，讓輕聲講也能被聽到。App 內聽寫與鍵盤講話都有效；iOS 沒有公開的麥克風硬體增益 API，所以是在軟體裡放大。")
                }

                Section("語音處理路徑") {
                    Picker("處理方式", selection: $processingMode) {
                        ForEach(DictationProcessingMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }
                    .onChange(of: processingMode) { _, mode in
                        if mode != DictationRouteSettings.mode { DictationRouteSettings.mode = mode }
                    }
                    Text(processingMode == .local
                         ? "鍵盤使用 Apple 裝置端辨識，再由本機模型整理；音訊與文字不上傳。Qwen 僅供主 App 前景聽寫。"
                         : "使用選定的雲端辨識與整理服務；失敗時改用 Apple 裝置端辨識結果與本機整理，完成後一次貼入。")
                        .font(.caption).foregroundStyle(.secondary)
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
                    .feedbackOnChange(of: dictionaryMode)
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
                            TapPulse.shared.fire()
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
                            .pushHaptic()
                            .onDisappear { DictionaryCloud.sync(); dictionary = DictionaryStore.shared.dictionary }
                    } label: {
                        Label("詞庫包與匯入", systemImage: "books.vertical")
                    }
                    .accessibilityIdentifier("vocabularyPacksRow")
                    // 分頁瀏覽（全部／自動加入／手動加入＋搜尋）。下面那個收合清單留著當快速刪除。
                    NavigationLink {
                        DictionaryBrowserView()
                            .pushHaptic()
                            .onDisappear { dictionary = DictionaryStore.shared.dictionary }
                    } label: {
                        Label("瀏覽字典", systemImage: "list.bullet.rectangle")
                    }
                    .accessibilityIdentifier("dictionaryBrowseRow")
                    // 跟 Android、Mac 互通的字典檔；iPhone↔Mac 另外會經 iCloud 自動同步。
                    HStack {
                        Button {
                            TapPulse.shared.fire()
                            exportDocument = DictionaryFile(data: DictionaryStore.shared.exportData())
                            exporting = true
                        } label: { Label("匯出字典檔", systemImage: "square.and.arrow.up") }
                        .accessibilityIdentifier("dictExport")
                        Spacer()
                        Button { TapPulse.shared.fire(); importing = true } label: { Label("匯入字典檔", systemImage: "square.and.arrow.down") }
                            .accessibilityIdentifier("dictImport")
                    }
                    .buttonStyle(.borderless)
                    if let dictionaryMessage {
                        Text(dictionaryMessage).font(.footnote).foregroundStyle(.secondary)
                            .accessibilityIdentifier("dictIoMessage")
                    }
                    // 「已加入的詞」快速清單。**用 Button ＋ 條件列，不用 DisclosureGroup**：
                    // DisclosureGroup 是容器，`.accessibilityIdentifier` 會同時套到展開後的內容容器上，
                    // 同一個 identifier 就對應到兩個無障礙元素（2026-10-13 UI 測試回歸：
                    // 「Failed to tap dictionaryListToggle: Multiple matching elements found」）。
                    // 自己畫一列，identifier 只掛在這一個 Button 上，展開／收合都只有一個。
                    Button {
                        TapPulse.shared.fire()
                        dictionaryListExpanded.toggle()
                    } label: {
                        HStack {
                            Text("已加入的詞（\(dictionary.count)）")
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .rotationEffect(.degrees(dictionaryListExpanded ? 90 : 0))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("dictionaryListToggle")
                    .id(Self.dictionaryListAnchor)
                    .feedbackOnChange(of: dictionaryListExpanded)
                    if dictionaryListExpanded {
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
                                TapPulse.shared.fire()
                                // 跟字典瀏覽頁同一個函式：刪掉自動學到的詞也要記進忽略清單，
                                // 否則同一組修正一下就被學回來。
                                LearnedVocabulary.removeFromDictionary(entry.key)
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

                Section {
                    NavigationLink {
                        SmartCleanupScreen()
                            .pushHaptic()
                    } label: {
                        LabeledContent("智慧整理", value: SmartCleanup.usesOnDevice ? String(localized: "本機模型")
                                                        : SmartCleanup.isEnabled ? String(localized: "已開啟") : String(localized: "未設定"))
                    }
                    .accessibilityIdentifier("smartCleanupRow")
                } header: {
                    Text("智慧整理（選配）")
                } footer: {
                    Text("整理服務會收到辨識文字，以及你在整理設定中明確開啟的欄位脈絡；原始錄音不會轉送到整理服務。")
                }

                Section("關於") {
                    LabeledContent("版本", value: "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—") (iOS)")
                    LabeledContent("辨識引擎", value: String(localized: "Apple Speech（裝置端優先）"))
                    LabeledContent("文字清理", value: "UTUVOTypeCore deterministic normalizer")
                    LabeledContent("鍵盤", value: String(localized: "同一套清理＋字典，寫回歷史"))
                }
            }
            .navigationTitle("設定")
            // 展開字典清單時把那一列捲到畫面上緣（2026-10-13）。
            // 這列常常正好停在浮動分頁列後面：展開之後新冒出來的每一列都落在分頁列底下、
            // 甚至畫面外，點開等於什麼都沒看到。捲上去之後展開的內容才真的看得到。
            .onChange(of: dictionaryListExpanded) { _, expanded in
                guard expanded else { return }
                proxy.scrollTo(Self.dictionaryListAnchor, anchor: .top)
            }
            // 截圖用 DEBUG 路徑：`utuvo.type.ios.debugDictionary` = 1 時開啟就直接進字典分頁。
            .navigationDestination(for: Int.self) { _ in
                DictionaryBrowserView()
                    .onDisappear { dictionary = DictionaryStore.shared.dictionary }
            }
            .onAppear {
                processingMode = DictationRouteSettings.mode
                dictionary = DictionaryStore.shared.dictionary
                // 變體／介面語言／外觀存在 App Group，鍵盤那邊也可能改到（鍵盤沒有設定頁，
                // 但匯入字典等流程會碰同一份偏好）——每次打開設定頁都重新讀一次。
                englishVariant = LanguageVariantStore.variant(for: .englishUS)
                hantVariant = LanguageVariantStore.variant(for: .traditionalChinese)
                hansVariant = LanguageVariantStore.variant(for: .simplifiedChinese)
                interfaceLanguage = InterfaceLanguageStore.current
                appearance = AppearanceStore.current
                #if DEBUG
                if UserDefaults.standard.bool(forKey: "utuvo.type.ios.debugDictionary"), debugPath.isEmpty {
                    debugPath = [0]
                }
                #endif
            }
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
    }

    /// 捲動定位用（「展開字典清單 → 把那一列捲到畫面上緣」）。
    private static let dictionaryListAnchor = "settings.dictionaryListToggle"

    // MARK: - 語言變體 / 介面語言 / 外觀 / 小聲模式

    /// 某個聽寫語言的變體選擇（App Group，鍵盤與主 app 共用同一份）。
    /// 值放在 `@State` 而不是直接讀 UserDefaults：Picker 的 selection 必須是可觀察的狀態，
    /// 直接每次讀 UserDefaults 會讓選完不重繪。
    private func variantBinding(_ language: DictationLanguage) -> Binding<LanguageVariant> {
        Binding(
            get: {
                switch language {
                case .englishUS: return englishVariant
                case .traditionalChinese: return hantVariant
                case .simplifiedChinese: return hansVariant
                default: return language.defaultVariant
                }
            },
            set: { newValue in
                LanguageVariantStore.setVariant(newValue, for: language)
                switch language {
                case .englishUS: englishVariant = newValue
                case .traditionalChinese: hantVariant = newValue
                case .simplifiedChinese: hansVariant = newValue
                default: break
                }
            })
    }

    @State private var englishVariant: LanguageVariant = LanguageVariantStore.variant(for: .englishUS)
    @State private var hantVariant: LanguageVariant = LanguageVariantStore.variant(for: .traditionalChinese)
    @State private var hansVariant: LanguageVariant = LanguageVariantStore.variant(for: .simplifiedChinese)
    @State private var interfaceLanguage: InterfaceLanguage = InterfaceLanguageStore.current
    /// 切換後要重開 App 才會生效——用這個旗標在畫面上明講，不要讓使用者以為沒反應。
    @State private var interfaceLanguageNeedsRestart = false
    @State private var appearance: AppearancePreference = AppearanceStore.current
    @AppStorage(QuietMode.settingKey, store: QuietMode.defaults) private var quietMode = false

    private func applyInterfaceLanguage(_ next: InterfaceLanguage) {
        interfaceLanguage = next
        InterfaceLanguageStore.current = next
        interfaceLanguageNeedsRestart = InterfaceLanguageStore.apply(next)
    }

    private func applyAppearance(_ next: AppearancePreference) {
        appearance = next
        AppearanceStore.current = next
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
                    TapPulse.shared.fire()
                    let error = IOSSecretStore.save(apiKeyDraft)
                    apiKeyMessageIsError = error != nil
                    apiKeyMessage = error ?? String(localized: "已存進 Keychain。")
                    if error == nil { apiKeyDraft = "" }
                    hasStoredKey = IOSSecretStore.hasKey()
                }
                .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
                Button("清除", role: .destructive) {
                    TapPulse.shared.fire()
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
                .feedbackOnChange(of: strength)
                Toggle("按鍵聲音", isOn: $sound)
                    .accessibilityIdentifier("keySound")
                    .feedbackOnChange(of: sound)
            } footer: {
                Text("按下去的當下就震（不是放開才震），選字、切換鍵盤也有。震動需要在系統設定打開「允許完整取用」（跟語音一樣），按鍵聲音不用；手機靜音或系統把觸覺回饋關掉時都不會有。")
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
                    TapPulse.shared.fire()
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
                    TapPulse.shared.fire()
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

/// 點擊震動（2026-10-10 Micky：「切換下面 menu 的時候也要，還有點擊每個選項的時候，不然都沒感覺」）。
/// 每個按鈕／選項的動作第一行呼叫 `fire()`；真正出震動的是 RootView 上綁 `n` 的 `.sensoryFeedback`
/// （view 綁定的原生觸覺，10-07 實機驗過有感；static UIImpactFeedbackGenerator 實機沒感覺）。
private struct PushHaptic: ViewModifier {
    @State private var done = false
    func body(content: Content) -> some View {
        content.onAppear {
            guard !done else { return }
            done = true
            TapPulse.shared.fire()
        }
    }
}

@MainActor @Observable final class TapPulse {
    static let shared = TapPulse()
    private(set) var n = 0
    private var last = Date.distantPast

    /// 同一次點擊可能同時碰到按鈕和外層列的手勢（例如翻譯語言列裡的「下載」）：150 ms 內只震一下。
    func fire(now: Date = Date()) {
        guard UIFeedback.enabled else { return }
        guard now.timeIntervalSince(last) >= 0.15 else { return }
        last = now
        n &+= 1
        UIFeedback.record(source: "tap")
    }
}

extension View {
    /// 掛在 App 最上層一次：TapPulse 每 fire 一次就震一下。
    func tapPulseFeedback() -> some View {
        sensoryFeedback(.impact(weight: .medium, intensity: Double(UIFeedback.intensity)), trigger: TapPulse.shared.n) { _, _ in
            UIFeedback.enabled
        }
    }

    /// 選項列（NavigationLink）點進去的那一頁出現時震一下。不在列上掛手勢：
    /// 10-10 實測 simultaneousGesture 會擋住 NavigationLink（點了進不去）。從更深的頁返回時不重複震。
    func pushHaptic() -> some View { modifier(PushHaptic()) }

    /// 值一變就震一下（設定 → 打字手感 → 介面震動 可關）。用 SwiftUI 原生的 sensoryFeedback（綁在畫面上），
    /// 不用沒有 view 的 UIImpactFeedbackGenerator——第一版那樣做，模擬器計數全對，Micky 實機卻說都沒震。
    func feedbackOnChange<V: Equatable>(of value: V) -> some View {
        sensoryFeedback(.impact(weight: .medium, intensity: Double(UIFeedback.intensity)), trigger: value) { _, _ in UIFeedback.enabled }
            .onChange(of: value) { UIFeedback.record(source: "sensoryFeedback") }
    }

    /// UI 測試：看不見的介面震動計數（只有 DEBUG）。
    @ViewBuilder func uiFeedbackProbe() -> some View {
        #if DEBUG
        overlay(alignment: .topLeading) {
            Text(verbatim: "\(UIFeedbackProbe.shared.count)")
                .font(.system(size: 1))
                .opacity(0.01)
                .accessibilityIdentifier("uiFeedbackCount")
                .allowsHitTesting(false)
        }
        #else
        self
        #endif
    }
}

import SwiftUI
import AppKit
import UTUVOTypeCore

enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case history
    case models
    case advanced
    case about
    case quick
    case localRuntime
    case dictionary
    case shortcuts
    case cloud

    var id: String { rawValue }

    func title(zh: Bool) -> String {
        switch self {
        case .general: return zh ? "一般" : "General"
        case .history: return zh ? "歷史紀錄" : "History"
        case .models: return zh ? "模型" : "Models"
        case .advanced: return zh ? "進階" : "Advanced"
        case .about: return zh ? "關於" : "About"
        case .quick: return zh ? "快速路徑" : "Quick path"
        case .localRuntime: return zh ? "本機 runtime" : "Local runtime"
        case .dictionary: return zh ? "個人字典" : "Dictionary"
        case .shortcuts: return zh ? "快捷鍵與門檻" : "Shortcuts & thresholds"
        case .cloud: return zh ? "雲端（選配）" : "Cloud optional"
        }
    }

    var icon: String {
        switch self {
        case .general: return "hand.tap"
        case .history: return "clock.arrow.circlepath"
        case .models: return "cpu"
        case .advanced: return "gearshape.2"
        case .about: return "info.circle"
        case .quick: return "bolt.fill"
        case .localRuntime: return "desktopcomputer"
        case .dictionary: return "character.book.closed"
        case .shortcuts: return "keyboard"
        case .cloud: return "cloud"
        }
    }

    var isProductSection: Bool {
        switch self {
        case .general, .history, .models, .advanced, .about: return true
        case .quick, .localRuntime, .dictionary, .shortcuts, .cloud: return false
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var preferences: AppPreferences
    @State private var selectedSection: SettingsSection = .general
    @State private var isCapturingShortcut = false
    @State private var dictionaryWord = ""
    @State private var dictionaryOutput = ""
    @State private var isCapturingPostProcessingShortcut = false
    @State private var presetBundleIdentifier = ""
    @State private var presetDisplayName = ""
    @State private var presetPromptHint = ""
    @State private var showingClearHistoryConfirmation = false
    @State private var expandedHistoryMonths: Set<String> = []
    @State private var deviceRefreshToken = UUID()
    @State private var engineRepoRoot: String? = RuntimeBootstrap.locateRepoRoot()
    // 引擎安裝狀態與 popover 的首次啟動卡共用（EngineInstaller.shared），不會兩邊各跑一個 bootstrap。
    @ObservedObject private var installer = EngineInstaller.shared
    // 百鍊 API key 輸入（D8-1，2026-09-11）：只寫 Keychain，永不回顯已存的 key。
    @State private var apiKeyDraft = ""
    @State private var apiKeyMessage: String?
    @State private var apiKeyMessageIsError = false
    @State private var apiKeyStateToken = UUID()
    // 雲端連線自測（2026-09-12）：貼完 key 不用等下次聽寫才知道對不對。
    @State private var cloudProbeResult: String?
    @State private var cloudProbeIsError = false
    @State private var isProbingCloud = false

    init(model: AppModel, initialSection: SettingsSection = .general) {
        self.model = model
        self._preferences = ObservedObject(wrappedValue: model.preferences)
        self._selectedSection = State(initialValue: initialSection)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(spacing: 0) {
                header
                Divider()
                selectedContent
            }
        }
        .frame(minWidth: 1_020, idealWidth: 1_100, minHeight: 680, idealHeight: 760)
        .tint(AppBrand.accent)
        // 玻璃底下要有東西可折射：暖底＋模糊色塊，卡片與側欄才有 Liquid Glass 的層次。
        .background(AmbientBackdrop())
        // 二次元淡色系是固定亮色調；不跟系統深色模式，避免原生控件變深色混搭。
        .colorScheme(AppBrand.colorScheme)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                brandIcon
                    .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 1) {
                    Text("UTUVO Type")
                        .font(AppBrand.ui(13, weight: .semibold))
                    Text(preferences.tr("語音輸入", "Voice input"))
                        .font(AppBrand.ui(10))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 34)
            .padding(.bottom, 16)

            Divider()
                .padding(.horizontal, 12)

            sidebarGroupTitle("TYPE")
            ForEach(SettingsSection.allCases.filter(\.isProductSection)) { section in
                sidebarButton(section)
            }

            sidebarGroupTitle(preferences.tr("組態", "CONFIGURATION"))
            ForEach(SettingsSection.allCases.filter { !$0.isProductSection }) { section in
                sidebarButton(section)
            }

            Spacer()

            // 只留前景 App 名稱；bundle id（com.utuvo.type）是噪音（2026-08-21 產品決定拿掉）。
            Text(model.currentAppName)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, 16)
                .padding(.bottom, 18)
        }
        .frame(width: 205)
        // macOS 26 式浮動側欄：內縮的一片玻璃，不貼視窗邊。
        .glassCard(cornerRadius: 20)
        .padding(.leading, 10)
        .padding(.vertical, 10)
    }

    /// 側欄品牌：真 icon（squircle 玻璃質感），不再用 SF Symbol 湊。
    private var brandIcon: some View {
        Group {
            if let url = Bundle.main.url(forResource: "utuvo-type-logo", withExtension: "png"),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "character.cursor.ibeam")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(AppBrand.accent)
            }
        }
        .shadow(color: AppBrand.accent.opacity(0.22), radius: 5, y: 2)
    }

    private func sidebarGroupTitle(_ title: String) -> some View {
        Text(title)
            .font(AppBrand.mono(9, weight: .bold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 6)
    }

    private func sidebarButton(_ section: SettingsSection) -> some View {
        Button {
            selectedSection = section
        } label: {
            HStack(spacing: 10) {
                Image(systemName: section.icon)
                    .frame(width: 18)
                Text(section.title(zh: preferences.isChineseUI))
                    .font(.callout.weight(selectedSection == section ? .semibold : .regular))
                Spacer()
            }
            .foregroundStyle(selectedSection == section ? AppBrand.accent : .primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background {
                if selectedSection == section {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.clear)
                        .typeGlass(RoundedRectangle(cornerRadius: 10, style: .continuous),
                                   tint: TypeGlass.accentSoftTint, interactive: true,
                                   fallback: AppBrand.accent.opacity(0.13))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private var selectedContent: some View {
        switch selectedSection {
        case .general: generalTab
        case .history: historyTab
        case .models: modelsTab
        case .advanced: advancedTab
        case .about: aboutTab
        case .quick: quickTab
        case .localRuntime: localRuntimeTab
        case .dictionary: dictionaryTab
        case .shortcuts: thresholdsTab
        case .cloud: cloudTab
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(preferences.tr("\(AppBrand.displayName) 設定", "\(AppBrand.displayName) Settings"))
                .font(.title2.weight(.semibold))

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(preferences.backend == .local ? "LOCAL" : "CLOUD")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(preferences.backend == .local ? Color.green : Color.orange)
                Text(preferences.mode.shortName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 30)
        .padding(.bottom, 14)
    }

    /// 開源防呆：本機引擎（venv＋ASR 模型）缺件時的安裝卡；跑 scripts/bootstrap-runtime.sh 並串流進度。
    /// 不會在使用者不知情時下載任何東西——下載只發生在按下按鈕之後。
    private func engineInstallCard(root: String) -> some View {
        settingsCard(
            title: preferences.tr("本機引擎尚未安裝", "Local engine not installed yet"),
            subtitle: preferences.tr(
                "安裝 Python venv 並下載 Qwen3-ASR 模型（約 1.2 GB，一次性，需要網路）；安裝前仍可用雲端模式。",
                "Installs a Python venv and downloads the Qwen3-ASR model (~1.2 GB, one time, network required); cloud mode still works before install."
            ),
            icon: "arrow.down.circle"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Button {
                        installEngine(root: root)
                    } label: {
                        Label(
                            installer.isInstalling
                                ? preferences.tr("安裝中…", "Installing…")
                                : preferences.tr("安裝本機引擎", "Install Local Engine"),
                            systemImage: installer.isInstalling ? "gearshape.2" : "arrow.down.circle.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .glassProminentButton()
                    .disabled(installer.isInstalling)

                    // 取消＝terminate bootstrap 子進程；腳本 idempotent，重跑安全。
                    if installer.isInstalling {
                        Button(preferences.tr("取消", "Cancel"), role: .destructive) {
                            RuntimeBootstrap.terminateActive()
                        }
                    }
                }

                if installer.failed, let diagnosis = installer.diagnosis {
                    EngineInstallFailureView(preferences: preferences, diagnosis: diagnosis, log: installer.log, compact: false) {
                        installEngine(root: root)
                    }
                }

                if !installer.log.isEmpty {
                    // raw log 留給想看的人；一般使用者看上面的卡就夠。
                    DisclosureGroup(preferences.tr("完整安裝紀錄", "Full install log")) {
                    ScrollView {
                        Text(installer.log)
                            .font(AppBrand.mono(9))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 130)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.black.opacity(0.05))
                    )
                    }
                    .font(AppBrand.ui(11))
                }
            }
        }
    }

    private func installEngine(root: String) {
        installer.install(tr: preferences.tr)
    }

    private var generalTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 介面語言放 General 最上面（2026-08-21 使用者回饋在 About 找不到）。
                settingsCard(
                    title: preferences.tr("介面語言與外觀", "Language & Appearance"),
                    subtitle: preferences.tr(
                        "切換後立即套用整個介面。",
                        "Applies to the whole interface immediately."
                    ),
                    icon: "globe"
                ) {
                    settingsPickerRow(
                        preferences.tr("介面語言", "Application Language"),
                        selection: $preferences.appLanguage,
                        options: AppLanguageChoice.allCases,
                        name: { $0.localizedName(zh: preferences.isChineseUI) }
                    )
                    settingsPickerRow(
                        preferences.tr("外觀主題", "Application Theme"),
                        selection: $preferences.appTheme,
                        options: AppThemeChoice.allCases,
                        name: { $0.localizedName(zh: preferences.isChineseUI) }
                    )
                }

                settingsCard(
                    title: preferences.tr("一般", "General"),
                    subtitle: preferences.tr(
                        "快捷鍵與按住說話行為放在同一頁。",
                        "Shortcut and push-to-talk behavior on one page."
                    ),
                    icon: "hand.tap"
                ) {
                    settingsRow(preferences.tr("聽寫快捷鍵", "Transcribe Shortcut")) {
                        HotkeyRecorder(
                            shortcut: $preferences.globalShortcut,
                            isCapturing: $isCapturingShortcut,
                            localize: preferences.tr
                        )
                        .frame(maxWidth: .infinity, minHeight: 34)
                    }

                    settingsRow(
                        preferences.tr("預設快捷鍵", "Default shortcut"),
                        caption: preferences.tr(
                            "預設 ⌥Space；若被 Gemini／ChatGPT／Raycast 等佔用，app 會自動暫用 ⌥` 並在 menu bar 提示。",
                            "Default is ⌥Space; if it is taken by Gemini / ChatGPT / Raycast and friends, the app temporarily uses ⌥` and shows a hint in the menu bar."
                        )
                    ) {
                        Button(preferences.tr("恢復預設 ⌥Space", "Reset to ⌥Space")) {
                            isCapturingShortcut = false
                            preferences.globalShortcut = "⌥Space"
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }

                    settingsRow(
                        preferences.tr("按住說話", "Push to Talk"),
                        caption: preferences.pushToTalkEnabled
                            ? preferences.tr("按住快捷鍵錄音，放開後停止並貼上。", "Hold the shortcut to record; release to stop and paste.")
                            : preferences.tr("按一下開始，再按一下停止。", "Press once to start, again to stop.")
                    ) {
                        Toggle("", isOn: $preferences.pushToTalkEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                }

                // 開源防呆：偵測到本機引擎缺件才顯示安裝卡（docs/OPEN-SOURCE-READINESS.md §二）。
                if let engineRoot = engineRepoRoot, !installer.installed {
                    engineInstallCard(root: engineRoot)
                }

                settingsCard(
                    title: preferences.tr("Qwen3-ASR 0.6B 設定", "Qwen3-ASR 0.6B Settings"),
                    subtitle: preferences.tr(
                        "預設使用繁體中文，也保留中英夾雜的即時辨識路徑。",
                        "Defaults to Traditional Chinese, with a mixed Chinese-English realtime path."
                    ),
                    icon: "waveform"
                ) {
                    settingsPickerRow(
                        preferences.tr("語言", "Language"),
                        selection: $preferences.transcriptionLanguage,
                        options: TranscriptionLanguage.allCases,
                        name: { $0.localizedName(zh: preferences.isChineseUI) }
                    )
                    settingsPickerRow(
                        preferences.tr("輸出文字", "Output Script"),
                        selection: $preferences.outputScript,
                        options: OutputScript.allCases,
                        name: { $0.localizedName(zh: preferences.isChineseUI) }
                    )
                    Text(preferences.tr(
                        "語言、輸出文字與輸入端點會從下一次錄音開始套用。繁體轉換使用台灣用語（軟體、資訊）。",
                        "Language, output script and input endpoint apply from the next recording. Traditional conversion uses Taiwan wording."
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                settingsCard(
                    title: preferences.tr("即時翻譯", "Live Translation"),
                    subtitle: preferences.tr(
                        "按住修飾鍵再按聽寫快捷鍵，貼上該語言的翻譯。",
                        "Hold a modifier with the dictation shortcut to paste a translation."
                    ),
                    icon: "character.book.closed"
                ) {
                    settingsPickerRow(
                        "⇧ + \(preferences.globalShortcut)",
                        selection: $preferences.translationSlotShift,
                        options: TranslationTarget.allCases,
                        name: { $0.localizedName(zh: preferences.isChineseUI) }
                    )
                    settingsPickerRow(
                        "⌘ + \(preferences.globalShortcut)",
                        selection: $preferences.translationSlotCommand,
                        options: TranslationTarget.allCases,
                        name: { $0.localizedName(zh: preferences.isChineseUI) }
                    )
                    settingsPickerRow(
                        "⌃ + \(preferences.globalShortcut)",
                        selection: $preferences.translationSlotControl,
                        options: TranslationTarget.allCases,
                        name: { $0.localizedName(zh: preferences.isChineseUI) }
                    )
                    Text(preferences.tr(
                        "toggle 模式下，停止那一下按的修飾鍵決定語言——先講完再選要翻成什麼。",
                        "In toggle mode the modifier you press to stop decides the language — speak first, then pick."
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                settingsCard(
                    title: preferences.tr("音訊", "Sound"),
                    subtitle: preferences.tr(
                        "選擇 Type 要使用的麥克風、輸入聲道與輸出裝置。",
                        "Choose the microphone, input channel and output device for Type."
                    ),
                    icon: "mic"
                ) {
                    // 卡內小節標題：文字在左、按鈕進右側控制欄。
                    HStack(spacing: 16) {
                        Text(preferences.tr("輸入與輸出裝置", "Input and output devices"))
                            .font(.subheadline.weight(.semibold))
                        Spacer(minLength: 12)
                        Button {
                            inputDevicesCache = AudioDeviceCatalog.inputDevices()
                            outputDevicesCache = AudioDeviceCatalog.outputDevices()
                            deviceRefreshToken = UUID()
                        } label: {
                            Label(preferences.tr("重新整理", "Refresh"), systemImage: "arrow.clockwise")
                        }
                        .glassButton()
                        .frame(width: controlColumnWidth, alignment: .trailing)
                    }

                    settingsPickerRow(
                        preferences.tr("麥克風", "Microphone"),
                        selection: $preferences.inputDeviceUID,
                        options: [""] + inputDevices.map { $0.id },
                        name: { uid in
                            if uid.isEmpty { return preferences.tr("系統預設", "System Default") }
                            return inputDevices.first { $0.id == uid }?.displayName ?? uid
                        }
                    )
                    settingsPickerRow(
                        preferences.tr("輸入聲道", "Input Channel"),
                        selection: $preferences.inputChannel,
                        options: inputChannels,
                        name: { $0.displayName }
                    )
                    settingsRow(preferences.tr("錄音時靜音輸出", "Mute While Recording")) {
                        Toggle("", isOn: $preferences.muteWhileRecording)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    settingsRow(preferences.tr("提示音", "Audio Feedback")) {
                        Toggle("", isOn: $preferences.audioFeedback)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    if preferences.audioFeedback {
                        settingsRow(preferences.tr("提示音量", "Feedback Volume")) {
                            HStack(spacing: 10) {
                                Slider(value: $preferences.audioFeedbackVolume, in: 0 ... 1)
                                Text("\(Int(preferences.audioFeedbackVolume * 100))%")
                                    .font(AppBrand.mono(10))
                                    .frame(width: 42, alignment: .trailing)
                            }
                        }
                    }
                    settingsPickerRow(
                        preferences.tr("輸出裝置", "Output Device"),
                        selection: $preferences.outputDeviceUID,
                        options: [""] + outputDevices.map { $0.id },
                        name: { uid in
                            if uid.isEmpty { return preferences.tr("系統預設", "System Default") }
                            return outputDevices.first { $0.id == uid }?.displayName ?? uid
                        }
                    )

                    Text(preferences.tr(
                        "Output Device 會用於錄音時的靜音保護；Audio Feedback 使用 macOS 系統提示音。",
                        "The output device is used for mute protection while recording; audio feedback uses macOS system sounds."
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if inputDevices.isEmpty {
                        Label(
                            preferences.tr(
                                "目前沒有可列出的輸入裝置；請確認麥克風已連接並允許 \(AppBrand.displayName) 使用。",
                                "No input devices found; make sure a microphone is connected and \(AppBrand.displayName) is allowed to use it."
                            ),
                            systemImage: "exclamationmark.triangle"
                        )
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                settingsCard(
                    title: preferences.tr("目前狀態", "Current Status"),
                    subtitle: preferences.tr(
                        "權限、裝置選擇與預設模式摘要。",
                        "Permissions, device selection and default mode at a glance."
                    ),
                    icon: "checkmark.shield"
                ) {
                    settingsRow(preferences.tr("麥克風", "Microphone")) {
                        statusCapsule(
                            model.microphonePermissionReady ? "READY" : "MISSING",
                            color: model.microphonePermissionReady ? AppBrand.retroGreen : AppBrand.accent
                        )
                    }
                    settingsRow(preferences.tr("輔助使用", "Accessibility")) {
                        statusCapsule(
                            model.accessibilityPermissionReady ? "READY" : "MISSING",
                            color: model.accessibilityPermissionReady ? AppBrand.retroGreen : AppBrand.accent
                        )
                    }
                    settingsRow(preferences.tr("模式", "Mode")) {
                        statusCapsule(preferences.mode.shortName, color: AppBrand.accent)
                    }
                    Text(model.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(24)
        }
        .id(deviceRefreshToken)
        .scrollIndicators(.hidden)
        .onAppear {
            // Settings window 會被 cache；每次打開重探 repo root（使用者可能剛 clone／搬移 repo）。
            engineRepoRoot = RuntimeBootstrap.locateRepoRoot()
            installer.refresh()
        }
        .onChange(of: preferences.inputDeviceUID) { _, _ in
            if !inputChannels.contains(preferences.inputChannel) {
                preferences.inputChannel = .average
            }
        }
    }

    private var historyTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                settingsCard(
                    title: preferences.tr("歷史紀錄", "History"),
                    subtitle: preferences.tr(
                        "保留每次轉錄的原始文字、整理結果與錄音；資料只存於本機。",
                        "Keeps each dictation's raw transcript, formatted result and recording; data stays on this Mac."
                    ),
                    icon: "clock.arrow.circlepath"
                ) {
                    HStack {
                        Label(
                            preferences.tr("目前 \(preferences.historyRecords.count) 筆", "\(preferences.historyRecords.count) records"),
                            systemImage: "archivebox"
                        )
                            .font(.callout)
                        Spacer()
                        Button(preferences.tr("打開錄音資料夾", "Open Recordings Folder")) { model.openRecordingsFolder() }
                        Button(preferences.tr("清空歷史", "Clear History")) { showingClearHistoryConfirmation = true }
                            .buttonStyle(.borderless)
                            .disabled(preferences.historyRecords.isEmpty)
                    }
                }

                if preferences.historyRecords.isEmpty {
                    settingsCard(
                        title: preferences.tr("尚無紀錄", "No records yet"),
                        subtitle: preferences.tr(
                            "完成第一次 Fast Dictate 後，這裡會出現可播放、複製與重試的紀錄。",
                            "After your first Fast Dictate, records you can play, copy and retry will appear here."
                        ),
                        icon: "waveform"
                    ) {
                        Text(preferences.tr(
                            "錄音檔與歷史資料只寫在 Type 自己的資料夾。",
                            "Recordings and history are written only into Type's own folder."
                        ))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    // 以月為單位摺疊，預設全部收合（2026-08-21 產品決定）。
                    ForEach(historyMonths, id: \.key) { month in
                        historyMonthSection(month)
                    }
                }
            }
            .padding(24)
        }
        .scrollIndicators(.hidden)
        .confirmationDialog(
            preferences.tr("清空 UTUVO Type 歷史紀錄？", "Clear UTUVO Type history?"),
            isPresented: $showingClearHistoryConfirmation,
            titleVisibility: .visible
        ) {
            Button(preferences.tr("清空全部", "Clear All"), role: .destructive) { model.clearHistory() }
            Button(preferences.tr("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(preferences.tr(
                "這會一併刪除 Type 自己保存的錄音檔，無法復原。",
                "This also deletes the recordings Type keeps, and cannot be undone."
            ))
        }
    }

    private struct HistoryMonth {
        let key: String
        let title: String
        let records: [HistoryRecord]
    }

    private var historyMonths: [HistoryMonth] {
        let calendar = Calendar.current
        var order: [String] = []
        var buckets: [String: [HistoryRecord]] = [:]
        for record in preferences.historyRecords {
            let comps = calendar.dateComponents([.year, .month], from: record.date)
            let key = String(format: "%04d-%02d", comps.year ?? 0, comps.month ?? 0)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(record)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: preferences.isChineseUI ? "zh_TW" : "en_US")
        formatter.dateFormat = preferences.isChineseUI ? "yyyy 年 M 月" : "MMMM yyyy"
        return order.map { key in
            let records = buckets[key] ?? []
            let title = records.first.map { formatter.string(from: $0.date) } ?? key
            return HistoryMonth(key: key, title: title, records: records)
        }
    }

    private func historyMonthSection(_ month: HistoryMonth) -> some View {
        let expanded = expandedHistoryMonths.contains(month.key)
        return VStack(alignment: .leading, spacing: 12) {
            Button {
                if expanded {
                    expandedHistoryMonths.remove(month.key)
                } else {
                    expandedHistoryMonths.insert(month.key)
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppBrand.accent)
                        .frame(width: 14)
                    Text(month.title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(AppBrand.retroText)
                    Text(preferences.tr("\(month.records.count) 筆", "\(month.records.count) records"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .popoverTile(selected: false, cornerRadius: 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                ForEach(month.records) { record in
                    historyRow(record)
                }
            }
        }
    }

    private func historyRow(_ record: HistoryRecord) -> some View {
        settingsCard(
            title: record.date.formatted(date: .long, time: .shortened),
            subtitle: "\(record.mode.shortName) · \(record.appName ?? preferences.tr("未知 App", "Unknown App")) · \(Int(record.duration.rounded())) \(preferences.tr("秒", "sec"))",
            icon: record.isStarred ? "star.fill" : "waveform"
        ) {
            Text(record.output)
                .font(.callout)
                .lineLimit(8)
                .textSelection(.enabled)

            if record.rawTranscript != record.output {
                DisclosureGroup(preferences.tr("原始 transcript", "Raw transcript")) {
                    Text(record.rawTranscript)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            HStack(spacing: 8) {
                Button {
                    model.playHistory(record)
                } label: {
                    Label(
                        model.playingHistoryID == record.id ? preferences.tr("停止", "Stop") : preferences.tr("播放", "Play"),
                        systemImage: model.playingHistoryID == record.id ? "stop.fill" : "play.fill"
                    )
                }
                Button(preferences.tr("複製", "Copy")) { model.copyHistory(record) }
                Button(record.isStarred ? preferences.tr("取消星標", "Unstar") : preferences.tr("加星標", "Star")) {
                    model.toggleHistoryStar(record)
                }
                Button(preferences.tr("重試", "Retry")) { model.retryHistory(record) }
                Spacer()
                Button(role: .destructive) { model.deleteHistory(record) } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
            .glassButton()
        }
    }

    private var modelsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                settingsCard(
                    title: preferences.tr("已下載模型", "Downloaded Models"),
                    subtitle: preferences.tr(
                        "集中顯示 Type 可用的模型；Type 不會自動下載 27B。",
                        "Every model available to Type in one place; Type never auto-downloads the 27B."
                    ),
                    icon: "cpu"
                ) {
                    modelStatusRow(
                        name: "Qwen3-ASR 0.6B",
                        detail: preferences.localASRCommand.isEmpty
                            ? preferences.tr(
                                "macOS 裝置端語音 fallback（尚未設定獨立 executable）",
                                "macOS on-device speech fallback (no standalone executable configured)"
                            )
                            : preferences.localASRCommand,
                        status: preferences.localASRCommand.isEmpty ? "FALLBACK" : "CONFIGURED",
                        color: .green
                    )
                    modelStatusRow(
                        name: preferences.localEditorModel.isEmpty ? "Deterministic normalizer" : preferences.localEditorModel,
                        detail: preferences.localEditorCommand.isEmpty
                            ? preferences.tr(
                                "Smart 會使用本機 deterministic；設定小型 editor 後才會呼叫模型",
                                "Smart uses the local deterministic pass; a model is only called once a small editor is configured"
                            )
                            : preferences.localEditorCommand,
                        status: preferences.localEditorCommand.isEmpty && preferences.localEditorModel.isEmpty ? "READY" : "CONFIGURED",
                        color: .blue
                    )
                }

                settingsCard(
                    title: preferences.tr("選配雲端模型", "Optional Cloud Models"),
                    subtitle: preferences.tr(
                        "百鍊僅在你手動切換 Cloud backend 或選擇 Deep 時使用；Fast 永遠不呼叫大型模型。",
                        "Bailian is used only when you switch to the cloud backend or choose Deep; Fast never calls large models."
                    ),
                    icon: "cloud"
                ) {
                    modelStatusRow(
                        name: "qwen-audio-3.0-asr-flash-streaming",
                        detail: "WebSocket streaming · partial transcript · context / hotwords",
                        status: preferences.backend == .bailian ? "SELECTED" : "OPTIONAL",
                        color: .orange
                    )
                    modelStatusRow(
                        name: "qwen3.7-flash-2026-07-15",
                        detail: "Formatter primary · thinking disabled · streamed content only",
                        status: "PRIMARY",
                        color: .orange
                    )
                    Text(SecretStore.bailianAPIKey() == nil
                         ? preferences.tr(
                            "未偵測到 Keychain／環境變數 API key；本機模式仍可使用。",
                            "No Keychain or environment API key detected; local mode still works."
                         )
                         : preferences.tr(
                            "已偵測到安全儲存的百鍊 key（只顯示狀態，不顯示密鑰）。",
                            "A securely stored Bailian key was detected (status only; the key is never shown)."
                         ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                settingsCard(
                    title: preferences.tr("僅限 Deep", "Deep only"),
                    subtitle: preferences.tr(
                        "qwen3.7-plus 與本機 27B 只允許在 Deep／長文門檻／使用者明確選擇時出現。",
                        "qwen3.7-plus and the local 27B may appear only for Deep, the long-note threshold, or an explicit choice."
                    ),
                    icon: "lock.shield"
                ) {
                    Label(preferences.tr("不自動下載模型。", "No automatic model downloads."), systemImage: "checkmark.shield")
                    Label(preferences.tr("qwen3.7-max 不進入普通聽寫。", "qwen3.7-max never enters ordinary dictation."), systemImage: "nosign")
                    Label(
                        preferences.tr(
                            "模型失敗時保留原始 transcript 並回退 deterministic。",
                            "On model failure the raw transcript is kept and processing falls back to deterministic."
                        ),
                        systemImage: "arrow.uturn.backward"
                    )
                    // D8-2（2026-09-11）：把「選 Deep 之後實際走什麼」講白，
                    // 不再讓使用者從 routing 原始碼推。
                    Text(preferences.tr(
                        "選 Deep 本身就是 opt-in，沒有第二個開關：設了「Deep 本機 model」走本機 27B；沒設、後端切百鍊走 qwen3.7-plus；兩者都沒有就退回 flash／本機整理。",
                        "Choosing Deep is the opt-in; there is no second switch. With a Deep local model set it runs the local 27B; without one, the Bailian backend runs qwen3.7-plus; with neither it falls back to flash or local formatting."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(24)
        }
        .scrollIndicators(.hidden)
    }

    private func modelStatusRow(name: String, detail: String, status: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "cpu.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.callout.weight(.semibold))
                    .textSelection(.enabled)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Spacer()
            Text(status)
                .font(AppBrand.mono(9, weight: .bold))
                .foregroundStyle(color)
        }
    }

    private var advancedTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                settingsCard(
                    title: "App",
                    subtitle: preferences.tr(
                        "啟動、tray、overlay 與模型生命週期選項。",
                        "Startup, tray, overlay and model lifecycle options."
                    ),
                    icon: "gearshape.2"
                ) {
                    settingsRow(preferences.tr("啟動時隱藏", "Start Hidden")) {
                        Toggle("", isOn: $preferences.startHidden)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    settingsRow(preferences.tr("登入時自動啟動", "Launch on Startup")) {
                        Toggle("", isOn: $preferences.launchOnStartup)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    settingsRow(preferences.tr("顯示選單列圖示", "Show Tray Icon")) {
                        Toggle("", isOn: $preferences.showTrayIcon)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    settingsPickerRow(
                        preferences.tr("錄音浮層", "Overlay"),
                        selection: $preferences.overlayStyle,
                        options: OverlayStyle.allCases,
                        name: { $0.localizedName(zh: preferences.isChineseUI) }
                    )
                    settingsPickerRow(
                        preferences.tr("浮層位置", "Overlay Position"),
                        selection: $preferences.overlayPosition,
                        options: OverlayPosition.allCases,
                        name: { $0.localizedName(zh: preferences.isChineseUI) }
                    )
                    settingsPickerRow(
                        preferences.tr("卸載模型時機", "Unload Model"),
                        selection: $preferences.unloadPolicy,
                        options: UnloadPolicy.allCases,
                        name: { $0.localizedName(zh: preferences.isChineseUI) }
                    )
                    Text(preferences.tr(
                        "Start Hidden 會讓 App 只在 menu bar 運作；Show Tray Icon 關閉後仍可用設定好的全域快捷鍵。",
                        "Start Hidden keeps the app in the menu bar only; with the tray icon off, the global shortcut still works."
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                settingsCard(
                    title: preferences.tr("輸出", "Output"),
                    subtitle: preferences.tr(
                        "貼上方式可調整；不會把 API response 的 reasoning 貼進輸入框。",
                        "Paste behavior is adjustable; API response reasoning is never pasted into the input field."
                    ),
                    icon: "arrow.down.left.and.arrow.up.right"
                ) {
                    settingsPickerRow(
                        preferences.tr("貼上方式", "Paste Method"),
                        selection: $preferences.pasteMethod,
                        options: PasteMethod.allCases,
                        name: { $0.localizedName(zh: preferences.isChineseUI) }
                    )
                    settingsPickerRow(
                        preferences.tr("剪貼簿處理", "Clipboard Handling"),
                        selection: $preferences.clipboardHandling,
                        options: ClipboardHandling.allCases,
                        name: { $0.localizedName(zh: preferences.isChineseUI) }
                    )
                    settingsPickerRow(
                        preferences.tr("自動送出", "Auto Submit"),
                        selection: $preferences.autoSubmit,
                        options: AutoSubmit.allCases,
                        name: { $0.localizedName(zh: preferences.isChineseUI) }
                    )
                    settingsRow(preferences.tr("結尾補一個空格", "Append Trailing Space")) {
                        Toggle("", isOn: $preferences.appendTrailingSpace)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                }

                settingsCard(
                    title: preferences.tr("轉錄", "Transcription"),
                    subtitle: preferences.tr(
                        "Voice activity detection、有限 context 與 formatter 開關。",
                        "Voice activity detection, limited context and formatter switches."
                    ),
                    icon: "waveform"
                ) {
                    settingsRow(preferences.tr("語音活動偵測（VAD）", "Voice Activity Detection")) {
                        Toggle("", isOn: $preferences.voiceActivityDetection)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    settingsRow(preferences.tr("附帶有限的周邊 context", "Include limited surrounding context")) {
                        Toggle("", isOn: $preferences.includeSurroundingContext)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    settingsRow(preferences.tr("後處理", "Post-processing")) {
                        Toggle("", isOn: $preferences.postProcessingEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    settingsRow(preferences.tr("實驗性功能", "Experimental Features")) {
                        Toggle("", isOn: $preferences.experimentalFeatures)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    Text(preferences.tr(
                        "周邊 context 只向 AX 請求目前選取附近最多約 2,000 字，不讀取整個螢幕或整份文件。",
                        "Surrounding context only asks AX for up to about 2,000 characters near the current selection; it never reads the whole screen or document."
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                settingsCard(
                    title: preferences.tr("歷史紀錄", "History"),
                    subtitle: preferences.tr(
                        "控制本機歷史資料與錄音保留期限。",
                        "Controls local history data and how long recordings are kept."
                    ),
                    icon: "clock.arrow.circlepath"
                ) {
                    settingsRow(preferences.tr("歷史筆數上限", "History Limit")) {
                        HStack(spacing: 6) {
                            TextField("20", value: $preferences.historyLimit, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: .infinity)
                            Text(preferences.tr("筆", "entries"))
                                .foregroundStyle(.secondary)
                        }
                    }
                    settingsPickerRow(
                        preferences.tr("自動刪除錄音", "Auto-Delete Recordings"),
                        selection: $preferences.autoDeletePolicy,
                        options: AutoDeletePolicy.allCases,
                        name: { $0.localizedName(zh: preferences.isChineseUI) }
                    )
                }

                settingsCard(
                    title: preferences.tr("Formatter prompt", "Formatter prompt"),
                    subtitle: preferences.tr(
                        "formatter-v1.txt 可編輯、可測試；留空使用產品內建範本。",
                        "formatter-v1.txt is editable and testable; leave empty to use the built-in template."
                    ),
                    icon: "text.quote"
                ) {
                    settingsRow(preferences.tr("外部 prompt 檔案路徑（可留空）", "External prompt file path (optional)")) {
                        HStack(spacing: 8) {
                            TextField(preferences.tr("可留空", "optional"), text: $preferences.formatterPromptPath)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: .infinity)
                            Button(preferences.tr("選擇…", "Choose…")) { choosePromptFile() }
                        }
                    }
                    Text(preferences.tr(
                        "只允許替換產品自己的 formatter template；API key 永遠不會寫進 prompt。",
                        "Only the product's own formatter template can be replaced; the API key is never written into the prompt."
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                settingsCard(
                    title: preferences.tr("後處理快捷鍵", "Post-processing shortcut"),
                    subtitle: preferences.tr(
                        "重新整理最後一段文字；不會重新錄音。預設為 ⌘⌥P，可自行清除或改成 F13–F20。",
                        "Re-formats the last text without re-recording. Defaults to ⌘⌥P; clear it or set F13–F20."
                    ),
                    icon: "wand.and.stars"
                ) {
                    settingsRow(
                        preferences.tr("快捷鍵", "Shortcut"),
                        caption: preferences.tr(
                            "若沒有最後結果，快捷鍵不會做任何事。",
                            "If there is no last result, the shortcut does nothing."
                        )
                    ) {
                        HStack(spacing: 8) {
                            HotkeyRecorder(
                                shortcut: $preferences.postProcessingShortcut,
                                isCapturing: $isCapturingPostProcessingShortcut,
                                localize: preferences.tr
                            )
                            .frame(maxWidth: .infinity, minHeight: 34)
                            Button(preferences.tr("清除", "Clear")) {
                                isCapturingPostProcessingShortcut = false
                                preferences.postProcessingShortcut = ""
                            }
                            .glassButton()
                        }
                    }
                }

                appPresetsCard
            }
            .padding(24)
        }
        .scrollIndicators(.hidden)
    }

    private var appPresetsCard: some View {
        settingsCard(
            title: preferences.tr("App 預設組", "App Presets"),
            subtitle: preferences.tr(
                "依 foreground app bundle id 套用有限語氣提示；不讀取完整螢幕內容。",
                "Applies a limited tone hint per foreground app bundle id; never reads full screen content."
            ),
            icon: "rectangle.3.group"
        ) {
            HStack(spacing: 8) {
                TextField(preferences.tr("Bundle ID，例如 com.apple.Notes", "Bundle ID, e.g. com.apple.Notes"), text: $presetBundleIdentifier)
                    .textFieldStyle(.roundedBorder)
                TextField(preferences.tr("顯示名稱", "Display name"), text: $presetDisplayName)
                    .textFieldStyle(.roundedBorder)
            }
            TextField(preferences.tr("Prompt hint（可留空）", "Prompt hint (optional)"), text: $presetPromptHint)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button(preferences.tr("加入 preset", "Add preset")) { addPreset() }
                    .glassProminentButton()
                    .disabled(presetBundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text(preferences.tr("目前 \(preferences.appPresets.count) 個 preset", "\(preferences.appPresets.count) presets"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(preferences.appPresets) { preset in
                HStack(spacing: 8) {
                    Image(systemName: "app.badge")
                        .foregroundStyle(AppBrand.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(preset.displayName.isEmpty ? preset.bundleIdentifier : preset.displayName)
                            .font(.callout.weight(.medium))
                        Text(preset.bundleIdentifier)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { preset.enabled },
                        set: { enabled in
                            var updated = preset
                            updated.enabled = enabled
                            preferences.saveAppPreset(updated)
                        }
                    ))
                    .labelsHidden()
                    Button(role: .destructive) { preferences.removeAppPreset(id: preset.id) } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private var aboutTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                settingsCard(
                    title: preferences.tr("關於 UTUVO Type", "About UTUVO Type"),
                    subtitle: preferences.tr(
                        "獨立產品線：本機優先的 macOS menu bar 語音輸入 App。",
                        "A standalone product line: local-first macOS menu bar voice input app."
                    ),
                    icon: "info.circle"
                ) {
                    Text(preferences.tr(
                        "介面語言與外觀主題已移到「一般」分頁最上方。",
                        "Language and theme options now live at the top of the General tab."
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Text(preferences.tr("版本", "Version"))
                        Spacer()
                        Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0")
                            .font(AppBrand.mono(12, weight: .medium))
                    }
                }

                settingsCard(
                    title: preferences.tr("權限", "Permissions"),
                    subtitle: preferences.tr(
                        "權限只屬於 UTUVO Type。",
                        "Permissions belong to UTUVO Type only."
                    ),
                    icon: "lock.shield"
                ) {
                    permissionStatusRow(preferences.tr("麥克風", "Microphone"), ready: model.microphonePermissionReady)
                    permissionStatusRow(preferences.tr("輔助使用", "Accessibility"), ready: model.accessibilityPermissionReady)
                    HStack {
                        Button(preferences.tr("打開系統設定", "Open System Settings")) { model.openMissingPermissionSettings() }
                        Text(model.statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                settingsCard(
                    title: preferences.tr("App 資料位置", "App Data Directory"),
                    subtitle: preferences.tr(
                        "資料、錄音與 log 位置；所有路徑都在 Type 自己的命名空間。",
                        "Data, recordings and log locations; every path lives in Type's own namespace."
                    ),
                    icon: "folder"
                ) {
                    pathRow(preferences.tr("資料", "Data"), path: preferences.applicationSupportDirectory, open: preferences.applicationSupportDirectory)
                    pathRow(preferences.tr("錄音", "Recordings"), path: preferences.recordingsDirectory, open: preferences.recordingsDirectory)
                    pathRow(preferences.tr("Log", "Logs"), path: preferences.logDirectory, open: preferences.logDirectory)
                }

                settingsCard(
                    title: preferences.tr("開源邊界", "Open source boundaries"),
                    subtitle: preferences.tr(
                        "本 App 的程式碼、引擎與資料都在自己的 repo 與資料夾裡。",
                        "Everything this app runs on lives in its own repo and its own folders."
                    ),
                    icon: "lock.open"
                ) {
                    Text("Engine: \(engineRepoRoot ?? preferences.tr("（找不到引擎腳本；設 UTUVO_TYPE_ROOT）", "(engine scripts not found; set UTUVO_TYPE_ROOT)"))")
                        .font(AppBrand.mono(10))
                        .textSelection(.enabled)
                    if let engineRepoRoot {
                        Text("Models: \(RuntimeBootstrap.engineHome(for: engineRepoRoot))")
                            .font(AppBrand.mono(10))
                            .textSelection(.enabled)
                    }
                    Text(preferences.tr(
                        "本 App 不會改動其他 App 的設定與原始碼。",
                        "This app never touches other apps' settings or source."
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
        }
        .scrollIndicators(.hidden)
    }

    private func permissionStatusRow(_ title: String, ready: Bool) -> some View {
        HStack {
            Image(systemName: ready ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ready ? .green : .orange)
            Text(title)
            Spacer()
            Text(ready ? "READY" : "MISSING")
                .font(AppBrand.mono(10, weight: .bold))
                .foregroundStyle(ready ? .green : .orange)
        }
    }

    private func pathRow(_ title: String, path: URL, open: URL) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.callout.weight(.medium))
                .frame(width: 90, alignment: .leading)
            Text(path.path)
                .font(AppBrand.mono(9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
            Button(preferences.tr("打開", "Open")) { NSWorkspace.shared.open(open) }
                .glassButton()
        }
    }

    private var quickTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                settingsCard(
                    title: preferences.tr("預設工作模式", "Default Mode"),
                    subtitle: preferences.tr(
                        "一般聽寫建議使用 Fast；它不會呼叫任何 LLM。",
                        "Fast is recommended for everyday dictation; it never calls an LLM."
                    ),
                    icon: "slider.horizontal.3"
                ) {
                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                        spacing: 10
                    ) {
                        settingsModeTile(.fast, title: "Fast Dictate", subtitle: preferences.tr("最快・ASR + deterministic", "Fastest · ASR + deterministic"), icon: "bolt.fill")
                        settingsModeTile(.smart, title: "Smart Dictate", subtitle: preferences.tr("本機小型 editor", "Local small editor"), icon: "sparkles")
                        settingsModeTile(.editSelection, title: "Edit Selection", subtitle: preferences.tr("改寫目前選取文字", "Rewrites the current selection"), icon: "square.and.pencil")
                        settingsModeTile(.deep, title: "Deep / Long Note", subtitle: preferences.tr("手動才會啟用長文路徑", "Long-form path, manual only"), icon: "doc.text")
                    }
                }

                settingsCard(
                    title: preferences.tr("使用中的後端", "Active Backend"),
                    subtitle: preferences.tr(
                        "這裡只切換 Type 自己的後端。",
                        "Switches Type's own backend only."
                    ),
                    icon: "arrow.triangle.branch"
                ) {
                    settingsPickerRow(
                        preferences.tr("ASR／整理後端", "ASR / formatting backend"),
                        selection: $preferences.backend,
                        options: AppBackend.allCases,
                        name: { $0 == .local
                            ? preferences.tr("本機優先", "Local first")
                            : preferences.tr("百鍊", "Bailian") }
                    )

                    HStack(spacing: 10) {
                        Image(systemName: preferences.backend == .local ? "checkmark.shield.fill" : "cloud.fill")
                            .foregroundStyle(preferences.backend == .local ? Color.green : Color.orange)
                        Text(preferences.backend == .local
                             ? preferences.tr(
                                "目前為本機快速路徑：Qwen3-ASR 0.6B → deterministic normalizer。",
                                "Currently on the local fast path: Qwen3-ASR 0.6B → deterministic normalizer."
                             )
                             : preferences.tr(
                                "百鍊是選配後端；若雲端失敗，仍會保留 transcript 並回退本機整理。",
                                "Bailian is an optional backend; if the cloud fails, the transcript is kept and formatting falls back to local."
                             ))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                settingsCard(
                    title: preferences.tr("快速狀態", "Quick Status"),
                    subtitle: preferences.tr(
                        "目前安裝的 runtime 與預設策略",
                        "Installed runtimes and default policy"
                    ),
                    icon: "speedometer"
                ) {
                    settingsRow("ASR") {
                        statusCapsule("Qwen3 0.6B", color: .green)
                    }
                    settingsRow("Fast") {
                        statusCapsule(preferences.tr("不呼叫 LLM", "No LLM calls"), color: .blue)
                    }
                    settingsRow("27B") {
                        statusCapsule(preferences.tr("未啟用", "Not enabled"), color: .secondary)
                    }
                    Text(preferences.tr(
                        "停止說話後才送出本機音檔進行轉錄；本機 ASR runtime 會保持 warm，避免每次重新載入模型。",
                        "Audio is sent for transcription only after you stop speaking; the local ASR runtime stays warm to avoid reloading the model."
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
        }
        .scrollIndicators(.hidden)
    }

    private var localRuntimeTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                settingsCard(
                    title: preferences.tr("本機語音辨識", "Local Speech Recognition"),
                    subtitle: preferences.tr(
                        "使用獨立 Qwen3-ASR 0.6B runtime；留空才會嘗試 macOS speech fallback。",
                        "Uses a standalone Qwen3-ASR 0.6B runtime; the macOS speech fallback is tried only when left empty."
                    ),
                    icon: "waveform"
                ) {
                    labeledField(preferences.tr("ASR command", "ASR command"), text: $preferences.localASRCommand)
                    labeledField(preferences.tr("ASR arguments", "ASR arguments"), text: $preferences.localASRArguments)
                    Text(preferences.tr(
                        "用 {audio} 代表 App 產生的暫存 WAV 路徑。預設已接到產品內 runtime。",
                        "{audio} stands for the temporary WAV path the app produces. The built-in runtime is wired up by default."
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                settingsCard(
                    title: preferences.tr("本機文字整理", "Local Text Formatting"),
                    subtitle: preferences.tr(
                        "Smart / Edit Selection 才會使用；Fast 永遠跳過 editor。",
                        "Used only by Smart / Edit Selection; Fast always skips the editor."
                    ),
                    icon: "text.badge.checkmark"
                ) {
                    labeledField(preferences.tr("小型 editor command", "Small editor command"), text: $preferences.localEditorCommand)
                    labeledField(preferences.tr("小型 editor model（可留空）", "Small editor model (optional)"), text: $preferences.localEditorModel)
                    Text(preferences.tr(
                        "目前可使用產品內 Qwen3 4B editor。若 model 留空，會只使用 deterministic normalizer。",
                        "The built-in Qwen3 4B editor is available. With model left empty, only the deterministic normalizer runs."
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                settingsCard(
                    title: "Deep / Long Note",
                    subtitle: preferences.tr(
                        "只在手動 Deep、長文門檻或明確選擇時才允許；不會自動下載 27B。",
                        "Allowed only for manual Deep, the long-note threshold, or an explicit choice; the 27B is never auto-downloaded."
                    ),
                    icon: "arrow.down.right.and.arrow.up.left"
                ) {
                    labeledField(preferences.tr("Deep 本機 model（手動設定）", "Deep local model (manual)"), text: $preferences.localDeepModel)
                    Text(preferences.tr(
                        "留空代表 Deep 也只保留本機 deterministic 結果。大型模型測試會等快速路徑確認後再進行。",
                        "Empty means Deep also keeps only the local deterministic result. Large-model testing waits until the fast path is confirmed."
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
        }
        .scrollIndicators(.hidden)
    }

    private var dictionaryTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                settingsCard(
                    title: preferences.tr("個人字典", "Personal Dictionary"),
                    subtitle: preferences.tr(
                        "輸入一個詞、按加入，再從詞條旁邊移除；不需要編輯 JSON。",
                        "Type a word and add it, then remove it from its chip; no JSON editing needed."
                    ),
                    icon: "character.book.closed"
                ) {
                    HStack(spacing: 8) {
                        TextField(preferences.tr("新增詞彙，例如：UTUVO Type", "Add a term, e.g. UTUVO Type"), text: $dictionaryWord)
                            .textFieldStyle(.roundedBorder)
                        TextField(preferences.tr("輸出寫法（可留空）", "Output spelling (optional)"), text: $dictionaryOutput)
                            .textFieldStyle(.roundedBorder)
                        Button(preferences.tr("加入", "Add")) { addDictionaryTerm() }
                            .glassProminentButton()
                            .disabled(dictionaryWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    if preferences.dictionary.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "text.badge.plus")
                                .foregroundStyle(AppBrand.accent)
                            Text(preferences.tr(
                                "尚未加入詞彙。可輸入品牌、姓名、產品名或常用英文詞。",
                                "No terms yet. Add brands, names, product names or frequent English words."
                            ))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    } else {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 190), spacing: 8)],
                            spacing: 8
                        ) {
                            ForEach(dictionaryEntries, id: \.source) { entry in
                                dictionaryChip(entry)
                            }
                        }
                    }

                    HStack {
                        Text(preferences.tr(
                            "目前 \(preferences.dictionary.count) 個詞條；會套用到本機整理與 ASR context。",
                            "\(preferences.dictionary.count) terms; applied to local formatting and ASR context."
                        ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(preferences.tr("清空全部", "Clear All")) { preferences.resetDictionaryToEmpty() }
                            .buttonStyle(.borderless)
                    }
                }

                settingsCard(
                    title: preferences.tr("目前解析狀態", "Current Status"),
                    subtitle: preferences.tr(
                        "設定會即時保存到 Type 自己的 UserDefaults。",
                        "Settings save immediately to Type's own UserDefaults."
                    ),
                    icon: "checkmark.circle"
                ) {
                    Text(model.statusMessage)
                        .font(.callout)
                        .textSelection(.enabled)
                    Text(preferences.tr(
                        "字典解析失敗時，App 會以空字典繼續，不會讓聽寫流程消失。",
                        "If the dictionary fails to parse, the app continues with an empty one; dictation keeps working."
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
        }
        .scrollIndicators(.hidden)
    }

    private var thresholdsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                settingsCard(
                    title: preferences.tr("快捷鍵", "Shortcut"),
                    subtitle: preferences.tr(
                        "點擊按鈕後直接按想使用的按鍵，支援 F1–F20、Fn＋字母/數字與 ⌘⌥⌃⇧ 修飾鍵。",
                        "Click the button, then press the keys you want; supports F1–F20, Fn + letter/digit and ⌘⌥⌃⇧ modifiers."
                    ),
                    icon: "keyboard"
                ) {
                    settingsRow(preferences.tr("快捷鍵", "Shortcut")) {
                        VStack(alignment: .trailing, spacing: 8) {
                            HotkeyRecorder(
                                shortcut: $preferences.globalShortcut,
                                isCapturing: $isCapturingShortcut,
                                localize: preferences.tr
                            )
                            .frame(maxWidth: .infinity, minHeight: 34)
                            HStack(spacing: 8) {
                                Button(preferences.tr("清除", "Clear")) {
                                    isCapturingShortcut = false
                                    preferences.globalShortcut = ""
                                }
                                .glassButton()
                                Button(preferences.tr("恢復預設 ⌥Space", "Reset to ⌥Space")) {
                                    isCapturingShortcut = false
                                    preferences.globalShortcut = "⌥Space"
                                }
                                .glassButton()
                            }
                        }
                    }
                    Text(preferences.globalShortcut.isEmpty
                         ? preferences.tr(
                            "目前沒有全域快捷鍵；你仍可用 menu bar 按鈕開始。",
                            "No global shortcut set; you can still start from the menu bar button."
                         )
                         : preferences.tr(
                            "目前快捷鍵：\(preferences.globalShortcut)。修改後會立即重新註冊，不需要重開 App。",
                            "Current shortcut: \(preferences.globalShortcut). Changes re-register immediately; no app restart needed."
                         ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                settingsCard(
                    title: preferences.tr("Deep 觸發門檻", "Deep Trigger Thresholds"),
                    subtitle: preferences.tr(
                        "只影響 Deep / Long Note，不會讓普通短句走大型模型。",
                        "Affects Deep / Long Note only; ordinary short phrases never go to large models."
                    ),
                    icon: "ruler"
                ) {
                    thresholdField(preferences.tr("最少字數", "Min characters"), value: $preferences.deepMinCharacters, suffix: preferences.tr("字", "chars"))
                    thresholdField(preferences.tr("最少音訊", "Min audio"), value: $preferences.deepMinAudioSeconds, suffix: preferences.tr("秒", "sec"))
                }

                settingsCard(
                    title: preferences.tr("系統權限與最近結果", "Permissions & Last Result"),
                    subtitle: preferences.tr(
                        "Edit Selection 只讀取目前輸入欄位需要的最少選取文字與 App context。",
                        "Edit Selection reads only the minimal selected text and app context the current field needs."
                    ),
                    icon: "lock.shield"
                ) {
                    HStack(spacing: 10) {
                        Button(preferences.tr("要求輔助使用權限", "Request Accessibility")) { model.requestAccessibility() }
                        Button(preferences.tr("複製最後結果", "Copy Last Result")) { model.copyLastOutput() }
                            .disabled(model.lastOutput.isEmpty)
                    }
                    Text(model.statusMessage)
                        .font(.callout)
                        .textSelection(.enabled)
                    if !model.lastOutput.isEmpty {
                        Text(model.lastOutput)
                            .font(.callout)
                            .lineLimit(5)
                            .textSelection(.enabled)
                            .padding(.top, 2)
                    }
                }
            }
            .padding(24)
        }
        .scrollIndicators(.hidden)
    }

    /// 百鍊 API key 輸入（D8-1）：直接寫 Keychain，取代「只能開終端機」。
    /// 已存的 key 永不回顯——欄位只用來輸入新值，狀態列只講有沒有。
    private var apiKeyCard: some View {
        settingsCard(
            title: preferences.tr("百鍊 API key", "Bailian API key"),
            subtitle: preferences.tr(
                "存進本機 Keychain（service com.utuvo.type.bailian）。留空＝完全不連雲端。",
                "Stored in the local Keychain (service com.utuvo.type.bailian). Leave empty for fully local use."
            ),
            icon: "key.fill"
        ) {
            let fromEnvironment = SecretStore.keyComesFromEnvironment()
            let hasKeychainKey = { _ = apiKeyStateToken; return SecretStore.hasKeychainKey() }()

            HStack(spacing: 8) {
                SecureField(
                    preferences.tr("貼上新的 API key", "Paste a new API key"),
                    text: $apiKeyDraft
                )
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)

                Button(preferences.tr("儲存", "Save")) {
                    let error = SecretStore.saveBailianAPIKey(apiKeyDraft)
                    apiKeyMessageIsError = error != nil
                    apiKeyMessage = error ?? preferences.tr("已寫入 Keychain。", "Saved to the Keychain.")
                    if error == nil { apiKeyDraft = "" }
                    apiKeyStateToken = UUID()
                }
                .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button(preferences.tr("清除", "Remove")) {
                    let error = SecretStore.deleteBailianAPIKey()
                    apiKeyMessageIsError = error != nil
                    apiKeyMessage = error ?? preferences.tr("已從 Keychain 刪除。", "Removed from the Keychain.")
                    apiKeyDraft = ""
                    apiKeyStateToken = UUID()
                }
                .disabled(!hasKeychainKey)
            }

            HStack(spacing: 6) {
                Image(systemName: hasKeychainKey ? "checkmark.seal.fill" : "circle.dashed")
                    .foregroundStyle(hasKeychainKey ? AppBrand.retroGreen : Color.secondary)
                Text(hasKeychainKey
                     ? preferences.tr("Keychain 已有一把 key（不顯示內容）。", "The Keychain holds a key (never displayed).")
                     : preferences.tr("Keychain 目前沒有 key；本機模式照常可用。", "No key in the Keychain; local mode still works."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if fromEnvironment {
                Label(
                    preferences.tr(
                        "偵測到環境變數 key，它的優先權高於 Keychain——這裡存的 key 不會生效。",
                        "An environment-variable key was detected; it overrides the Keychain, so a key saved here will not take effect."
                    ),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            if let apiKeyMessage {
                Text(apiKeyMessage)
                    .font(.caption)
                    .foregroundStyle(apiKeyMessageIsError ? Color.red : .secondary)
            }

            Divider().padding(.vertical, 2)

            HStack(spacing: 8) {
                Button(preferences.tr("測試雲端連線", "Test cloud connection")) {
                    probeCloud()
                }
                .disabled(isProbingCloud)
                if isProbingCloud {
                    ProgressView().controlSize(.small)
                }
            }
            Text(preferences.tr(
                "用目前的 key 與 formatter 端點實際送一句話，照 fallback 鏈逐個試模型；不會改任何設定。",
                "Sends one real sentence with the current key and formatter endpoint, walking the fallback chain; changes no settings."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if let cloudProbeResult {
                Text(cloudProbeResult)
                    .font(.caption)
                    .foregroundStyle(cloudProbeIsError ? Color.red : AppBrand.retroGreen)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 照 `BailianModel.standardFallbackChain` 逐個試，回報第一個成功的模型與耗時。
    /// 失敗訊息只帶 HTTP 狀態，不帶 response body（body 可能含請求 metadata）。
    private func probeCloud() {
        isProbingCloud = true
        cloudProbeResult = nil
        let endpoint = preferences.bailianFormatterEndpoint
        let zh = preferences.isChineseUI
        Task { @MainActor in
            defer { isProbingCloud = false }
            guard SecretStore.bailianAPIKey() != nil else {
                cloudProbeIsError = true
                cloudProbeResult = zh
                    ? "找不到 key：Keychain 與環境變數都沒有。"
                    : "No key found in the Keychain or the environment."
                return
            }
            let client: BailianFormatterClient
            do {
                client = try BailianFormatterClient(endpointString: endpoint)
            } catch {
                cloudProbeIsError = true
                cloudProbeResult = zh ? "端點網址無效（必須是 https）。" : "Invalid endpoint (https required)."
                return
            }
            let probePrompt = zh
                ? "把下面這句整理成乾淨的繁體中文，只輸出結果：嗯那個等一下三點開會不對是四點"
                : "Clean up this sentence and output only the result: uh the meeting is at three no wait four"
            var attempts: [String] = []
            for model in BailianModel.standardFallbackChain {
                let started = Date()
                do {
                    let text = try await client.format(prompt: probePrompt, model: model.rawValue)
                    let ms = Int(Date().timeIntervalSince(started) * 1000)
                    attempts.append("✅ \(model.rawValue) \(ms)ms")
                    cloudProbeIsError = false
                    cloudProbeResult = attempts.joined(separator: "\n")
                        + (zh ? "\n輸出：" : "\nOutput: ")
                        + text.trimmingCharacters(in: .whitespacesAndNewlines)
                    return
                } catch {
                    attempts.append("❌ \(model.rawValue) — \(error.localizedDescription)")
                }
            }
            cloudProbeIsError = true
            cloudProbeResult = attempts.joined(separator: "\n")
                + (zh ? "\n整條 fallback 鏈都失敗。" : "\nEvery model in the fallback chain failed.")
        }
    }

    private var cloudTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                settingsCard(
                    title: preferences.tr("百鍊 adapter（選配）", "Bailian adapter (optional)"),
                    subtitle: preferences.tr(
                        "目前不需要登入或 API key 也能使用本機 Fast；雲端只在你手動切換後端時使用。",
                        "No login or API key is needed for local Fast; the cloud is used only when you switch backends manually."
                    ),
                    icon: "cloud"
                ) {
                    labeledField(preferences.tr("ASR WebSocket endpoint", "ASR WebSocket endpoint"), text: $preferences.bailianASREndpoint)
                    labeledField(preferences.tr("Formatter endpoint", "Formatter endpoint"), text: $preferences.bailianFormatterEndpoint)
                    labeledField(preferences.tr("Workspace ID（可留空）", "Workspace ID (optional)"), text: $preferences.bailianWorkspaceID)

                    // 2026-09-11 實測：訂閱制（Token Plan）的 key 打不通 dashscope.aliyuncs.com
                    // （401），要用 token-plan 自己的網域。一鍵切換免得使用者自己拼網址。
                    HStack(spacing: 8) {
                        Button(preferences.tr("填入訂閱制（Token Plan）端點", "Use subscription (Token Plan) endpoints")) {
                            preferences.bailianASREndpoint = BailianEndpointPreset.tokenPlan.asr
                            preferences.bailianFormatterEndpoint = BailianEndpointPreset.tokenPlan.formatter
                        }
                        Button(preferences.tr("填回按量付費端點", "Use pay-as-you-go endpoints")) {
                            preferences.bailianASREndpoint = BailianEndpointPreset.payAsYouGo.asr
                            preferences.bailianFormatterEndpoint = BailianEndpointPreset.payAsYouGo.formatter
                        }
                    }
                    Text(preferences.tr(
                        "百鍊有兩種帳號：按量付費用 dashscope.aliyuncs.com；訂閱制（Agent／Token Plan）用 token-plan.cn-beijing.maas.aliyuncs.com。拿訂閱制的 key 去打 dashscope 會 401——不是 key 壞掉，是網域不對。",
                        "Bailian has two account types: pay-as-you-go uses dashscope.aliyuncs.com, while subscriptions (Agent/Token Plan) use token-plan.cn-beijing.maas.aliyuncs.com. A subscription key sent to dashscope returns 401 — the key is fine, the host is wrong."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    Text(SecretStore.keychainInstructions)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                apiKeyCard

                settingsCard(
                    title: preferences.tr("安全與 fallback", "Security & fallback"),
                    subtitle: preferences.tr(
                        "API key 不會出現在設定欄位、repo、log 或貼上結果。",
                        "The API key never appears in settings fields, the repo, logs or pasted output."
                    ),
                    icon: "checkmark.shield"
                ) {
                    Label(
                        preferences.tr(
                            "雲端 timeout 或模型不可用時，保留原始 transcript。",
                            "On cloud timeout or model unavailability, the raw transcript is kept."
                        ),
                        systemImage: "arrow.uturn.backward.circle"
                    )
                    Label(
                        preferences.tr(
                            "先套用 deterministic normalizer，再貼出可用結果。",
                            "The deterministic normalizer runs first, then a usable result is pasted."
                        ),
                        systemImage: "bolt.circle"
                    )
                    Label(
                        preferences.tr(
                            "qwen3.7-max 不進入普通聽寫流程。",
                            "qwen3.7-max never enters the ordinary dictation flow."
                        ),
                        systemImage: "nosign"
                    )
                }
            }
            .padding(24)
        }
        .scrollIndicators(.hidden)
    }

    /// 裝置清單只在視窗建立與按「重新整理」時查一次（`.id(deviceRefreshToken)` 會重建 view＝重查）。
    /// 之前是 computed property 每次讀都打 CoreAudio HAL，而 FixedWidthPopUp 替每個選項呼叫一次 name closure，
    /// 一般分頁開啟量到約 0.9 s 全在這裡（09-17 sample）。
    @State private var inputDevicesCache: [AudioDeviceOption] = AudioDeviceCatalog.inputDevices()
    @State private var outputDevicesCache: [AudioDeviceOption] = AudioDeviceCatalog.outputDevices()

    private var inputDevices: [AudioDeviceOption] { inputDevicesCache }
    private var outputDevices: [AudioDeviceOption] { outputDevicesCache }

    private var selectedInputChannelCount: Int {
        let devices = inputDevices
        if let selected = devices.first(where: { $0.id == preferences.inputDeviceUID }) {
            return selected.channelCount
        }
        return devices.first(where: { $0.isDefault })?.channelCount ?? 1
    }

    private var inputChannels: [AudioInputChannel] {
        AudioInputChannel.available(for: max(1, selectedInputChannelCount))
    }

    private var dictionaryEntries: [(source: String, output: String)] {
        preferences.dictionary
            .map { (source: $0.key, output: $0.value) }
            .sorted { $0.source.localizedCaseInsensitiveCompare($1.source) == .orderedAscending }
    }

    /// 所有「標籤＋控制項」列共用的控制欄寬度：右緣切齊同一條線。
    private let controlColumnWidth: CGFloat = 240

    /// 標籤靠左、控制項填滿右側固定寬欄、可選說明小字在標籤下方。
    private func settingsRow<Control: View>(
        _ label: String,
        caption: String? = nil,
        @ViewBuilder control: () -> Control
    ) -> some View {
        // Recorder／Toggle／Slider 沒有文字基線，用垂直置中避免標籤貼到控制項底邊。
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.callout)
                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control()
                .frame(width: controlColumnWidth, alignment: .trailing)
        }
        .frame(minHeight: 36)
    }

    private func settingsPickerRow<Option: Hashable>(
        _ title: String,
        selection: Binding<Option>,
        options: [Option],
        name: @escaping (Option) -> String
    ) -> some View {
        settingsRow(title) {
            FixedWidthPopUp(selection: selection, options: options, name: name, width: controlColumnWidth)
                .frame(width: controlColumnWidth, height: 26)
        }
    }

    /// settingsRow 右欄用的膠囊狀態標籤。
    private func statusCapsule(_ value: String, color: Color) -> some View {
        Text(value)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }

    private func addDictionaryTerm() {
        preferences.addDictionaryTerm(source: dictionaryWord, output: dictionaryOutput)
        dictionaryWord = ""
        dictionaryOutput = ""
    }

    private func addPreset() {
        let bundleID = presetBundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleID.isEmpty else { return }
        preferences.saveAppPreset(AppPreset(
            bundleIdentifier: bundleID,
            displayName: presetDisplayName.trimmingCharacters(in: .whitespacesAndNewlines),
            promptHint: presetPromptHint.trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        presetBundleIdentifier = ""
        presetDisplayName = ""
        presetPromptHint = ""
    }

    private func choosePromptFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        preferences.formatterPromptPath = url.path
    }

    private func dictionaryChip(_ entry: (source: String, output: String)) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.source)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                if entry.output != entry.source {
                    Text("→ \(entry.output)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Button {
                preferences.removeDictionaryTerm(source: entry.source)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(preferences.tr("移除 \(entry.source)", "Remove \(entry.source)"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppBrand.accent.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(AppBrand.accent.opacity(0.18))
        )
    }

    private func settingsModeTile(
        _ mode: FormatterMode,
        title: String,
        subtitle: String,
        icon: String
    ) -> some View {
        let selected = preferences.mode == mode
        return Button {
            preferences.mode = mode
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(selected ? AppBrand.accent : .secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? AppBrand.accent : Color.secondary.opacity(0.5))
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
            .popoverTile(selected: selected, cornerRadius: 12)
        }
        .buttonStyle(.plain)
    }

    private func labeledField(_ label: String, text: Binding<String>) -> some View {
        settingsRow(label) {
            // 列標籤已顯示同一字串，空欄位內不再重複 placeholder。
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)
        }
    }

    private func thresholdField(_ label: String, value: Binding<Int>, suffix: String) -> some View {
        settingsRow(label) {
            HStack(spacing: 6) {
                TextField("0", value: value, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                Text(suffix)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func settingsCard<Content: View>(
        title: String,
        subtitle: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppBrand.accent)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, 5)
            content()
        }
        .padding(18)
        .popoverCard(cornerRadius: 16)
    }
}

private extension FormatterMode {
    var shortName: String {
        switch self {
        case .fast: return "Fast Dictate"
        case .smart: return "Smart Dictate"
        case .editSelection: return "Edit Selection"
        case .deep: return "Deep / Long Note"
        }
    }
}

/// 等寬原生下拉：系統 .menu Picker 不吃 frame 寬度，改包 NSPopUpButton 並用 Auto Layout 鎖寬。
struct FixedWidthPopUp<Option: Hashable>: NSViewRepresentable {
    @Binding var selection: Option
    let options: [Option]
    let name: (Option) -> String
    var width: CGFloat = 280

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: width).isActive = true
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionChanged(_:))
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        let titles = options.map(name)
        // 逐項建 NSMenuItem：addItems(withTitles:) 會合併重複標題，造成索引與 options 錯位。
        if button.numberOfItems != titles.count || button.itemTitles != titles {
            button.removeAllItems()
            for (index, title) in titles.enumerated() {
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.tag = index
                button.menu?.addItem(item)
            }
        }
        if let index = options.firstIndex(of: selection), button.indexOfSelectedItem != index {
            button.selectItem(at: index)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor final class Coordinator: NSObject {
        var parent: FixedWidthPopUp
        init(_ parent: FixedWidthPopUp) { self.parent = parent }

        @objc func selectionChanged(_ button: NSPopUpButton) {
            // 用 item tag 對回 options 索引，不依賴 indexOfSelectedItem（重複標題時仍正確）。
            guard let item = button.selectedItem else { return }
            let index = item.tag
            guard parent.options.indices.contains(index) else { return }
            parent.selection = parent.options[index]
        }
    }
}

@preconcurrency import AVFoundation
@preconcurrency import Speech
import AppKit
import Combine
import Foundation
import OSLog
import UTUVOTypeCore

@MainActor
final class AppModel: ObservableObject {
    private let logger = Logger(subsystem: "com.utuvo.type", category: "permissions")
    /// 投遞／整理結果（`log show --predicate 'subsystem == "com.utuvo.type"'` 查得到；不含逐字稿內容）。
    private let deliveryLog = Logger(subsystem: "com.utuvo.type", category: "delivery")
    @Published private(set) var isRecording = false
    @Published private(set) var isProcessing = false {
        didSet {
            // 上一句還在轉錄時按的「開始」先記著，貼出（isProcessing 變 false）就立刻開錄。
            guard oldValue, !isProcessing, let pending = pendingStart else { return }
            pendingStart = nil
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isRecording, !self.isProcessing else { return }
                self.activeTranslationTarget = pending
                self.startRecording(mode: self.preferences.mode)
            }
        }
    }
    /// 2026-10-19 Typeless 對打：上一句還在轉錄時按熱鍵會被 `guard !isProcessing` 靜默吃掉，
    /// 連續講話時下一句就沒錄到（Typeless 不會）。改成排隊：處理完自動開始，期間再按一次＝取消排隊。
    private(set) var pendingStart: TranslationTarget?
    #if DEBUG
    /// 測試用：模擬「上一句還在轉錄」。
    func setProcessingForTesting(_ value: Bool) { isProcessing = value }
    #endif
    @Published private(set) var statusMessage = "準備就緒"
    @Published private(set) var partialTranscript = ""
    @Published private(set) var lastRawTranscript = ""
    @Published private(set) var lastOutput = ""
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var needsPermissionSetup = false
    @Published private(set) var microphonePermissionReady = false
    @Published private(set) var accessibilityPermissionReady = false
    @Published private(set) var currentAppName = "未偵測"
    @Published private(set) var currentBundleIdentifier = ""
    @Published private(set) var playingHistoryID: UUID?

    let preferences: AppPreferences
    var onStateChange: (() -> Void)?

    private var capture: AudioCaptureSession?
    private let feedbackTonePlayer = FeedbackTonePlayer()
    private var cloudASRTask: Task<String, Error>?
    /// 錄音中收齊 16 kHz PCM（本機 Qwen／Groq 雲端辨識都用）：停頓時先辨識，Groq 模式停下來整段送。
    private var pcmTask: Task<Data, Never>?
    private var pcmEngineIsGroq = false
    /// 出字時間拆解（停止 → 錄音收尾 → 辨識 → 整理 → 送達），寫 delivery log。
    private var stopPressedAt: Date?
    /// 停頓預先處理（Groq 模式）：講完一段停下來時先辨識、先整理；按停止時錄音沒有新聲音就直接沿用。
    private struct Speculation {
        let token: UUID
        let pcmBytes: Int
        let asr: Task<String?, Never>
        var cleanup: (raw: String, config: CleanupConfig, task: Task<String?, Never>)?
    }
    private var speculation: Speculation?
    private var activeMode: FormatterMode = .fast
    private var selectedContext: LimitedAppContext?
    private var operationToken = UUID()
    private var pushToTalkActive = false
    // 即時翻譯：由按下的修飾鍵變體決定，停止那一下按的變體優先。
    private var activeTranslationTarget: TranslationTarget = .off
    // PTT 放開事件被忽略（主鍵仍壓著）後的看門狗：若使用者放開主鍵時按著一顆
    // 沒註冊變體的修飾鍵（例如 ⌥），Carbon 不會再送任何事件，沒有它錄音會永遠不停。
    private var pttKeyWatchdog: Task<Void, Never>?
    private var historyAudioPlayer: NSSound?
    private var unloadTask: Task<Void, Never>?
    private var inputChangedDuringRecording = false
    private var permissionOnboardingInFlight = false
    // 背景智慧整理（SmartCleanup）：先送 deterministic 出去、捕捉 AXInsertionTicket；
    // cleanup 完成後用 AXReplacementGate 確認「同一欄位、同一內容、同一前綴」才覆寫。
    private var pendingCleanupTask: Task<Void, Never>?
    private var destination: (any DictationDestination)?
    private var capturedPID: Int32?
    /// Ask anything（2026-10-13）：這次錄音是問問題／對選取文字下指令，不是聽寫。
    private var askActive = false
    private var askSelection: String?
    private var askPID: Int32?
    /// 問問題當下的焦點欄位：回答要貼回去時必須還是同一個欄位（luna-review r2：同 App 換欄位會貼錯地方）。
    private var askElement: AXUIElement?
    /// 問問題當下的選取範圍／游標位置；貼回去前要一模一樣（luna-review r3：同欄位改選別段或移動游標會貼錯位置）。
    private var askRange: CFRange?
    /// 問問題當下的欄位能不能編輯（modes-4）：網頁、PDF、郵件閱讀窗格、唯讀文字框不能 replace，
    /// 否則 ⌘V 貼進空氣還回報「已改寫」。只看 AXValue／AXSelectedText 可不可寫——
    /// 唯讀 NSTextView 照樣可以設選取範圍，所以不看 AXSelectedTextRange。
    private var askEditable = false
    /// Ask anything 開始時選取被擋的原因（context-awareness-v2）；回答後附在狀態上。
    private var askBlockNote: String?
    /// 開始聽寫當下的 App 脈絡（context-awareness-v1）：跟投遞目的地同一刻抓，token 對得上才用。
    /// 以前 ASR 結束後才讀「當下 focus 的欄位」，講話中換了分頁／欄位，脈絡就是別的地方的。
    private var capturedContext: (token: UUID, context: LimitedAppContext)?
    /// 歷史重試剛更新的那一筆（設定頁那一列顯示「已更新，已複製」）。
    @Published private(set) var retriedHistoryID: UUID?
    /// 隔離模式（測試）不碰系統剪貼簿：寫到這裡。
    private(set) var isolatedClipboard: String?
    /// 歷史重試的工作（測試等它跑完）。
    private var historyRetryTask: Task<Void, Never>?
    /// 重新辨識存下來的錄音（delivery-learning-1）：nil＝正式路徑（Groq → 本機 Qwen，跟停止錄音後同一套）。
    /// 測試注入假的；隔離模式沒注入就一律失敗（不碰 Keychain、不連網）。
    var recordingTranscriber: ((URL) async -> (text: String?, failure: String?))?
    /// 快到錄音上限／很久沒聲音快要停時的倒數提示（capture-latency-v3）；nil＝沒有。
    /// 選單、狀態列圖示的提示文字、錄音球的輔助說明都顯示這一句（repair-batch1：選單關著也看得到）。
    @Published private(set) var recordingLimitNotice: String?
    private var recordingLimitTask: Task<Void, Never>?
    /// 目前這一輪倒數是哪一種；錄音球依它換成「快停了」的樣子（`OverlayWindowController.showsLimitWarning`）。
    /// repair round 2：倒數**不出聲**——麥克風開著，提示音會被錄進去（還會被當成「有聲音」把安靜倒數取消掉），
    /// 開了「錄音時靜音」也聽不到。只用看得到的：錄音球、球的輔助說明、狀態列圖示的提示文字、選單。
    @Published private(set) var recordingLimitCountdown: RecordingLimits.StopReason?
    /// 很久沒聲音而自動停下來的那一次（operationToken）：結束後不按送出鍵（repair-batch1）。
    private var autoSubmitSuppressedToken: UUID?

    /// 這次聽寫結束後要不要按送出鍵。很久沒聲音而自動停下來的那一次一律不送——使用者可能根本不在電腦前，
    /// 文字照樣貼上、留在歷史，等他看過再自己送出（repair-batch1）。其他情況照設定。
    var effectiveAutoSubmit: AutoSubmit {
        autoSubmitSuppressedToken == operationToken ? .off : preferences.autoSubmit
    }
    /// 隔離模式（測試）不貼：本來要貼的完整內容（含接續前綴與結尾空白）記在這裡。
    private(set) var isolatedPastePayload: String?

    /// context-awareness-2：上一段送到哪個 App、哪個欄位、送了什麼（不含補的前綴與結尾空白）。
    /// 放在獨立的 box：production 的 capture closure 不抓 self，也要知道游標前該讀多長。
    @MainActor final class ContinuationMemory {
        var pid: Int32?
        var text: String?
        /// 上一段被 `SentenceMood.finish` 拿掉的句尾標點（「，」「、」原樣補回；「。」不補）。
        var droppedMark: String?
        /// 上一段送進的欄位（`DictationDestination.fieldIdentity`）；nil＝不知道＝下一段不接續。
        var field: AnyHashable?
        /// 上一段送完後游標應該在的位置（UTF-16）；nil＝不知道（只比欄位）。
        var end: Int?

        /// 開始聽寫時游標前要讀多長：上一段送進同一個 App 才放寬到「上一段＋8」，其他 App 一律 32
        /// （審查 10-22：以前不看 App，送過 4000 字之後，到別的 App——包括封鎖網站——也讀 4096）。
        /// 同一個 App 裡還要是同一個欄位，那一層在 `AXAdapter.effectiveBeforeWindow`。
        func beforeWindow(expectedPID: Int32?) -> Int {
            guard let pid, pid == expectedPID else { return AXAdapter.minimumBeforeWindow }
            return AXAdapter.beforeWindow(previous: text)
        }

        /// 這一段要不要接續上一段：同一個 App、同一個欄位，游標也正好停在上一段送完的地方（兩邊都知道位置時）。
        /// 審查 10-22：以前只比 App，同一個 App 的另一則筆記游標前剛好也是「好」，就被補了「。」。
        func previous(pid capturedPID: Int32?, at destination: (any DictationDestination)?) -> (text: String, mark: String?)? {
            guard let text, pid == capturedPID,
                  let field, let destination, destination.fieldIdentity == field else { return nil }
            if let end, let location = destination.cursorLocation, location != end { return nil }
            return (text, droppedMark)
        }

        func remember(pid: Int32?, text: String, droppedMark: String, at destination: (any DictationDestination)?,
                      payload: String) {
            self.pid = pid
            self.text = text
            self.droppedMark = droppedMark
            field = destination?.fieldIdentity
            end = field == nil ? nil : destination?.cursorLocation.map { $0 + payload.utf16.count }
        }

        func forget() {
            pid = nil; text = nil; droppedMark = nil; field = nil; end = nil
        }
    }
    private let continuation: ContinuationMemory

    /// modes-v1：Edit Selection 開始時的選取。改好的文字貼回去前，要還是同一個 App、同一個欄位、同一段選取，
    /// 欄位也要能編輯；否則不貼（貼了會蓋掉別的地方，或貼進空氣還回報「已改寫」），結果放卡片。
    struct SelectionAnchor {
        let text: String
        let pid: Int32?
        let element: AXUIElement?
        let range: CFRange?
        let editable: Bool
    }
    private var editAnchor: SelectionAnchor?
    /// 測試注入：改選取貼回去前「選取還在不在」。nil＝讀 AX（`stillAtField`）。
    var selectionStillThere: ((SelectionAnchor) -> Bool)?
    #if DEBUG
    /// 測試用：模擬 Edit Selection 開始時讀到的選取（隔離模式不會跑 beginRecording）。
    func setEditSelectionForTesting(_ text: String, editable: Bool = true) {
        editAnchor = SelectionAnchor(text: text, pid: nil, element: nil, range: nil, editable: editable)
    }
    #endif

    /// 同一個 App、同一個欄位、同一個選取範圍（還有同一段選取文字）——Ask anything 與 Edit Selection 共用。
    static func stillAtField(pid: Int32?, element: AXUIElement?, range: CFRange?, expectSelection: String? = nil) -> Bool {
        guard let pid, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
        guard let element, let range else { return false }
        guard let now = AccessibilitySupport.focusedElement(), CFEqual(now, element),
              let current = AccessibilitySupport.selectedRange(of: now),
              current.location == range.location, current.length == range.length else { return false }
        if let expectSelection {
            let text = AccessibilitySupport.selectedText(of: now)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return text == expectSelection
        }
        return true
    }

    /// 欄位能不能直接改（modes-4）：只看 AXValue／AXSelectedText 可不可寫——唯讀 NSTextView 照樣可以設選取範圍。
    static func isEditable(_ element: AXUIElement) -> Bool {
        AXAdapter.settable(element, kAXValueAttribute) || AXAdapter.settable(element, kAXSelectedTextAttribute)
    }

    private func stillAtAskField(expectSelection: String? = nil) -> Bool {
        Self.stillAtField(pid: askPID, element: askElement, range: askRange, expectSelection: expectSelection)
    }
    /// 插入後追蹤修改 → 字典建議（2026-10-13）。
    let editWatcher = EditWatcher()

    private func watchEdits(_ inserted: String) {
        guard preferences.learnFromEdits, preferences.isolation == nil else { return }
        // 過得了讀音／拼法關的自動加進字典、其他留建議；學到什麼都跳一個不搶焦點的小提示（delivery-learning-4）。
        editWatcher.onSuggestions = { [weak self] found in
            guard let self else { return }
            LearnedWordToast.shared.present(self.preferences.learn(fromEdits: found), preferences: self.preferences)
        }
        editWatcher.watch(inserted: inserted)
    }
    var captureDestination: (Int32?) -> (any DictationDestination)?
    /// 開始聽寫當下抓 App 脈絡（context-awareness-v1）；測試注入，隔離模式回空。
    var captureContext: (_ includeSurrounding: Bool, _ blockedSites: [String]) -> LimitedAppContext
    var cleanupRunner: @Sendable (String, CleanupConfig) async -> String?
    /// 整理服務的 key（測試注入；隔離模式一律空，不碰 Keychain）。
    var cleanupKeyLookup: (SmartCleanup.Provider) -> String
    /// 語音翻譯的雲端那一步：(system, 文字, 服務) → 譯文（modes-1）。測試注入；production 走 SmartCleanup.ask。
    var cloudTranslationRunner: @Sendable (_ system: String, _ text: String,
                                           _ route: DictationTranslation.CloudRoute) async throws -> String
    /// Edit Selection 的雲端那一步：(system, user, 服務) → 改好的文字（modes-v1）。測試注入；production 走 SmartCleanup.ask。
    var cloudEditRunner: @Sendable (_ system: String, _ user: String,
                                    _ route: DictationTranslation.CloudRoute) async throws -> String
    /// 語音翻譯的系統翻譯：(文字, 辨識語言, 目標語言代碼) → 譯文。測試注入；隔離模式回 nil。
    var systemTranslationRunner: (_ text: String, _ sourceRaw: String, _ targetCode: String) async -> String?
    /// 語音翻譯的本機 editor：nil＝跑設定的 command（測試注入假的）。
    var localEditorTranslationRunner: ((_ text: String, _ target: TranslationTarget) async -> String?)?
    /// Isolated tests can verify local Smart output is inserted before its slower formatter completes.
    var localBackgroundRunner: (@Sendable (String, LimitedAppContext, [String: String]) async -> String?)?
    // Isolated fixtures can exercise the actual one-shot branch without starting a provider.
    var legacyFormatterRunner: ((String) async throws -> String)?
    var onDeliveryEvent: ((String) -> Void)?
    private let legacyFirstUsePermissionKey = "utuvo.type.firstUsePermissionPrompted"
    private let permissionOnboardingAttemptedKey = "utuvo.type.permissionOnboardingAttempted"
    private let permissionOnboardingCompletedKey = "utuvo.type.permissionOnboardingCompleted"

    init(preferences: AppPreferences = AppPreferences()) {
        self.preferences = preferences
        let memory = ContinuationMemory()
        self.continuation = memory
        if preferences.isolation != nil {
            captureDestination = { _ in nil }
            captureContext = { _, _ in LimitedAppContext() }
            cleanupRunner = { _, _ in nil }
            cleanupKeyLookup = { _ in "" }
            cloudTranslationRunner = { _, _, _ in throw URLError(.notConnectedToInternet) }
            cloudEditRunner = { _, _, _ in throw URLError(.notConnectedToInternet) }
            systemTranslationRunner = { _, _, _ in nil }
            legacyFormatterRunner = { _ in throw URLError(.notConnectedToInternet) }
        } else {
            // context-awareness-2：游標前讀「上一段＋8」那麼長，才比得出游標前就是上一段的結尾——
            // 只限上一段送進的那個 App 的那個欄位；其他地方照舊只讀 32。
            captureDestination = {
                AXAdapter.shared.capture(expectedPID: $0, beforeUTF16: memory.beforeWindow(expectedPID: $0),
                                         previousField: memory.field)
            }
            captureContext = { AccessibilitySupport.readCurrentContext(includeSurrounding: $0, blockedSites: $1) }
            cleanupRunner = { text, config in await SmartCleanup.clean(text, config: config) }
            cleanupKeyLookup = { SmartCleanup.key(for: $0) }
            let ask: @Sendable (String, String, DictationTranslation.CloudRoute) async throws -> String = { system, text, route in
                try await SmartCleanup.ask(system: system, user: text, provider: route.provider, key: route.key,
                                           customEndpoint: route.customEndpoint, customModel: route.customModel,
                                           transport: StrictCleanupSession.shared)
            }
            cloudTranslationRunner = ask
            cloudEditRunner = ask
            systemTranslationRunner = { text, source, target in
                await SystemTranslator.shared.translate(text, sourceRaw: source, targetCode: target)
            }
        }
        statusMessage = preferences.tr("準備就緒", "Ready")
        refreshPermissionState()
    }

    /// Display-only scalar; polling does not publish changes or alter recording.
    func liveVoiceLevel() -> Float? { isRecording ? capture?.currentVoiceLevel : nil }

    /// modes-v2：錄音圓球下方的標籤（翻譯目標／Ask anything／Edit Selection）；一般聽寫是 nil。
    var overlayBadge: String? {
        OverlayBadge.text(translation: activeTranslationTarget, ask: askActive,
                          editSelection: activeMode == .editSelection, zh: preferences.isChineseUI)
    }

    var modeDisplayName: String {
        switch activeMode {
        case .fast: return "Fast Dictate"
        case .smart: return "Smart Dictate"
        case .editSelection: return "Edit Selection"
        case .deep: return "Deep / Long Note"
        }
    }

    func toggleRecording() {
        if isRecording {
            pushToTalkActive = false
            stopRecording()
        } else {
            pushToTalkActive = preferences.pushToTalkEnabled
            startRecording(mode: preferences.mode)
        }
    }

    /// menu bar 按鈕走這裡：一律原文輸出。
    func toggleRecordingFromUI() {
        activeTranslationTarget = .off
        toggleRecording()
    }

    func shortcutPressed(translation: TranslationTarget = .off) {
        if !isRecording && !isProcessing { askActive = false; askSelection = nil }   // 一般聽寫開始：清掉殘留的 Ask
        if preferences.pushToTalkEnabled {
            guard !isProcessing else { return }
            if isRecording {
                // PTT 按住期間補按／放開修飾鍵：Carbon 會送「舊組合 released＋新組合 pressed」。
                // 這裡只改翻譯目標，不開新錄音——規則與 toggle 一致：放開主鍵那一刻按著什麼就翻成什麼。
                // 錄音是 toggle 起的（pushToTalkActive=false）也走這裡，絕不重入 beginRecording（F2）。
                pushToTalkActive = true
                activeTranslationTarget = translation
                logger.info("ptt retarget -> \(translation.rawValue, privacy: .public)")
                notify()   // modes-v2：圓球下方的翻譯標籤要跟著換
                return
            }
            pushToTalkActive = true
            activeTranslationTarget = translation
            startRecording(mode: preferences.mode)
        } else {
            // toggle：停止那一下按的修飾鍵決定翻譯語言（先講後選語言）；
            // 處理中按變體不改目標（F6）。
            if isProcessing {
                if pendingStart != nil {
                    pendingStart = nil
                    statusMessage = preferences.tr("已取消排隊的錄音", "Queued recording cancelled")
                } else {
                    pendingStart = translation
                    statusMessage = preferences.tr("上一句處理完就開始錄…", "Recording starts as soon as the last one is done…")
                }
                notify()
                return
            }
            activeTranslationTarget = translation
            toggleRecording()
        }
    }

    /// - Parameter mainKeyStillDown: 主鍵（非修飾鍵）此刻是否仍被壓著；
    ///   仍壓著＝只是修飾鍵變了（Carbon 會送 released），不是真的放開，忽略。
    func shortcutReleased(mainKeyStillDown: Bool = false, mainKeyCode: UInt32? = nil) {
        guard preferences.pushToTalkEnabled else { return }
        logger.info("ptt release mainKeyDown=\(mainKeyStillDown, privacy: .public) recording=\(self.isRecording, privacy: .public) active=\(self.pushToTalkActive, privacy: .public)")
        if mainKeyStillDown, isRecording, pushToTalkActive {
            logger.info("ptt release ignored (main key still down)")
            startPTTKeyWatchdog(keyCode: mainKeyCode)
            return
        }
        pttKeyWatchdog?.cancel()
        pttKeyWatchdog = nil
        pushToTalkActive = false
        if isRecording {
            stopRecording()
        }
    }

    /// 每 50ms 查一次主鍵硬體狀態，放開就補送真正的 release（F1）；上限 120s 防呆。
    private func startPTTKeyWatchdog(keyCode: UInt32?) {
        guard let keyCode else { return }
        pttKeyWatchdog?.cancel()
        pttKeyWatchdog = Task { [weak self] in
            for _ in 0..<2_400 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                if Task.isCancelled { return }
                if !CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(keyCode)) {
                    await MainActor.run {
                        guard let self, self.isRecording, self.pushToTalkActive else { return }
                        self.logger.info("ptt watchdog: main key up without Carbon release -> stop")
                        self.pttKeyWatchdog = nil
                        self.shortcutReleased(mainKeyStillDown: false)
                    }
                    return
                }
            }
        }
    }

    func ensureFirstUsePermissions() async {
        guard preferences.isolation == nil else { return }
        guard !permissionOnboardingInFlight else { return }
        permissionOnboardingInFlight = true
        defer { permissionOnboardingInFlight = false }

        refreshPermissionState()
        if !needsPermissionSetup {
            UserDefaults.standard.set(true, forKey: permissionOnboardingCompletedKey)
            statusMessage = preferences.tr("系統權限已就緒", "System permissions are ready")
            notify()
            return
        }

        // The old key meant "the prompt was shown". Treat it as an attempted
        // onboarding flow, not as permission completion, so an upgraded app
        // cannot reopen the native prompt on every menu-bar click.
        let alreadyAttempted = UserDefaults.standard.bool(forKey: permissionOnboardingAttemptedKey)
            || UserDefaults.standard.bool(forKey: legacyFirstUsePermissionKey)
        guard !alreadyAttempted else {
            updatePermissionStatus()
            notify()
            return
        }
        UserDefaults.standard.set(true, forKey: permissionOnboardingAttemptedKey)

        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await PermissionGate.requestMicrophone()
        }
        refreshPermissionState()

        // The defensive flow is an explicit System Settings handoff. Do
        // not call AXIsProcessTrustedWithOptions here: macOS can show its native
        // "control this computer" alert again after an ad-hoc rebuild, even
        // though the user already authorized this app. The card remains visible
        // until TCC reports the permission as ready, and the user can click the
        // exact pane again deliberately.
        openMissingPermissionSettings()
        refreshPermissionState()
        if !needsPermissionSetup {
            UserDefaults.standard.set(true, forKey: permissionOnboardingCompletedKey)
        }
        updatePermissionStatus()
        notify()
    }

    func openMissingPermissionSettings() {
        guard preferences.isolation == nil else { return }
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            AccessibilitySupport.openPrivacySettings(section: "Microphone")
            return
        }
        if !AccessibilitySupport.isTrusted() {
            AccessibilitySupport.openPrivacySettings(section: "Accessibility")
        }
    }

    /// 截圖模式用：固定示範中的前景 app 名稱，不讓 loginwindow／Finder 之類進行銷圖。
    func overrideCurrentAppNameForSnapshot(_ name: String) {
        currentAppName = name
    }

    func refreshPermissionState() {
        guard preferences.isolation == nil else { return }
        microphonePermissionReady = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibilityPermissionReady = AccessibilitySupport.isTrusted()
        needsPermissionSetup = !microphonePermissionReady || !accessibilityPermissionReady
        let context = AccessibilitySupport.readCurrentContext()
        currentAppName = context.appName ?? preferences.tr("未偵測", "Not detected")
        currentBundleIdentifier = context.foregroundBundleIdentifier ?? ""
        logger.info(
            "permission state microphone=\(self.microphonePermissionReady, privacy: .public) accessibility=\(self.accessibilityPermissionReady, privacy: .public)"
        )
    }

    /// 翻譯：用本機小型 editor 翻譯整段輸出。
    /// 翻譯結果與原文重疊度天然很低，不能過 FormatterOutputGuard 的幻覺重疊檢查，
    /// 只做 code fence 剝除與 trim。失敗回 nil（呼叫端出 notice＋留 log，不無聲吞掉）。
    private func translateOutput(_ text: String, target: TranslationTarget) async -> String? {
        if let localEditorTranslationRunner { return await localEditorTranslationRunner(text, target) }
        let command = preferences.localEditorCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return nil }
        // 字形轉換只對中文目標有意義；日文漢字會被 OpenCC s2t 誤改（国→國），
        // 非中文目標一律關掉 wrapper 的轉換。
        let script: String
        switch target {
        case .traditionalChinese: script = OutputScript.traditional.rawValue
        case .simplifiedChinese: script = OutputScript.simplified.rawValue
        default: script = OutputScript.asIs.rawValue
        }
        let prompt = """
        You are a professional translator. Translate the text below into \(target.promptName). \
        Output ONLY the translation. No explanations, no quotes, no labels.

        \(text)
        """
        do {
            let client = LocalFormatterProcessClient(command: command, outputScript: script)
            let candidate = try await client.format(
                prompt: prompt,
                model: preferences.localEditorModel.isEmpty ? "local-qwen3-editor" : preferences.localEditorModel
            )
            let cleaned = TranslatePrompt.cleanOutput(candidate)
            return cleaned.isEmpty ? nil : cleaned
        } catch {
            logger.info("translation failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func startRecording(mode: FormatterMode, persistMode: Bool = true) {
        guard !isProcessing else { return }
        prepareDictation(mode: mode)
        guard preferences.isolation == nil else { return }
        // 2026-09-24 實機（苑涵 0.1.5）：安裝中按聽寫＝錄完才靜靜失敗，使用者以為壞了。開始前就講清楚。
        if preferences.backend == .local, EngineInstaller.shared.isInstalling {
            let step = EngineInstaller.shared.lastLine
            fail(preferences.tr("本機引擎還在安裝，完成前無法轉文字。\(step)",
                                "The local engine is still installing; dictation works once it finishes. \(step)"))
            return
        }
        let generation = operationToken
        unloadTask?.cancel()
        unloadTask = nil
        activeMode = mode
        if persistMode { preferences.mode = mode }
        if mode == .smart, preferences.postProcessingEnabled, preferences.cleanupEnabled {
            let provider = SmartCleanup.Provider(rawValue: preferences.cleanupProvider.rawValue) ?? .gemini
            SmartCleanup.warmUp(provider: provider,
                                customEndpoint: preferences.customCleanupEndpoint,
                                bailianEndpoint: preferences.bailianFormatterEndpoint)
        } else if mode == .smart, preferences.postProcessingEnabled, preferences.backend == .local {
            LocalEditorPrewarmer.warmUp(command: preferences.localEditorCommand.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        Task { [weak self] in
            guard let self, self.operationToken == generation else { return }
            await self.beginRecording()
        }
    }

    func cancelProcessing() {
        invalidateBackground()
        activeTranslationTarget = .off
        askActive = false
        askSelection = nil
        guard isProcessing else { return }
        operationToken = UUID()
        cloudASRTask?.cancel()
        pcmTask?.cancel(); pcmTask = nil
        capture?.cancel()
        capture = nil
        pushToTalkActive = false
        isRecording = false
        isProcessing = false
        // 背景 cleanup 不准在取消後還把 lastOutput / history 蓋掉。
        pendingCleanupTask?.cancel()
        pendingCleanupTask = nil
        statusMessage = preferences.tr("已取消；沒有貼上新文字", "Cancelled; no new text was pasted")
        notify()
    }

    /// Escape cancel behaviour: stop an active capture first;
    /// if formatting is already running, cancel it without discarding the
    /// latest raw transcript.
    func cancelRecording() {
        invalidateBackground()
        activeTranslationTarget = .off
        askActive = false
        askSelection = nil
        if isRecording {
            operationToken = UUID()
            cloudASRTask?.cancel()
            pcmTask?.cancel(); pcmTask = nil
            capture?.cancel()
            capture = nil
            recordingLimitTask?.cancel(); recordingLimitTask = nil
            recordingLimitNotice = nil
            recordingLimitCountdown = nil
            pushToTalkActive = false
            isRecording = false
            isProcessing = false
            statusMessage = preferences.tr("已取消錄音；沒有貼上新文字", "Recording cancelled; no new text was pasted")
            notify()
            return
        }
        cancelProcessing()
    }

    func copyLastOutput() {
        guard !lastOutput.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastOutput, forType: .string)
        statusMessage = preferences.tr("已複製最後整理結果", "Copied the last formatted result")
        notify()
    }

    func copyHistory(_ record: HistoryRecord) {
        NSPasteboard.general.clearContents()
        // 取消的紀錄沒有輸出，只有逐字稿（app-shell-3）：複製逐字稿。
        NSPasteboard.general.setString(record.output.isEmpty ? record.rawTranscript : record.output, forType: .string)
        statusMessage = preferences.tr("已複製歷史結果", "Copied history result")
        notify()
    }

    func toggleHistoryStar(_ record: HistoryRecord) {
        preferences.toggleHistoryStar(id: record.id)
        notify()
    }

    func deleteHistory(_ record: HistoryRecord) {
        preferences.deleteHistory(id: record.id)
        statusMessage = preferences.tr("已刪除歷史紀錄", "History entry deleted")
        notify()
    }

    func clearHistory() {
        preferences.clearHistory()
        statusMessage = preferences.tr("已清空歷史紀錄", "History cleared")
        notify()
    }

    func openRecordingsFolder() {
        do {
            try FileManager.default.createDirectory(
                at: preferences.recordingsDirectory,
                withIntermediateDirectories: true
            )
            NSWorkspace.shared.open(preferences.recordingsDirectory)
        } catch {
            statusMessage = preferences.tr("無法開啟錄音資料夾", "Could not open the recordings folder")
            lastErrorMessage = error.localizedDescription
        }
        notify()
    }

    func playHistory(_ record: HistoryRecord) {
        guard let audioPath = record.audioPath,
              FileManager.default.fileExists(atPath: audioPath) else {
            statusMessage = preferences.tr("這筆紀錄沒有可播放的錄音", "This entry has no playable recording")
            notify()
            return
        }
        if playingHistoryID == record.id {
            historyAudioPlayer?.stop()
            historyAudioPlayer = nil
            playingHistoryID = nil
            notify()
            return
        }
        guard let player = NSSound(contentsOfFile: audioPath, byReference: true) else {
            statusMessage = preferences.tr("無法播放這筆錄音", "Could not play this recording")
            notify()
            return
        }
        historyAudioPlayer?.stop()
        historyAudioPlayer = player
        playingHistoryID = record.id
        player.play()
        statusMessage = preferences.tr("播放歷史錄音中", "Playing history recording")
        notify()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(1, Int(record.duration.rounded()) + 1)))
            guard let self, self.playingHistoryID == record.id else { return }
            self.playingHistoryID = nil
            self.historyAudioPlayer = nil
            self.notify()
        }
    }

    func retryHistory(_ record: HistoryRecord) {
        // 決策集中在 core 的 RetryPolicy（MAC2）：重試不重新錄音；順序是「忙碌先擋」再看模式。
        // 有逐字稿就重新整理；辨識失敗／轉錄前取消的紀錄沒有逐字稿，用存下來的錄音重新辨識（delivery-learning-1）。
        let decision = RetryPolicy.decide(mode: record.mode, isRecording: isRecording, isProcessing: isProcessing,
                                          isAskAnything: record.isAskAnything, rawTranscript: record.rawTranscript,
                                          hasAudio: record.audioPath.map { FileManager.default.fileExists(atPath: $0) } ?? false)
        switch decision {
        case .ignoreBusy:
            return
        case .needsReselection:
            statusMessage = preferences.tr(
                "Edit Selection 需要重新選取原文字後再執行",
                "Edit Selection requires selecting the original text again before retrying"
            )
            notify()
            return
        case .notDictation:
            statusMessage = preferences.tr("Ask anything 的紀錄不能重試；請再問一次",
                                           "Ask anything entries can't be retried; ask again")
            notify()
            return
        case .nothingToRetry:
            statusMessage = preferences.tr("這筆沒有逐字稿，錄音也已刪除；沒有東西可以重試",
                                           "This entry has no transcript and its recording was deleted; nothing to retry")
            notify()
            return
        case .reformatFromRawTranscript, .retranscribeFromAudio:
            break
        }
        // app-shell-v1：就地更新同一筆、不改預設模式、不貼到最前面的 App（從設定頁按重試時那就是 Type 自己）。
        // 使用數據：正常的紀錄已經算過不再算；失敗／取消的紀錄當初沒算，重試成功時算一次。
        guard let bookkeeping = RetryPolicy.bookkeeping(for: decision, entryCounted: record.status == nil) else { return }
        activeMode = record.mode
        if bookkeeping.changesDefaultMode { preferences.mode = record.mode }
        selectedContext = nil
        retriedHistoryID = nil
        operationToken = UUID()
        isProcessing = true
        let retranscribe = decision == .retranscribeFromAudio
        statusMessage = retranscribe
            ? preferences.tr("重新辨識這段錄音…", "Re-transcribing this recording…")
            : preferences.tr("重新整理歷史紀錄…", "Reformatting history entry…")
        let token = operationToken
        notify()
        historyRetryTask = Task { [weak self] in
            var transcript = record.rawTranscript
            if retranscribe, let self, let audioPath = record.audioPath {
                let outcome = await self.transcribeRecording(at: URL(fileURLWithPath: audioPath))
                guard token == self.operationToken else { return }
                guard let text = outcome.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    // 還是辨識不出來：同一筆留著（仍是失敗、錄音還在），原因換成這一次的。
                    let reason = outcome.failure ?? self.noTranscriptMessage
                    self.preferences.setHistoryNote(id: record.id, note: reason)
                    self.fail(self.preferences.tr("重新辨識沒有成功：\(reason)", "Re-transcription didn't succeed: \(reason)"))
                    return
                }
                transcript = text
            }
            await self?.formatAndPaste(
                transcript: transcript,
                audioDuration: record.duration,
                asrError: nil,
                token: token,
                historyID: bookkeeping.updatesEntryInPlace ? record.id : UUID(),
                audioPath: record.audioPath,
                translation: record.translation ?? .off,   // FX-4：翻譯過的那筆重試照樣翻譯
                sink: .retry(record, bookkeeping)
            )
            guard let self else { return }
            self.isProcessing = false
            self.scheduleRuntimeUnload()
            self.notify()
        }
    }

    /// 寫剪貼簿的唯一入口：隔離模式（測試）不碰系統剪貼簿。
    func writeClipboard(_ text: String) {
        if preferences.isolation != nil { isolatedClipboard = text; return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func reprocessLastResult() {
        guard preferences.postProcessingEnabled,
              !isRecording,
              !isProcessing,
              !lastRawTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        activeMode = .smart
        operationToken = UUID()
        isProcessing = true
        statusMessage = preferences.tr("重新整理最後一段…", "Reformatting the last passage…")
        let token = operationToken
        let transcript = lastRawTranscript
        notify()
        Task { [weak self] in
            // 這是對目前游標的新貼上（新的一筆），但同一段話已經算過一次使用數據（app-shell-v1）。
            await self?.formatAndPaste(
                transcript: transcript,
                audioDuration: 0,
                asrError: nil,
                token: token,
                historyID: UUID(),
                sink: .newEntry(countsTowardStats: false)
            )
            guard let self else { return }
            self.isProcessing = false
            self.scheduleRuntimeUnload()
            self.notify()
        }
    }

    func requestAccessibility() {
        refreshPermissionState()
        AccessibilitySupport.openPrivacySettings(section: "Accessibility")
        statusMessage = accessibilityPermissionReady
            ? preferences.tr(
                "輔助使用已完成；若功能仍未更新，請回到 \(AppBrand.displayName) 再試一次",
                "Accessibility is granted; if features still lag, return to \(AppBrand.displayName) and try again"
            )
            : preferences.tr(
                "請在系統設定中允許 \(AppBrand.displayName) 輔助使用",
                "Please allow \(AppBrand.displayName) under Accessibility in System Settings"
            )
        notify()
    }

    private func updatePermissionStatus() {
        if !needsPermissionSetup {
            statusMessage = preferences.tr("系統權限已就緒", "System permissions are ready")
        } else if !microphonePermissionReady && !accessibilityPermissionReady {
            statusMessage = preferences.tr(
                "尚缺麥克風與輔助使用權限；只會提示一次",
                "Microphone and Accessibility permissions are still missing; you will only be prompted once"
            )
        } else if !microphonePermissionReady {
            statusMessage = preferences.tr(
                "輔助使用已完成；尚缺麥克風權限",
                "Accessibility is granted; Microphone permission is still missing"
            )
        } else {
            statusMessage = preferences.tr(
                "麥克風已完成；尚缺輔助使用權限",
                "Microphone is granted; Accessibility permission is still missing"
            )
        }
    }

    func reportShortcutStatus(_ message: String) {
        statusMessage = message
        notify()
    }

    private func beginRecording() async {
        editWatcher.checkNow()   // 上一段已經改完了：先比對，再開始這一段
        lastErrorMessage = nil
        partialTranscript = ""
        selectedContext = nil
        let generation = operationToken

        guard await PermissionGate.requestMicrophone() else {
            fail(preferences.tr(
                "麥克風權限未開啟；請到系統設定 → 隱私權與安全性 → 麥克風允許 \(AppBrand.displayName)",
                "Microphone permission is off; allow \(AppBrand.displayName) in System Settings → Privacy & Security → Microphone"
            ))
            return
        }

        guard generation == operationToken else { return }
        if activeMode == .editSelection {
            guard AccessibilitySupport.isTrusted() else {
                fail(preferences.tr(
                    "Edit Selection 需要輔助使用權限；未讀取任何螢幕內容",
                    "Edit Selection needs Accessibility permission; no screen content was read"
                ))
                return
            }
            // modes-3：Electron／Chromium 的 App 先打開 AXManualAccessibility；剛打開的話等它建好樹再讀。
            if ChromiumAccessibility.shared.enableForFrontmostApp() {
                try? await Task.sleep(for: .milliseconds(300))
                guard generation == operationToken else { return }
            }
            let context = AccessibilitySupport.readCurrentContext(
                includeSurrounding: preferences.includeSurroundingContext,
                blockedSites: preferences.contextBlockedSites
            )
            // context-awareness-v2：擋下的原因（在清單上／網址讀不到）分開講；沒有選取另一句。
            if let problem = editSelectionProblem(context) {
                fail(problem)
                return
            }
            selectedContext = context
            let element = AccessibilitySupport.focusedElement()
            editAnchor = SelectionAnchor(
                text: context.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                pid: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                element: element,
                range: element.flatMap(AccessibilitySupport.selectedRange(of:)),
                editable: element.map(Self.isEditable) ?? false)
        }

        // Local Qwen3-ASR remains the final transcript source. If the user has
        // already granted Speech permission, Apple's on-device recognizer adds
        // a low-latency preview. A configured Qwen runtime never triggers an
        // extra permission prompt; the Speech fallback is requested only when
        // no local ASR executable is available.
        let hasLocalASRCommand = !preferences.localASRCommand
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        let enableSpeechPreview: Bool
        if preferences.backend != .local {
            enableSpeechPreview = false
        } else if hasLocalASRCommand {
            enableSpeechPreview = SFSpeechRecognizer.authorizationStatus() == .authorized
        } else {
            enableSpeechPreview = await PermissionGate.requestSpeechRecognition()
        }

        let session = AudioCaptureSession(
            inputDeviceUID: preferences.inputDeviceUID.isEmpty ? nil : preferences.inputDeviceUID,
            inputChannel: preferences.inputChannel,
            transcriptionLanguageIdentifier: preferences.transcriptionLanguage.speechLocaleIdentifier,
            outputDeviceUID: preferences.outputDeviceUID.isEmpty ? nil : preferences.outputDeviceUID,
            muteWhileRecording: preferences.muteWhileRecording,
            voiceActivityDetection: preferences.voiceActivityDetection && !preferences.pushToTalkEnabled
        )
        session.defersOutputMute = RecordingCues.defersMute(audioFeedback: preferences.audioFeedback,
                                                            muteWhileRecording: preferences.muteWhileRecording)
        // asr-vocab-v3：Apple 語音退路（還沒裝本機引擎的人全程走這條）也吃同一份提示詞，受 Apple 的條數上限。
        session.speechHints = asrHints(limit: AudioCaptureSession.speechHintLimit)
        // 忘記關麥的保護（capture-latency-v3）：只有 Groq 一條辨識路時上限比 Groq 收的短（295 秒），否則 9 分鐘。
        // repair round 2：上限在 tap 端按樣本數硬截（`captureLimitSeconds`），不只靠每秒一次的檢查。
        let groqActive = groqASRActive   // 讀一次 key（Keychain）：上限與下面選辨識路用同一個答案
        let groqOnlyCapture = preferences.backend == .local && groqActive && !localASRConfigured
        let maxRecordingDuration = RecordingLimits.maxDuration(cloudOnly: groqOnlyCapture)
        session.captureLimitSeconds = maxRecordingDuration
        session.onCaptureLimitReached = { [weak self, weak session] in
            Task { @MainActor in
                guard let self, let session, self.isRecording, self.capture === session else { return }
                _ = self.applyRecordingLimit(.stop(.maxDuration), maxDuration: maxRecordingDuration)
            }
        }
        session.onPartial = { [weak self] text in
            Task { @MainActor in
                guard let self else { return }
                self.partialTranscript = text
                self.statusMessage = self.preferences.tr("聆聽中…", "Listening…")
                self.notify()
            }
        }
        session.onSilenceDetected = { [weak self] in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                self.statusMessage = self.preferences.tr(
                    "偵測到停止說話，正在完成轉錄…",
                    "Detected silence; finishing transcription…"
                )
                self.stopRecording()
            }
        }

        let audioStream: AsyncThrowingStream<Data, Error>
        do {
            audioStream = try session.start(enableSpeechFallback: enableSpeechPreview)
        } catch {
            fail(error.localizedDescription)
            return
        }

        capture = session
        isRecording = true
        startRecordingCues(session)
        let micName = session.inputDeviceName
        statusMessage = micName.isEmpty
            ? preferences.tr("聆聽中…點選停止以整理並貼上", "Listening… click stop to format and paste")
            : preferences.tr("聆聽中（麥克風：\(micName)）…點選停止以整理並貼上", "Listening (mic: \(micName))… click stop to format and paste")
        notify()
        // 2026-09-24 實機（苑涵 0.1.5）：AirPods 搶走系統輸入，對著電腦講、錄到的全是靜音，使用者不知道。
        // 錄音中輸入裝置被換掉＝停下來講清楚；講了 3 秒還幾乎沒聲音＝當場提示用的是哪支麥克風。
        session.onInputDeviceChanged = { [weak self] in
            Task { @MainActor in
                guard let self, self.isRecording, self.capture === session else { return }
                self.inputChangedDuringRecording = true
                self.stopRecording()
            }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, self.isRecording, self.capture === session,
                  session.peakDBFSSoFar < AudioCaptureResult.silentPeakDBFS else { return }
            self.statusMessage = self.preferences.tr(
                "好像沒收到聲音——目前使用的麥克風是「\(micName)」，可到設定換輸入裝置",
                "No sound detected yet — the current microphone is \"\(micName)\"; change the input in Settings")
            self.notify()
        }

        if preferences.pushToTalkEnabled && !pushToTalkActive {
            stopRecording()
            return
        }

        if preferences.backend == .bailian {
            do {
                let asr = try BailianASRTranscriber(
                    endpointString: preferences.bailianASREndpoint,
                    workspaceID: preferences.bailianWorkspaceID
                )
                let appContext = deliveryContext()
                let asrContext = ASRContext(
                    languageIdentifier: preferences.transcriptionLanguage.speechLocaleIdentifier,
                    allowMixedChineseEnglish: true,
                    hotwords: asrHints(limit: 50),
                    limitedContext: String((appContext.appName ?? "").prefix(120))
                )
                cloudASRTask = Task { [weak self] in
                    var finalized = ""
                    var latest = ""
                    for try await partial in asr.transcribe(audio: audioStream, context: asrContext) {
                        if partial.isFinal {
                            finalized.append(partial.text)
                            latest = finalized
                        } else {
                            latest = finalized + partial.text
                        }
                        if let self {
                            self.partialTranscript = latest
                            self.statusMessage = self.preferences.tr("即時轉錄中…", "Live transcribing…")
                            self.notify()
                        }
                    }
                    return finalized.isEmpty ? latest : finalized
                }
            } catch {
                statusMessage = preferences.tr(
                    "百鍊 ASR 尚未就緒；停止後會嘗試本機 adapter",
                    "Bailian ASR is not ready; the local adapter will be tried after you stop"
                )
                notify()
            }
        } else if groqActive || localASRConfigured {
            pcmEngineIsGroq = groqActive
            if pcmEngineIsGroq { MacCloudASR.warmUp() }
            let token = operationToken
            pcmTask = Task.detached(priority: .userInitiated) { [weak self] in
                var pcm = Data()
                var pauses = MacCloudASR.PauseDetector()
                do {
                    for try await chunk in audioStream {
                        pcm.append(chunk)
                        if pauses.feed(chunk) {
                            let snapshot = pcm
                            Task { @MainActor [weak self] in self?.speculate(pcm: snapshot, token: token) }
                        }
                    }
                } catch { }
                return pcm
            }
        }
        watchRecordingLimits(session, maxDuration: maxRecordingDuration)
    }

    /// 每秒看一次：快到上限、很久沒聲音都先倒數（看得到，不出聲），倒數完照常停止（不是取消）。
    /// 長度上限另外在 tap 端按樣本數硬截（`AudioCaptureSession.captureLimitSeconds`），這裡負責倒數與停止。
    /// 長度按實際錄到的音訊算（`capturedSeconds`），安靜按比較低的門檻算（`lastSoundActivity`）。
    private func watchRecordingLimits(_ session: AudioCaptureSession, maxDuration: TimeInterval) {
        recordingLimitTask?.cancel()
        recordingLimitNotice = nil
        recordingLimitCountdown = nil
        var limits = RecordingLimits(startedAt: Date(), maxDuration: maxDuration)
        recordingLimitTask = Task { @MainActor [weak self] in
            while true {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.isRecording, self.capture === session else { return }
                let action = limits.check(now: Date(), capturedSeconds: session.capturedSeconds,
                                          lastVoiceAt: session.lastSoundActivity)
                guard self.applyRecordingLimit(action, maxDuration: maxDuration) else { return }
            }
        }
    }

    /// 回傳要不要繼續看。測試直接呼叫（隔離模式沒有麥克風，`stopRecording` 不做事）。
    func applyRecordingLimit(_ action: RecordingLimits.Action, maxDuration: TimeInterval) -> Bool {
        switch action {
        case .none:
            // 安靜倒數中又有聲音：倒數取消，提示收掉。
            guard recordingLimitNotice != nil else { return true }
            recordingLimitNotice = nil
            recordingLimitCountdown = nil
            statusMessage = preferences.tr("聆聽中…", "Listening…")
            notify()
            return true
        case .countdown(let secondsLeft):
            showRecordingLimitCountdown(.maxDuration, notice: preferences.tr(
                "錄音將在 \(secondsLeft) 秒後自動停止並送出",
                "Recording stops and is sent automatically in \(secondsLeft) s"))
            return true
        case .silenceCountdown(let secondsLeft):
            showRecordingLimitCountdown(.longSilence, notice: preferences.tr(
                "一直沒有聲音，錄音將在 \(secondsLeft) 秒後自動停止（不會自動送出）；講話就繼續錄",
                "No sound for a while; recording stops in \(secondsLeft) s (won't auto-submit). Speak to keep recording"))
            return true
        case .stop(let reason):
            let minutes = Int(maxDuration / 60)
            if reason == .longSilence { autoSubmitSuppressedToken = operationToken }
            recordingLimitCountdown = nil
            recordingLimitNotice = nil
            stopRecording()
            statusMessage = reason == .maxDuration
                ? preferences.tr("已達錄音上限 \(minutes) 分鐘，自動停止，正在轉錄…",
                                 "Reached the \(minutes)-minute recording limit; stopped automatically, transcribing…")
                : preferences.tr("一直沒有聲音，自動停止（不會自動送出），正在轉錄…",
                                 "No sound for a while; stopped automatically (won't auto-submit), transcribing…")
            deliveryLog.info("recording auto-stopped: \(reason == .maxDuration ? "max-duration" : "long-silence", privacy: .public)")
            notify()
            return false
        }
    }

    /// 倒數只改看得到的東西（錄音球、提示文字），不出聲（repair round 2，見 `recordingLimitCountdown`）。
    private func showRecordingLimitCountdown(_ kind: RecordingLimits.StopReason, notice: String) {
        if recordingLimitCountdown != kind { recordingLimitCountdown = kind }
        guard notice != recordingLimitNotice else { return }
        recordingLimitNotice = notice
        statusMessage = notice
        notify()
    }

    private var localASRConfigured: Bool {
        preferences.backend == .local && !preferences.localASRCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 本機優先模式＋開了雲端辨識＋有 Groq key＋語言是中／英。
    private var groqASRActive: Bool {
        preferences.backend == .local && preferences.cloudASREnabled
            && MacCloudASR.supports(language: preferences.transcriptionLanguage.rawValue)
            && !MacCloudASR.key().isEmpty
    }

    /// 停頓點：把目前為止的錄音先辨識；這次會走雲端背景整理的話，拿到文字就用跟停止後**完全相同的輸入**先整理。
    private func speculate(pcm: Data, token: UUID) {
        guard token == operationToken, isRecording, !askActive else { return }
        speculation?.asr.cancel(); speculation?.cleanup?.task.cancel()
        let language = preferences.transcriptionLanguage.rawValue
        let hotwords = asrHints(limit: 80)
        let script = preferences.outputScript
        let taiwanFixes = preferences.effectiveLanguageVariant.appliesTaiwanFixes
        let asr: Task<String?, Never>
        if pcmEngineIsGroq {
            let key = MacCloudASR.key()
            asr = Task {
                if case .ok(let text) = await MacCloudASR.transcribe(pcm16: pcm, language: language, hotwords: hotwords,
                                                                     outputScript: script, key: key,
                                                                     taiwanFixes: taiwanFixes) { return text }
                return nil
            }
        } else {
            // 本機 Qwen：停頓前的錄音寫成暫存 WAV 先辨識（不上傳）。
            let client = localASRClient()
            asr = Task.detached(priority: .userInitiated) {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("utuvo-type-pause-\(UUID().uuidString).wav")
                defer { try? FileManager.default.removeItem(at: url) }
                guard (try? WhisperAudio.wav(MacCloudASR.samples(fromPCM16: pcm)).write(to: url)) != nil,
                      let text = try? await client.transcribe(audioURL: url),
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return text
            }
        }
        speculation = Speculation(token: token, pcmBytes: pcm.count, asr: asr)
        deliveryLog.info("pause: speculating on \(pcm.count / 32, privacy: .public) ms of audio")
        Task { [weak self] in
            guard let text = await asr.value, let self, token == self.operationToken,
                  self.speculation?.asr == asr, !self.askActive,
                  self.preferences.cleanupEnabled, self.preferences.postProcessingEnabled,
                  Self.backgroundEligible(mode: self.activeMode, translation: self.activeTranslationTarget,
                                          autoSubmit: self.preferences.autoSubmit, enabled: true,
                                          language: self.preferences.transcriptionLanguage.rawValue) else { return }
            let context = self.deliveryContext()
            let dictionary = self.preferences.dictionary
            let original = self.deliveryOriginal(self.normalizedForDelivery(text, dictionary: dictionary))
            let config = self.cleanupConfig(original: original, context: context, dictionary: dictionary)
            let run = self.cleanupRunner
            self.speculation?.cleanup = (text, config, Task { await run(text, config) })
        }
    }

    private func localASRClient() -> LocalASRProcessClient {
        LocalASRProcessClient(
            command: preferences.localASRCommand,
            argumentsTemplate: preferences.localASRArguments,
            outputScript: preferences.outputScript.rawValue,
            asrLanguage: preferences.transcriptionLanguage.asrLanguageName,
            hotwords: asrHints(limit: 80))
    }

    /// 辨識提示詞：Qwen、Groq、百鍊、Apple 語音退路都從這一份排好的清單取前 `limit` 個
    /// （個人字典 → 產品名 → 音訊 → AI → 其他內建 → catalog，排序在 core `BuiltInVocabulary.asrHints`；asr-vocab-1／v3）。
    /// 字形跟輸出走（core `BuiltInVocabulary.hintScript`）：台灣繁體時只有簡體寫的個人詞轉繁體（字典裡存成簡體的詞會把
    /// 辨識器帶去輸出簡體），已經是繁體的詞不動；簡體輸出時內建包的繁體詞轉簡體。
    func asrHints(limit: Int) -> [String] {
        let script = BuiltInVocabulary.hintScript(language: preferences.transcriptionLanguage.rawValue,
                                                  simplifiedOutput: preferences.outputScript == .simplified)
        return VocabularyPacks.contextualHints(personal: preferences.dictionary, enabled: preferences.enabledVocabularyPackIDs,
                                               limit: limit, script: script)
    }

    /// 停止後的整理：停頓時已經用同一份（逐字稿＋設定）先跑了就沿用，否則現在跑。
    private func cleanupWork(raw: String, config: CleanupConfig) -> @Sendable () async -> String? {
        if let pending = speculation?.cleanup, pending.raw == raw, pending.config == config {
            speculation = nil
            deliveryLog.info("pause: cleanup reused from pause")
            let task = pending.task
            return { await task.value }
        }
        let run = cleanupRunner
        return { await run(raw, config) }
    }

    private func stopRecording() {
        guard isRecording, let capture else { return }
        isRecording = false
        isProcessing = true
        statusMessage = preferences.tr("正在完成轉錄…", "Finishing transcription…")
        notify()

        let cloudTask = cloudASRTask
        let pcmTask = pcmTask
        self.pcmTask = nil
        let groqTask = pcmEngineIsGroq ? pcmTask : nil
        let token = operationToken
        // 停止當下就記住這次是不是 Ask、用的模式和 App：取消會把 askActive 清掉，之後就分不出來
        // （Ask 的錄音不能當聽寫留著）；下一次錄音也會換掉模式與脈絡。
        let origin = captureOrigin()
        self.capture = nil
        recordingLimitTask?.cancel(); recordingLimitTask = nil
        recordingLimitNotice = nil
        recordingLimitCountdown = nil
        stopPressedAt = Date()
        // 有正式辨識（Groq／本機 Qwen）時，Apple 語音預覽只是最後的退路，不必再等它 350 ms 收尾。
        let speechGrace = groqTask == nil && cloudTask == nil
            && preferences.localASRCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        Task { [weak self] in
            let result = await capture.stop(speechGrace: speechGrace)
            self?.playAudioFeedbackIfEnabled()
            await self?.finishCapture(result, cloudTask: cloudTask, pcmTask: pcmTask, groqTask: groqTask,
                                      capture: capture, token: token, origin: origin)
        }
    }

    /// 開始提示音＋錄音時靜音（capture-latency-5）。兩個都開時：先播音（藍牙耳機先等它切換完），
    /// 播完才靜音；只開一個時跟以前一樣（靜音已在 start() 做、提示音立刻播）。
    private func startRecordingCues(_ session: AudioCaptureSession) {
        guard session.defersOutputMute else { playAudioFeedbackIfEnabled(); return }
        let plan = RecordingCues.startPlan(audioFeedback: true, muteWhileRecording: true, toneDelayMs: startToneDelayMs())
        Task { @MainActor [weak self] in
            await RecordingCues.run(
                plan,
                stillRecording: { [weak self] in
                    guard let self else { return false }
                    return self.isRecording && self.capture === session
                },
                playTone: { [weak self] in self?.playAudioFeedbackIfEnabled() },
                mute: { session.applyDeferredOutputMute() },
                sleep: { try? await Task.sleep(for: .milliseconds($0)) })
        }
    }

    /// Typeless 的開始音延遲：同一支藍牙耳機又錄又放 1.2 s、AirPods 0.3 s、其他 0。
    private func startToneDelayMs() -> Int {
        let outputUID = preferences.outputDeviceUID.isEmpty ? AudioDeviceCatalog.defaultOutputUID() : preferences.outputDeviceUID
        guard let outputUID else { return 0 }
        let inputUID = preferences.inputDeviceUID.isEmpty ? AudioDeviceCatalog.defaultInputUID() : preferences.inputDeviceUID
        let name = AudioDeviceCatalog.outputDevices().first { $0.id == outputUID }?.name ?? ""
        return RecordingCues.toneDelayMs(outputIsBluetooth: AudioDeviceCatalog.isBluetooth(uid: outputUID),
                                         outputIsAlsoInput: inputUID == outputUID, outputName: name)
    }

    private func playAudioFeedbackIfEnabled() {
        guard preferences.audioFeedback else { return }
        feedbackTonePlayer.play(
            outputDeviceUID: preferences.outputDeviceUID,
            frequency: isRecording ? 880 : 660,
            volume: preferences.audioFeedbackVolume
        )
    }

    private func finishCapture(
        _ result: AudioCaptureResult?,
        cloudTask: Task<String, Error>?,
        pcmTask: Task<Data, Never>? = nil,
        groqTask: Task<Data, Never>? = nil,
        capture: AudioCaptureSession,
        token: UUID,
        origin: CaptureOrigin
    ) async {
        guard token == operationToken else {
            // 按了停止、轉錄還沒開始就取消（delivery-learning-1）：不送辨識（尤其不送雲端），
            // 錄音照「處理中取消」的規則收好或刪掉，不留在暫存資料夾。
            if let result, result.framesWritten > 0 {
                await concludeCapture(CapturedAudio(result, transcript: "", asrError: nil, origin: origin), token: token)
            } else if let result {
                capture.deleteTemporaryAudio(at: result.audioURL)
            }
            return
        }
        defer {
            if token == operationToken {
                cloudASRTask = nil
                isProcessing = false
                scheduleRuntimeUnload()
                notify()
            }
        }
        guard let result else {
            fail(preferences.tr("沒有取得錄音結果；未貼上文字", "No recording result was received; no text was pasted"))
            return
        }
        let inputChanged = inputChangedDuringRecording
        inputChangedDuringRecording = false
        let micName = result.inputDeviceName
        if result.framesWritten == 0 {
            capture.deleteTemporaryAudio(at: result.audioURL)
            fail(inputChanged
                 ? preferences.tr("錄音中麥克風被切換（原本：\(micName)），這次沒有錄到聲音；請再講一次",
                                  "The microphone changed during recording (was: \(micName)); nothing was captured. Please try again")
                 : preferences.tr("沒有錄到任何聲音（麥克風：\(micName)）；請確認輸入裝置後再試",
                                  "Nothing was captured (mic: \(micName)); check the input device and try again"))
            return
        }

        let captureMs = stopPressedAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1
        let asrStarted = Date()
        var asrEngine = "speech"
        var transcript = ""
        var asrError: Error?
        if let pcmTask {
            let pcm = await pcmTask.value
            if let pending = speculation, pending.token == token, MacCloudASR.isQuiet(pcm, from: pending.pcmBytes),
               let text = await pending.asr.value {
                transcript = text; asrEngine = groqTask == nil ? "local-pause" : "groq-pause"
            }
        }
        // 取消之後不再開始任何辨識（尤其不再把錄音送雲端）。
        if let groqTask, transcript.isEmpty, token == operationToken {
            let pcm = await groqTask.value
            if case .ok(let text) = await groqTranscribe(pcm) { transcript = text; asrEngine = "groq" }
            else { asrEngine = "groq-failed" }
        }
        if let cloudTask {
            do {
                transcript = try await cloudTask.value
            } catch {
                asrError = error
            }
        }

        // The local process is the preferred local Qwen3-ASR integration. It
        // is only invoked when the user has explicitly configured a command;
        // there is no download or model discovery side effect.
        if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !preferences.localASRCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           token == operationToken {
            do {
                transcript = try await localASRClient().transcribe(audioURL: result.audioURL)
                asrEngine = asrEngine == "groq-failed" ? "groq-failed>local" : "local"
            } catch {
                asrError = asrError ?? error
            }
        }

        if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            transcript = result.speechTranscript
        }
        let asrMs = Int(Date().timeIntervalSince(asrStarted) * 1000)
        deliveryLog.info("timing: capture \(captureMs, privacy: .public) ms, asr[\(asrEngine, privacy: .public)] \(asrMs, privacy: .public) ms")
        await concludeCapture(CapturedAudio(result, transcript: transcript, asrError: asrError, origin: origin), token: token)
    }

    /// 按下停止那一刻這段錄音屬於誰：Ask 與否、模式、開始聽寫時抓的 App、要翻成的語言。
    struct CaptureOrigin {
        var isAsk: Bool
        var mode: FormatterMode
        var appName: String?
        var bundleIdentifier: String?
        /// 失敗／取消的紀錄也要記（FX-4）：取消會把 `activeTranslationTarget` 歸零，所以停止當下就記住。
        var translation: TranslationTarget
    }

    private func captureOrigin() -> CaptureOrigin {
        let context = capturedContext?.token == operationToken ? capturedContext?.context : nil
        return CaptureOrigin(isAsk: askActive, mode: activeMode, appName: context?.appName,
                             bundleIdentifier: context?.foregroundBundleIdentifier, translation: activeTranslationTarget)
    }

    /// 辨識完（或沒辨識就取消）的一段錄音，`concludeCapture` 的輸入。
    struct CapturedAudio {
        var audioURL: URL
        var transcript: String
        var asrError: Error?
        var duration: TimeInterval
        var soundsSilent: Bool
        var peakDBFS: Float
        var micName: String
        var origin: CaptureOrigin

        init(audioURL: URL, transcript: String, asrError: Error?, duration: TimeInterval, soundsSilent: Bool,
             peakDBFS: Float, micName: String, origin: CaptureOrigin) {
            self.audioURL = audioURL; self.transcript = transcript; self.asrError = asrError; self.duration = duration
            self.soundsSilent = soundsSilent; self.peakDBFS = peakDBFS; self.micName = micName; self.origin = origin
        }

        init(_ result: AudioCaptureResult, transcript: String, asrError: Error?, origin: CaptureOrigin) {
            self.init(audioURL: result.audioURL, transcript: transcript, asrError: asrError, duration: result.duration,
                      soundsSilent: result.soundsSilent, peakDBFS: result.peakDBFS, micName: result.inputDeviceName,
                      origin: origin)
        }
    }

    private var noTranscriptMessage: String {
        preferences.tr("沒有收到轉錄文字；請設定本機 Qwen3-ASR command 或選擇百鍊 ASR",
                       "No transcript was received; configure a local Qwen3-ASR command or choose Bailian ASR")
    }

    /// 辨識之後的收尾（delivery-learning-1／app-shell-3，2026-10-22）。規則：存進 Recordings 的錄音
    /// **一定**有一筆紀錄指著它，否則就刪掉——不留孤兒錄音。
    /// - 靜音：不存錄音、不寫紀錄。
    /// - 有聲音但辨識沒出字：寫一筆「辨識失敗」（不算使用數據），錄音留著，可在歷史紀錄按「重試」重新辨識。
    /// - 處理中取消（辨識途中或整理途中）：寫一筆「已取消」，逐字稿（有的話）和錄音留著、可以重試，
    ///   不算使用數據（Typeless 一樣把取消的轉錄留在歷史、提供 retry）。錄音中按 Esc 不在這裡：那個照舊丟掉。
    /// - Ask anything：指令不是聽寫、不能重試，失敗或取消時錄音刪掉。
    private func concludeCapture(_ audio: CapturedAudio, token: UUID) async {
        let transcript = audio.transcript
        let hasText = !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard token == operationToken else {
            keepCancelledCapture(audio)
            return
        }
        // 這次錄音的翻譯目標在這裡讀走並歸零，不論接下來是靜音、辨識失敗、Ask 還是正常貼出（FX-4 順手修）：
        // 以前只有正常貼出才歸零，辨識失敗後從選單開的 Edit Selection／Deep 會被殘留的目標偷翻譯。
        // token 不同（上面那條）時不動：那時可能已經開始下一次錄音，目標是新的那一次的。
        let translation = consumeTranslationTarget()
        guard hasText else {
            if audio.soundsSilent {
                deleteTemporaryRecording(audio.audioURL)
                fail(preferences.tr("好像沒收到聲音（峰值 \(Int(audio.peakDBFS)) dB）——目前使用的麥克風是「\(audio.micName)」，可到設定換輸入裝置",
                                    "No sound was picked up (peak \(Int(audio.peakDBFS)) dB) — the microphone was \"\(audio.micName)\"; change the input in Settings"))
                return
            }
            let reason = audio.asrError?.localizedDescription ?? noTranscriptMessage
            let id = UUID()
            // Ask 的指令不能重試：不留錄音。
            guard !audio.origin.isAsk, let path = preferences.storeRecording(from: audio.audioURL, id: id) else {
                deleteTemporaryRecording(audio.audioURL)
                fail(reason)
                return
            }
            deleteTemporaryRecording(audio.audioURL)
            preferences.appendHistory(HistoryRecord(id: id, rawTranscript: "", output: "", duration: audio.duration,
                mode: audio.origin.mode, appName: audio.origin.appName, bundleIdentifier: audio.origin.bundleIdentifier,
                audioPath: path, note: reason, status: .failed,
                translation: HistoryRecord.storedTranslation(audio.origin.translation, mode: audio.origin.mode)),
                countsTowardStats: false)
            onDeliveryEvent?("asr-failed")
            fail(preferences.tr("辨識沒有成功：\(reason)。錄音已留在歷史紀錄，可按「重試」重新辨識",
                                "Transcription didn't succeed: \(reason). The recording is kept in History; press Retry to transcribe it again"))
            return
        }
        let historyID = UUID()
        let historyAudioPath = preferences.storeRecording(from: audio.audioURL, id: historyID)
        deleteTemporaryRecording(audio.audioURL)
        if audio.origin.isAsk {
            askActive = false
            await handleAsk(transcript: transcript, duration: audio.duration, historyID: historyID,
                            audioPath: historyAudioPath, token: token)
            // Ask 沒答完（失敗／取消）就沒有紀錄：錄音不能留成孤兒。
            preferences.discardRecordingIfUnreferenced(historyAudioPath)
            return
        }
        await formatAndPaste(
            transcript: transcript,
            audioDuration: audio.duration,
            asrError: audio.asrError,
            token: token,
            historyID: historyID,
            audioPath: historyAudioPath,
            translation: translation
        )
        // 整理途中取消時 formatAndPaste 不寫紀錄：補一筆「已取消」，逐字稿和錄音留著可以重試。
        guard !preferences.historyRecords.contains(where: { $0.id == historyID }) else { return }
        guard token != operationToken else {
            preferences.discardRecordingIfUnreferenced(historyAudioPath)
            return
        }
        appendCancelledEntry(id: historyID, transcript: transcript, audio: audio, audioPath: historyAudioPath)
    }

    /// 轉錄還沒完成就被取消的錄音（delivery-learning-1）：靜音或 Ask → 刪；其他 → 寫「已取消」紀錄。
    private func keepCancelledCapture(_ audio: CapturedAudio) {
        guard !audio.origin.isAsk, !audio.soundsSilent else {
            deleteTemporaryRecording(audio.audioURL)
            return
        }
        let id = UUID()
        let path = preferences.storeRecording(from: audio.audioURL, id: id)
        deleteTemporaryRecording(audio.audioURL)
        // 錄音存不進去（資料夾不能寫、磁碟滿）：有逐字稿就照樣留一筆、沒有錄音——跟整理途中取消一樣（repair-batch1）。
        // 錄音和逐字稿都沒有才不寫（沒有東西可以留）。
        guard path != nil || !audio.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        appendCancelledEntry(id: id, transcript: audio.transcript, audio: audio, audioPath: path)
    }

    private func appendCancelledEntry(id: UUID, transcript: String, audio: CapturedAudio, audioPath: String?) {
        preferences.appendHistory(HistoryRecord(id: id, rawTranscript: transcript, output: "", duration: audio.duration,
            mode: audio.origin.mode, appName: audio.origin.appName, bundleIdentifier: audio.origin.bundleIdentifier,
            audioPath: audioPath, note: nil, status: .cancelled,
            translation: HistoryRecord.storedTranslation(audio.origin.translation, mode: audio.origin.mode)),
            countsTowardStats: false)
        onDeliveryEvent?("cancelled-kept")
        // 已經開始下一次錄音／處理就不蓋掉它的狀態。
        guard !isRecording, !isProcessing else { return }
        statusMessage = preferences.tr("已取消；沒有貼上新文字。這段話留在歷史紀錄，可以重試",
                                       "Cancelled; no new text was pasted. This dictation is kept in History and can be retried")
        notify()
    }

    private func deleteTemporaryRecording(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Groq 雲端辨識（停止錄音後與重新辨識共用同一個呼叫：同一套字典提示、同一套 TranscriptGuard）。
    private func groqTranscribe(_ pcm: Data) async -> MacCloudASR.Outcome {
        await MacCloudASR.transcribe(
            pcm16: pcm,
            language: preferences.transcriptionLanguage.rawValue,
            hotwords: asrHints(limit: 80),
            outputScript: preferences.outputScript,
            key: MacCloudASR.key(),
            taiwanFixes: preferences.effectiveLanguageVariant.appliesTaiwanFixes)
    }

    /// 重新辨識存下來的錄音（delivery-learning-1）：跟停止錄音後同一個順序——Groq（.caf 用錄音時同一條整流＋
    /// 轉換鏈轉成 16 kHz PCM）→ 本機 Qwen（直接讀 .caf）。不用 Apple 語音預覽（它只在錄音當下有）。
    private func transcribeRecording(at url: URL) async -> (text: String?, failure: String?) {
        if let recordingTranscriber { return await recordingTranscriber(url) }
        guard preferences.isolation == nil else {
            return (nil, preferences.tr("隔離模式不辨識", "Isolated mode does not transcribe"))
        }
        var failure: String?
        if groqASRActive {
            let channel = preferences.inputChannel
            do {
                let pcm = try await Task.detached(priority: .userInitiated) {
                    try AudioCaptureSession.pcm16Mono16k(fromRecording: url, inputChannel: channel)
                }.value
                switch await groqTranscribe(pcm) {
                case .ok(let text): return (text, nil)
                case .skipped(let why), .failed(let why):
                    failure = preferences.tr("Groq 雲端辨識沒有結果（\(why)）", "Groq cloud transcription returned nothing (\(why))")
                }
            } catch {
                failure = error.localizedDescription
            }
        }
        if !preferences.localASRCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do {
                let text = try await localASRClient().transcribe(audioURL: url)
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return (text, nil) }
            } catch {
                failure = error.localizedDescription
            }
        }
        return (nil, failure ?? noTranscriptMessage)
    }

    // MARK: - 選字白話解釋／翻譯（2026-10-19，帶進 UTUVO Explain）

    /// 選好文字按快捷鍵：不錄音，直接把選取文字送整理服務，答案出現在回答卡（翻譯可插回原處取代選取）。
    func explainSelectionPressed(_ action: ExplainSelection) {
        guard !isRecording, !isProcessing else { return }
        guard AccessibilitySupport.isTrusted() else {
            fail(preferences.tr("要先在「系統設定 → 隱私權與安全性 → 輔助使用」允許 UTUVO Type，才讀得到選取的文字",
                                "Allow UTUVO Type in System Settings → Privacy & Security → Accessibility to read the selection"))
            return
        }
        // modes-3：Electron／Chromium 的 App 剛打開 AXManualAccessibility，樹還沒建好——稍等再讀一次。
        if ChromiumAccessibility.shared.enableForFrontmostApp() {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                self?.explainSelectionPressed(action)
            }
            return
        }
        let context = captureContext(false, preferences.contextBlockedSites)
        // context-awareness-v2：網站被擋（在清單上／網址讀不到）要講原因，不是叫使用者「先選取一段文字」。
        if let problem = explainSelectionProblem(context, action: action) {
            fail(problem)
            return
        }
        let selected = context.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let provider = SmartCleanup.Provider(rawValue: preferences.cleanupProvider.rawValue) ?? .groq
        let key = SmartCleanup.key(for: provider)
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fail(preferences.tr("白話解釋／翻譯要用你的整理服務 key：到設定 → 智慧整理填一把 key",
                                "Explain / Translate uses your cleanup key: add one in Settings → Smart Cleanup"))
            return
        }
        let truncated = selected.count > ExplainSelection.maxCharacters
        let text = truncated ? String(selected.prefix(ExplainSelection.maxCharacters)) : selected
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let element = AccessibilitySupport.focusedElement()
        let range = element.flatMap(AccessibilitySupport.selectedRange(of:))
        AnswerCardController.shared.close()
        statusMessage = preferences.tr("\(action.cardTitle(zh: true))中…", "\(action.cardTitle(zh: false))…")
        notify()
        let zh = preferences.isChineseUI
        Task { [weak self] in
            guard let self else { return }
            let answer: String
            do {
                answer = try await SmartCleanup.ask(
                    system: action.systemPrompt(for: text), user: ExplainSelection.userMessage(text), provider: provider, key: key,
                    customEndpoint: provider == .dashscope ? self.preferences.bailianFormatterEndpoint : self.preferences.customCleanupEndpoint,
                    customModel: self.preferences.customCleanupModel,
                    transport: StrictCleanupSession.shared).trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                self.fail(self.preferences.tr("\(action.cardTitle(zh: true))沒有完成：\(error.localizedDescription)",
                                              "\(action.cardTitle(zh: false)) didn't finish: \(error.localizedDescription)"))
                return
            }
            guard !answer.isEmpty else { self.fail(self.preferences.tr("服務沒有回傳內容", "The service returned nothing")); return }
            // modes-6：卡片畫 Markdown；複製／插入用純文字。
            let plain = AnswerText.plain(answer)
            self.lastOutput = plain
            self.statusMessage = self.preferences.tr("已顯示\(action.cardTitle(zh: true))", "\(action.cardTitle(zh: false)) shown")
            self.notify()
            let preview = String(text.prefix(80)) + (text.count > 80 || truncated ? "…" : "")
            // 翻譯可以「插入」＝回原 App、選取還在就取代它；解釋只提供複製。
            let insert: (() -> Void)? = action == .translate ? { [weak self] in
                guard let self, let pid, let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(plain, forType: .string); return
                }
                app.activate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    let current = AccessibilitySupport.focusedElement()
                    guard let element, let current, CFEqual(element, current),
                          let range, let now = AccessibilitySupport.selectedRange(of: current),
                          now.location == range.location, now.length == range.length else {
                        self.writeClipboard(plain)
                        self.statusMessage = self.preferences.tr("選取已改變；譯文已複製", "Selection changed; translation copied")
                        self.notify()
                        return
                    }
                    try? ClipboardPaster.paste(plain, method: self.preferences.pasteMethod, handling: self.preferences.clipboardHandling)
                }
            } : nil
            AnswerCardController.shared.show(.init(
                question: "\(action.cardTitle(zh: zh))：\(preview)", answer: answer, zh: zh, onInsert: insert))
        }
    }

    // MARK: - Ask anything（2026-10-13，對齊 Typeless）

    /// Ask anything 快捷鍵：按一下開始講、再按一下送出。有選取文字＝對它下指令（改寫或問問題）。
    func askShortcutPressed() {
        if isRecording {
            if askActive { stopRecording() }
            return
        }
        guard !isProcessing else { return }
        // modes-3：Electron／Chromium 的 App 剛打開 AXManualAccessibility，樹還沒建好——稍等再開始（只有第一次）。
        if AccessibilitySupport.isTrusted(), ChromiumAccessibility.shared.enableForFrontmostApp() {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                self?.askShortcutPressed()
            }
            return
        }
        AnswerCardController.shared.close()
        askActive = true
        askPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let askContext = AccessibilitySupport.isTrusted()
            ? AccessibilitySupport.readCurrentContext(blockedSites: preferences.contextBlockedSites)
            : nil
        let selected = askContext?.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines)
        // context-awareness-v2：選取被擋（清單上／網址讀不到）時照樣可以問，但回答後要講清楚沒讀選取。
        askBlockNote = askContext.flatMap(selectionBlockedMessage)
        askElement = AccessibilitySupport.focusedElement()
        askRange = askElement.flatMap(AccessibilitySupport.selectedRange(of:))
        askEditable = askElement.map(Self.isEditable) ?? false
        askSelection = (selected?.isEmpty ?? true) ? nil : selected
        activeTranslationTarget = .off
        // 按住說話模式下 Ask 仍是「按一下開始、再按一下送出」：標成 active，beginRecording 才不會立刻停。
        if preferences.pushToTalkEnabled { pushToTalkActive = true }
        // 錄音本身照一般聽寫；不改使用者的預設模式。改選取模式要求先有選取，這裡不需要。
        startRecording(mode: preferences.mode == .editSelection ? .fast : preferences.mode, persistMode: false)
        if !isRecording && !isProcessing && lastErrorMessage != nil { askActive = false }
    }

    private func handleAsk(transcript: String, duration: TimeInterval, historyID: UUID,
                           audioPath: String?, token: UUID) async {
        let selection = askSelection
        askSelection = nil
        let editable = askEditable
        let provider = SmartCleanup.Provider(rawValue: preferences.cleanupProvider.rawValue) ?? .groq
        let key = SmartCleanup.key(for: provider)
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fail(preferences.tr("Ask anything 要用你的整理服務 key：到設定 → 雲端（選配）填一把 Groq／Gemini／百鍊 key",
                                "Ask anything uses your cleanup key: add a Groq / Gemini / Bailian key in Settings → Cloud"))
            return
        }
        statusMessage = preferences.tr("思考中…", "Thinking…")
        notify()
        let hasSelection = selection != nil
        let system = AskAnything.systemPrompt(hasSelection: hasSelection,
                                              languageHint: preferences.transcriptionLanguage.rawValue)
        let user = AskAnything.userMessage(instruction: transcript, selection: selection)
        let reply: AskAnything.Reply
        /// 模型要改寫，但選取的文字不能編輯（modes-4）：改放回答卡。
        var readOnlyRewrite = false
        do {
            let raw = try await SmartCleanup.ask(
                system: system, user: user, provider: provider, key: key,
                customEndpoint: provider == .dashscope ? preferences.bailianFormatterEndpoint : preferences.customCleanupEndpoint,
                customModel: preferences.customCleanupModel,
                transport: StrictCleanupSession.shared)
            guard let parsed = AskAnything.parse(raw, hasSelection: hasSelection, editable: editable) else {
                throw SmartCleanup.Failure.malformed
            }
            readOnlyRewrite = !editable && AskAnything.parse(raw, hasSelection: hasSelection)?.action == .replace
            reply = parsed
        } catch {
            guard token == operationToken else { return }
            fail(preferences.tr("Ask anything 沒有完成：\(error.localizedDescription)",
                                "Ask anything didn't finish: \(error.localizedDescription)"))
            return
        }
        guard token == operationToken else { return }
        // 回答常帶 Markdown（modes-6）：卡片畫粗體；複製、插入、取代、歷史一律用拿掉 ** 和 # 的純文字。
        let plain = AnswerText.plain(reply.text)
        lastOutput = plain
        preferences.appendHistory(HistoryRecord(id: historyID, rawTranscript: transcript, output: plain,
            duration: duration, mode: activeMode, appName: NSWorkspace.shared.frontmostApplication?.localizedName,
            bundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier, audioPath: audioPath,
            note: HistoryRecord.askAnythingNote), countsTowardStats: false)
        if reply.action == .replace, let selection, stillAtAskField(expectSelection: selection) {
            do {
                try ClipboardPaster.paste(plain, method: preferences.pasteMethod, handling: preferences.clipboardHandling)
                statusMessage = preferences.tr("已改寫選取文字", "Rewrote the selection")
            } catch {
                statusMessage = preferences.tr("改寫好了但貼不回去；可從選單複製", "Rewritten, but couldn't paste; copy it from the menu")
            }
            notify()
            return
        }
        let pid = askPID
        AnswerCardController.shared.show(.init(
            question: transcript, answer: reply.text, zh: preferences.isChineseUI,
            onInsert: { [weak self] in
                guard let self else { return }
                // 只插回原本問問題的那個 App；它關掉了或切不回去，就改成複製（luna-review r1：答案曾可能貼進別的 App）。
                guard let pid, let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
                    self.writeClipboard(plain)
                    self.statusMessage = self.preferences.tr("原本的 App 已關閉；答案已複製", "The original app is gone; the answer was copied")
                    self.notify()
                    return
                }
                app.activate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    guard self.askPID == pid, self.stillAtAskField() else {
                        self.writeClipboard(plain)
                        self.statusMessage = self.preferences.tr("切不回原本的輸入欄位；答案已複製", "Couldn't return to the original field; the answer was copied")
                        self.notify()
                        return
                    }
                    try? ClipboardPaster.paste(plain, method: self.preferences.pasteMethod,
                                               handling: self.preferences.clipboardHandling)
                }
            }))
        statusMessage = readOnlyRewrite
            ? preferences.tr("選取的文字不能直接修改；改寫結果在回答卡，可複製",
                             "The selected text can't be edited in place; the rewrite is on the card to copy")
            : preferences.tr("已回答（回答卡）", "Answered (see the card)")
        if let note = askBlockNote { statusMessage += preferences.tr("。", ". ") + note }
        askBlockNote = nil
        notify()
    }

    // MARK: - 選取被擋的原因（context-awareness-v2）

    /// 選取文字沒讀的原因要講對：網址讀得到而且在清單上，還是網址讀不到（有清單時為了安全一律先擋）。
    func selectionBlockedMessage(_ context: LimitedAppContext) -> String? {
        guard context.contextBlocked else { return nil }
        switch context.contextBlockReason {
        case .unverifiable:
            return preferences.tr(
                "讀不到這個網頁的網址，為了安全沒有讀取選取文字（設定 → 進階的「不讀脈絡的網站」有內容時會這樣擋）",
                "Couldn't read this page's address, so the selection wasn't read to be safe (this happens while Settings → Advanced → “Sites that never share context” has entries)")
        case .listed, nil:
            return preferences.tr(
                "這個網站在「不讀脈絡的網站」清單裡；沒有讀取選取文字",
                "This site is on your “never share context” list; the selection was not read")
        }
    }

    /// Edit Selection 開始前的檢查：被擋 → 講原因；沒有選取 → 沒有可改的文字。nil＝可以開始。
    func editSelectionProblem(_ context: LimitedAppContext) -> String? {
        if let blocked = selectionBlockedMessage(context) { return blocked }
        // 只讀得到前 12000 字：改寫前段再貼回去會蓋掉後面的字；以前要等講完才在卡片上說「選取已經改變」（審查 10-22）。
        if context.selectedTextTruncated == true {
            let limit = ContextBounds.selectedTextLimit
            return preferences.tr("選取的文字太長（超過 \(limit) 字），沒有改寫；請選短一點再試",
                                  "The selection is too long (over \(limit) characters) and wasn't edited; select less text and try again")
        }
        guard (context.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty else { return nil }
        return preferences.tr("目前 App 沒有可讀取的選取文字；未替換任何內容",
                              "The current app has no readable selected text; nothing was replaced")
    }

    /// 白話解釋／翻譯選取開始前的檢查（同上）。
    func explainSelectionProblem(_ context: LimitedAppContext, action: ExplainSelection) -> String? {
        if let blocked = selectionBlockedMessage(context) { return blocked }
        guard (context.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty else { return nil }
        return preferences.tr("先選取一段文字，再按\(action.cardTitle(zh: true))快捷鍵",
                              "Select some text first, then press the \(action.cardTitle(zh: false)) shortcut")
    }

    // MARK: - 接續上一段（context-awareness-2）

    /// 上一段（同一個 App、同一個欄位、游標停在它結尾）送出的文字與被拿掉的句尾標點；改選取不接續。
    private func continuationPrevious() -> (text: String, mark: String?)? {
        guard activeMode != .editSelection else { return nil }
        return continuation.previous(pid: capturedPID, at: destination)
    }

    /// - `target`：這段實際送進的目的地（記欄位與送完後的游標位置）；nil＝不知道＝下一段不接續。
    /// - `payload`：實際寫進欄位的完整字串（含補的前綴與結尾空白），算游標停在哪。
    private func rememberDelivered(_ text: String, droppedMark: String, target: (any DictationDestination)?, payload: String) {
        guard activeMode != .editSelection else { forgetDelivered(); return }
        continuation.remember(pid: capturedPID, text: text, droppedMark: droppedMark, at: target, payload: payload)
    }

    private func forgetDelivered() {
        continuation.forget()
    }

    /// `SentenceMood.finish` 這次拿掉的句尾標點（句尾語氣規則不適用的語言什麼都不拿）。
    private func finishDroppedMark(_ text: String) -> String {
        moodApplies ? SentenceMood.finishDroppedMark(text) : ""
    }

    /// 讀走並歸零本次翻譯目標：只有「這一次錄音」消費得到，
    /// reprocess 永遠拿 .off（F1：殘留目標會把重跑結果偷翻譯）；歷史重試用那筆紀錄存的目標（FX-4），不讀這裡。
    private func consumeTranslationTarget() -> TranslationTarget {
        let target = activeTranslationTarget
        activeTranslationTarget = .off
        return target
    }

    /// 投遞要用的 App 脈絡：改選取模式讀到的 → 開始聽寫當下抓的（同一個 token，context-awareness-v1）→ 現在讀。
    private func deliveryContext() -> LimitedAppContext {
        if let selectedContext { return selectedContext }
        if let captured = capturedContext, captured.token == operationToken { return captured.context }
        return captureContext(preferences.includeSurroundingContext, preferences.contextBlockedSites)
    }

    private func normalizedForDelivery(_ transcript: String, dictionary: [String: String]) -> String {
        Normalizer(options: NormalizerOptions(dictionary: dictionary, latinTerms: deliveryLatinTerms(dictionary)))
            .normalize(transcript).cleaned
    }

    /// 本機整理版的英文專名比對目標：個人字典的寫法 + 產品名 + 已開內建包的修正詞 + 已開 catalog 包的拉丁字母 seeds。
    /// 智慧整理後補套用同一份來源、少掉單字的包內詞（`applyingVocabulary`）。
    private func deliveryLatinTerms(_ dictionary: [String: String]) -> [String] {
        VocabularyPacks.latinTermsForFixer(personal: dictionary, enabled: preferences.enabledVocabularyPackIDs)
    }

    /// asr-vocab-2：智慧整理（雲端或本機 editor）通過把關之後、送出之前，補套使用者的「英文專名＋個人字典」
    /// （Claude 把「DAMI music」寫成「Darmy Music」、「UTUVO Type」寫成「Utuvo Type」）。字典跟本機整理版同一份；
    /// 英文專名用同一份來源，但詞庫包只留多字詞（`VocabularyPacks.latinTermsForCleanedText`）——模型寫對的英文不能被改掉。
    /// 只跑那兩關、冪等：已經寫對的一個字都不動，整理好的格式也不動。
    func applyingVocabulary(_ cleaned: String, dictionary: [String: String]) -> String {
        Normalizer.applyVocabulary(cleaned, dictionary: dictionary,
                                   latinTerms: VocabularyPacks.latinTermsForCleanedText(personal: dictionary,
                                                                                         enabled: preferences.enabledVocabularyPackIDs))
    }

    /// 先貼的本機版也照句尾語氣。
    private func deliveryOriginal(_ normalized: String) -> String {
        moodApplies ? SentenceMood.finish(normalized) : normalized
    }

    private func cleanupConfig(original: String, context: LimitedAppContext, dictionary: [String: String]) -> CleanupConfig {
        let promptContext = preferences.includeSurroundingContext
            ? CleanupPromptContext(
                appName: context.appName ?? "",
                styleHint: preferences.preset(for: context.foregroundBundleIdentifier)?.promptHint ?? "",
                surroundingText: context.surroundingText ?? "",
                textAfterCursor: context.textAfterCursor ?? "",
                windowTitle: context.windowTitle ?? "",
                pageLocation: context.pageLocation ?? "",
                fieldPlaceholder: context.fieldPlaceholder ?? ""
            )
            : .init()
        return CleanupConfig(enabled: true, provider: preferences.cleanupProvider,
            customEndpoint: preferences.customCleanupEndpoint, customModel: preferences.customCleanupModel,
            language: preferences.transcriptionLanguage.rawValue, personal: dictionary,
            enabledPacks: preferences.enabledVocabularyPackIDs, bailianEndpoint: preferences.bailianFormatterEndpoint,
            context: promptContext, validationSource: original, autoList: preferences.cleanupAutoList,
            variant: preferences.effectiveLanguageVariant)
    }

    /// 這次結果記到哪、送到哪（app-shell-v1）。
    private enum ResultSink {
        /// 一般聽寫：新增一筆歷史、送到開始聽寫的 App。reprocess 是同一段話再貼一次，不再算使用數據。
        case newEntry(countsTowardStats: Bool)
        /// 歷史重試：照 `RetryPolicy.Bookkeeping` 記帳（就地更新那一筆、不貼，結果放剪貼簿）。
        case retry(HistoryRecord, RetryPolicy.Bookkeeping)

        var countsTowardStats: Bool {
            switch self {
            case .newEntry(let counts): return counts
            case .retry(_, let bookkeeping): return bookkeeping.countsTowardStats
            }
        }
        var isRetry: Bool { if case .retry = self { return true } else { return false } }
    }

    private func formatAndPaste(
        transcript: String,
        audioDuration: TimeInterval,
        asrError: Error?,
        token: UUID,
        historyID: UUID,
        audioPath: String? = nil,
        translation: TranslationTarget = .off,
        sink: ResultSink = .newEntry(countsTowardStats: true)
    ) async {
        guard token == operationToken else { return }
        lastRawTranscript = transcript
        let context: LimitedAppContext
        if case .retry(let record, _) = sink {
            // 重試不讀現在的畫面（從設定頁按重試時那是 Type 自己）：只帶原本那筆的 App，App preset 照樣套用。
            context = LimitedAppContext(foregroundBundleIdentifier: record.bundleIdentifier, appName: record.appName)
        } else {
            context = deliveryContext()
        }
        let dictionary = preferences.dictionary
        let normalizedText = normalizedForDelivery(transcript, dictionary: dictionary)
        let combinedForFeatures = [transcript, context.selectedText ?? ""].joined(separator: "\n")
        let longTextThresholdReached = transcript.count >= max(1, preferences.deepMinCharacters)
            || audioDuration >= TimeInterval(max(1, preferences.deepMinAudioSeconds))
        let decision = Router.decide(RoutingInput(
            text: combinedForFeatures,
            mode: activeMode,
            hasListCues: InputFeatures.hasListCues(transcript),
            hasSelfCorrection: InputFeatures.hasSelfCorrection(transcript),
            hasMarkdown: InputFeatures.hasMarkdown(transcript),
            hasSelectedBlock: activeMode == .editSelection,
            highQuality: activeMode == .deep,
            deepOptIn: activeMode == .deep,
            localDeepAvailable: activeMode == .deep && !preferences.localDeepModel.isEmpty,
            longTextOptIn: longTextThresholdReached
        ))
        let editorInput = RoutingInput(
            text: transcript,
            mode: activeMode,
            hasListCues: InputFeatures.hasListCues(transcript),
            hasSelfCorrection: InputFeatures.hasSelfCorrection(transcript),
            hasMarkdown: InputFeatures.hasMarkdown(transcript)
        )
        let cloudBackgroundCleanup = preferences.cleanupEnabled && preferences.postProcessingEnabled
        let localBackgroundCleanup = !cloudBackgroundCleanup
            && preferences.postProcessingEnabled
            && preferences.backend == .local
            && activeMode == .smart
            && !decision.skipLLM
            && !Router.isShortSentence(editorInput)
            && (!preferences.localEditorCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !preferences.localEditorModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        if Self.backgroundEligible(mode: activeMode, translation: translation, autoSubmit: effectiveAutoSubmit,
                                   enabled: cloudBackgroundCleanup || localBackgroundCleanup,
                                   language: preferences.transcriptionLanguage.rawValue) {
            if sink.isRetry {
                // 重試沒有目的地可以先插入：整理（有時限）後一次寫回那一筆。
                let original = deliveryOriginal(normalizedText)
                await pasteWithoutCapture(original: original, originalMark: finishDroppedMark(normalizedText),
                                          raw: transcript, duration: audioDuration,
                                          historyID: historyID, audioPath: audioPath, token: token, context: context,
                                          dictionary: dictionary,
                                          config: cleanupConfig(original: original, context: context, dictionary: dictionary),
                                          useLocalFormatter: localBackgroundCleanup, sink: sink)
                return
            }
            await deliverImmediate(normalizedText, raw: transcript, duration: audioDuration,
                                   historyID: historyID, audioPath: audioPath, token: token, context: context,
                                   dictionary: dictionary, useLocalFormatter: localBackgroundCleanup,
                                   countsTowardStats: sink.countsTowardStats)
            return
        }
        // 語音翻譯（modes-1）：智慧整理有開而且有 key → 雲端「整理 → 翻譯」，本機 editor 那套整理就不跑
        // （新裝的 Mac 沒有那個模型，只會白跑一趟再留一句「整理服務失敗」）。
        let translationPlan = translation == .off ? nil : translationEngines()
        // 改選取的 output 是改好的選取文字，不是聽寫：照舊先跑 editor，翻譯時也不再整理逐字稿。
        let cloudTranslates = translationPlan?.engines.contains(.cloud) == true && activeMode != .editSelection
        // Edit Selection commands are often short (“改正式一點”), but the
        // selected text is the actual editing payload, so local editor use is
        // still allowed for that mode.
        let localEditorAllowed = activeMode == .editSelection
            || !Router.isShortSentence(editorInput)

        var output = normalizedText
        var formatterSucceeded = false
        var notice = asrError.map {
            preferences.tr("ASR fallback：\($0.localizedDescription)", "ASR fallback: \($0.localizedDescription)")
        }

        // modes-v1：Edit Selection 有使用者自己的整理服務（智慧整理＋key）就走雲端，不再只靠本機 editor
        //（新裝的 Mac 沒有那個模型，只會失敗）。沒有雲端才走原本的 editor。
        // 「後處理」總開關關著：選取（別人寫的螢幕內容）一個字都不送出去，也不讀 Keychain——跟聽寫的雲端整理同一個開關
        //（審查 10-22：以前只看「智慧整理」，後處理關了照樣把選取送雲端）。跟以前一樣不改寫，狀態講清楚原因。
        let editRoute = activeMode == .editSelection && preferences.postProcessingEnabled ? cloudRoute() : nil
        if activeMode == .editSelection && !preferences.postProcessingEnabled {
            notice = preferences.tr("後處理已關閉，選取文字沒有送出", "Post-processing is off; the selection was not sent")
        }
        if let editRoute {
            let selection = (context.selectedText ?? editAnchor?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if selection.isEmpty {
                notice = preferences.tr("沒有讀到選取文字", "No selected text was read")
            } else {
                statusMessage = preferences.tr("改寫選取中…", "Editing the selection…")
                notify()
                do {
                    let raw = try await cloudEditRunner(EditSelectionPrompt.system,
                                                        EditSelectionPrompt.userMessage(original: selection, instruction: transcript),
                                                        editRoute)
                    guard let safe = FormatterOutputGuard.sanitize(raw, source: transcript, mode: .editSelection) else {
                        throw SmartCleanup.Failure.malformed
                    }
                    output = safe
                    formatterSucceeded = true
                } catch {
                    notice = preferences.tr("整理服務沒有完成：\(error.localizedDescription)",
                                            "The cleanup service didn't finish: \(error.localizedDescription)")
                }
            }
        } else if preferences.postProcessingEnabled && !decision.skipLLM && !cloudTranslates {
            do {
                let prompt = try await makePrompt(transcript: transcript, context: context, dictionary: dictionary)
                if let legacyFormatterRunner {
                    let candidate = try await legacyFormatterRunner(prompt)
                    guard let safe = FormatterOutputGuard.sanitize(candidate, source: editorInput.text, mode: activeMode) else {
                        throw ProviderError.malformedResponse
                    }
                    output = safe
                    formatterSucceeded = true
                } else {
                    switch preferences.backend {
                    case .bailian:
                        let client = try BailianFormatterClient(endpointString: preferences.bailianFormatterEndpoint)
                        let models = uniqueModels(from: decision)
                        for model in models {
                            do {
                                let candidate = try await client.format(prompt: prompt, model: model.rawValue)
                                guard let safe = FormatterOutputGuard.sanitize(
                                    candidate,
                                    source: editorInput.text,
                                    mode: activeMode
                                ) else {
                                    throw ProviderError.malformedResponse
                                }
                                output = safe
                                formatterSucceeded = true
                                break
                            } catch {
                                notice = preferences.tr(
                                    "百鍊 formatter fallback：\(error.localizedDescription)",
                                    "Bailian formatter fallback: \(error.localizedDescription)"
                                )
                            }
                        }
                    case .local:
                        if activeMode == .deep,
                           decision.useLocalDeep,
                           !preferences.localDeepModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            let client = try OllamaFormatterClient(model: preferences.localDeepModel)
                            let candidate = try await client.format(prompt: prompt, model: preferences.localDeepModel)
                            guard let safe = FormatterOutputGuard.sanitize(candidate, source: editorInput.text, mode: activeMode) else {
                                throw ProviderError.malformedResponse
                            }
                            output = safe
                            formatterSucceeded = true
                        } else if !preferences.localEditorCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                  localEditorAllowed {
                            let client = LocalFormatterProcessClient(
                                command: preferences.localEditorCommand,
                                outputScript: preferences.outputScript.rawValue
                            )
                            let candidate = try await client.format(
                                prompt: prompt,
                                model: preferences.localEditorModel.isEmpty ? "local-qwen3-editor" : preferences.localEditorModel
                            )
                            guard let safe = FormatterOutputGuard.sanitize(candidate, source: editorInput.text, mode: activeMode) else {
                                throw ProviderError.malformedResponse
                            }
                            output = safe
                            formatterSucceeded = true
                        } else if !preferences.localEditorModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                  localEditorAllowed {
                            let client = try OllamaFormatterClient(model: preferences.localEditorModel)
                            let candidate = try await client.format(prompt: prompt, model: preferences.localEditorModel)
                            guard let safe = FormatterOutputGuard.sanitize(candidate, source: editorInput.text, mode: activeMode) else {
                                throw ProviderError.malformedResponse
                            }
                            output = safe
                            formatterSucceeded = true
                        } else {
                            notice = preferences.tr(
                                "本機沒有設定小型 editor，已使用 deterministic 整理",
                                "No local small editor is configured; deterministic formatting was used"
                            )
                        }
                    }
                }
            } catch {
                notice = preferences.tr(
                    "整理服務失敗，已使用 deterministic fallback：\(error.localizedDescription)",
                    "Formatting service failed; deterministic fallback was used: \(error.localizedDescription)"
                )
            }
        }

        // F5：翻譯前先驗 token——取消後的殘留 task 不准再改 statusMessage 或燒 editor。
        guard token == operationToken else { return }
        var historyNote: String?
        if translation != .off, let translationPlan {
            statusMessage = preferences.tr("翻譯中…", "Translating…")
            let outcome = await translateDictation(transcript: transcript, text: output, context: context,
                                                   dictionary: dictionary, target: translation,
                                                   engines: translationPlan.engines, cloud: translationPlan.cloud,
                                                   cleanFirst: cloudTranslates, token: token)
            guard token == operationToken else { return }
            switch outcome {
            case .translated(let translated, let engine):
                output = translated
                deliveryLog.info("translation: \(engine.rawValue, privacy: .public)")
            case .failed(let source, let triedCloud):
                // FX-4：重試時翻不出來，這筆原本有結果（之前翻好的譯文）就留著，不拿原文蓋掉；原因照樣寫，
                // 只是結尾照實講「保留原本的譯文」（重試不貼上，也沒有輸出原文）。
                var keptPrevious = false
                if case .retry(let record, _) = sink, !record.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    output = record.output
                    keptPrevious = true
                } else {
                    output = source
                }
                let outcomeZh = keptPrevious ? "保留這筆原本的譯文" : "已輸出原文"
                let outcomeEn = keptPrevious ? "this entry's previous translation was kept" : "the original text was pasted"
                if triedCloud {
                    notice = preferences.tr("翻譯未完成（整理服務沒有回應），\(outcomeZh)",
                                            "Translation did not complete (the cleanup service didn't respond); \(outcomeEn)")
                } else if translationPlan.engines.contains(.localEditor) {
                    notice = preferences.tr("翻譯未完成（本機 editor 沒有回應），\(outcomeZh)",
                                            "Translation did not complete (the local editor didn't respond); \(outcomeEn)")
                } else {
                    notice = preferences.tr("翻譯未完成：沒有可用的翻譯方式（到設定開啟智慧整理並填 key，或在系統設定安裝翻譯語言），\(outcomeZh)",
                                            "Translation did not complete: no translator is available (turn on Smart Cleanup with a key, or install the language in System Settings); \(outcomeEn)")
                }
                historyNote = notice
            }
        }

        guard token == operationToken else { return }

        // 句尾語氣（2026-10-02 Micky：不要每句都句號）：問句／感嘆改標點、最後一句不加句號。
        // 翻譯（日文也用「。」）與改選取（取代使用者原文）不動。
        var droppedMark = ""
        if translation == .off && activeMode != .editSelection && moodApplies {
            droppedMark = SentenceMood.finishDroppedMark(output)
            output = SentenceMood.finish(output)
        }

        lastOutput = output

        guard commitResult(output: output, raw: transcript, duration: audioDuration, historyID: historyID,
                           audioPath: audioPath, context: context, note: historyNote, translation: translation,
                           sink: sink) else { return }

        if activeMode == .editSelection && !formatterSucceeded {
            // Never replace a user's selected text with the spoken command
            // when an editor provider fails. The selected text remains intact.
            statusMessage = preferences.tr(
                "Edit Selection 未完成；原選取文字未變更。\(notice ?? "請稍後重試")",
                "Edit Selection did not complete; the original selection is unchanged. \(notice ?? "Please try again later")"
            )
            lastErrorMessage = notice
            return
        }

        if activeMode == .editSelection {
            // modes-v1：改好的文字要貼回「開始時那段選取」。欄位不能編輯、或選取已經換了（換 App／換欄位／改選別段／
            // 選取文字被改過），就不貼——⌘V 會蓋掉別的地方或貼進空氣——結果放卡片。
            guard let anchor = editAnchor, anchor.editable else {
                keepUndelivered(output, historyID: historyID, reason: .selectionReadOnly)
                return
            }
            let stillThere = selectionStillThere?(anchor)
                ?? Self.stillAtField(pid: anchor.pid, element: anchor.element, range: anchor.range, expectSelection: anchor.text)
            guard stillThere else {
                onDeliveryEvent?("selection-changed")
                keepUndelivered(output, historyID: historyID, reason: .selectionChanged)
                return
            }
        }

        // context-awareness-2：游標前就是上一段聽寫的結尾 → 英文接英文補空白、拿掉的「，」「、」補回；中文接中文不補（永遠不補「。」）。
        // 只有開始時抓到的目的地還有效（讀得到游標前文字）才補；拿不到就什麼都不加。
        let previous = continuationPrevious()
        let joinPrefix = SentenceMood.joinPrefix(before: destination?.textBeforeCursor,
                                                 previous: previous?.text, next: output, droppedMark: previous?.mark)
        let pasteOutput = joinPrefix + (preferences.appendTrailingSpace ? output + " " : output)
        guard preferences.isolation == nil else {
            isolatedPastePayload = pasteOutput
            statusMessage = preferences.tr("目的地已變更；可複製最後結果", "Destination changed; copy the last result")
            return
        }
        let plan = deliveryPlan()
        guard plan.paste else {
            keepUndelivered(output, historyID: historyID, reason: .destinationChanged)
            return
        }
        do {
            try ClipboardPaster.paste(
                pasteOutput,
                method: preferences.pasteMethod,
                handling: preferences.clipboardHandling
            )
            lastErrorMessage = notice
            // 焦點確定不是文字欄位：⌘V 多半沒進去，也不送 Return（可能按到焦點上的按鈕）；結果放卡片上。
            if plan.showCard {
                keepUndelivered(output, historyID: historyID, reason: .notATextField)
                return
            }
            // 開始時抓到的目的地已失效（打字／點滑鼠／換焦點）＝⌘V 貼到哪不確定：不記欄位，下一段不接續。
            rememberDelivered(output, droppedMark: droppedMark,
                              target: destination?.textBeforeCursor == nil ? nil : destination, payload: pasteOutput)
            ClipboardPaster.submit(effectiveAutoSubmit)
            // 追蹤修改只看聽寫內容本身（不含補的空白／「，」：那是我們加的，不是使用者的字）。
            if activeMode != .editSelection, effectiveAutoSubmit == .off { watchEdits(output) }
            statusMessage = notice.map {
                preferences.tr("已貼上 deterministic 結果（\($0)）", "Pasted deterministic result (\($0))")
            } ?? (activeMode == .editSelection
                  ? preferences.tr("已改寫選取文字", "Rewrote the selection")
                  : preferences.tr("已整理並貼上", "Formatted and pasted"))
        } catch {
            keepUndelivered(output, historyID: historyID, reason: .pasteFailed)
            lastErrorMessage = error.localizedDescription
        }

    }

    /// 寫歷史（app-shell-v1）。回傳要不要接著送到目的地：歷史重試就地更新那一筆、結果放剪貼簿，不貼。
    private func commitResult(output: String, raw: String, duration: TimeInterval, historyID: UUID,
                              audioPath: String?, context: LimitedAppContext, note: String?,
                              translation: TranslationTarget = .off, sink: ResultSink) -> Bool {
        guard case .retry(let record, let bookkeeping) = sink, bookkeeping.updatesEntryInPlace else {
            preferences.appendHistory(HistoryRecord(id: historyID, rawTranscript: raw, output: output,
                duration: duration, mode: activeMode, appName: context.appName,
                bundleIdentifier: context.foregroundBundleIdentifier, audioPath: audioPath, note: note,
                translation: HistoryRecord.storedTranslation(translation, mode: activeMode)),
                countsTowardStats: sink.countsTowardStats)
            return true
        }
        // 重新辨識時連逐字稿一起換；有結果＝這筆完成了，失敗／取消的狀態清掉（delivery-learning-1）。
        preferences.replaceHistoryEntry(id: record.id, output: output, note: note,
                                        rawTranscript: raw == record.rawTranscript ? nil : raw,
                                        countsTowardStats: bookkeeping.countsTowardStats)
        if bookkeeping.pastesIntoFrontmostApp { return true }
        writeClipboard(output)
        retriedHistoryID = record.id
        statusMessage = preferences.tr("已更新這筆紀錄，結果已複製", "Entry updated; the result was copied")
        onDeliveryEvent?("retry-updated")
        return false
    }

    /// 這次要不要貼、要不要另外跳結果卡（delivery-learning-2；規則在 core 的 DeliveryTarget）。
    private func deliveryPlan() -> DeliveryTarget.Plan {
        let changed = capturedPID != nil && NSWorkspace.shared.frontmostApplication?.processIdentifier != capturedPID
        return DeliveryTarget.plan(destinationChanged: changed,
                                   focus: changed ? .unknown : DeliveryTarget.classify(AccessibilitySupport.deliveryFocus()))
    }

    private enum UndeliveredReason: String { case destinationChanged, pasteFailed, notATextField, selectionChanged, selectionReadOnly }

    /// 結果沒送進輸入欄位時不能默默弄丟（delivery-learning-2）：狀態講清楚、歷史那筆標原因、
    /// 跳出結果卡（文字＋複製／貼到目前位置）。只有按「複製」才會動剪貼簿。
    private func keepUndelivered(_ text: String, historyID: UUID, reason: UndeliveredReason) {
        let status: String
        let note: String
        switch reason {
        case .destinationChanged:
            status = preferences.tr("目的地已變更，沒有貼上；結果在卡片上，可複製或貼到目前位置",
                                    "The destination changed, so nothing was pasted; the result is on the card to copy or insert")
            note = preferences.tr("未送達：目的地已變更", "Not delivered: the destination changed")
        case .pasteFailed:
            status = preferences.tr("貼上失敗；結果在卡片上，可複製或貼到目前位置",
                                    "Paste failed; the result is on the card to copy or insert")
            note = preferences.tr("未送達：貼上失敗", "Not delivered: paste failed")
        case .notATextField:
            status = preferences.tr("目前的焦點不是輸入欄位，可能沒有貼進去；結果在卡片上",
                                    "The focus isn't a text field, so the text may not have landed; the result is on the card")
            note = preferences.tr("可能未送達：焦點不是輸入欄位", "Possibly not delivered: the focus wasn't a text field")
        case .selectionChanged:
            status = preferences.tr("選取已經改變（換了 App、欄位或選取範圍），沒有取代；改寫結果在卡片上",
                                    "The selection changed (app, field or range), so nothing was replaced; the rewrite is on the card")
            note = preferences.tr("未送達：選取已改變", "Not delivered: the selection changed")
        case .selectionReadOnly:
            status = preferences.tr("選取的文字不能直接修改，沒有取代；改寫結果在卡片上，可複製",
                                    "The selected text can't be edited in place, so nothing was replaced; the rewrite is on the card to copy")
            note = preferences.tr("未送達：選取的文字不能編輯", "Not delivered: the selection isn't editable")
        }
        forgetDelivered()
        statusMessage = status
        preferences.setHistoryNote(id: historyID, note: note)
        deliveryLog.error("delivery: \(reason.rawValue, privacy: .public); result kept on the card")
        onDeliveryEvent?("undelivered")
        notify()
        guard preferences.isolation == nil else { return }   // 測試不開視窗
        AnswerCardController.shared.show(.init(
            question: status, answer: text, zh: preferences.isChineseUI,
            onInsert: { [weak self] in
                // 卡片不搶焦點：貼到「按下去當下」的輸入位置。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    guard let self else { return }
                    try? ClipboardPaster.paste(text, method: self.preferences.pasteMethod,
                                               handling: self.preferences.clipboardHandling)
                }
            },
            rendersMarkdown: false,
            insertLabel: preferences.tr("貼到目前位置", "Insert here")))
    }

    /// 語音翻譯要試的方法與雲端設定（modes-1）。智慧整理沒開就不讀 Keychain。
    private func translationEngines() -> (engines: [DictationTranslation.Engine], cloud: DictationTranslation.CloudRoute?) {
        let route = cloudRoute()
        let editorUsable = localEditorTranslationRunner != nil
            ? !preferences.localEditorCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            : DictationTranslation.localEditorUsable(command: preferences.localEditorCommand,
                                                     bundledWrapperPath: LocalEditorPrewarmer.bundledWrapperPath(),
                                                     bundledModelExists: LocalEditorPrewarmer.bundledModelExists())
        let engines = DictationTranslation.engines(cleanupEnabled: preferences.cleanupEnabled, hasKey: route != nil,
                                                   localEditorUsable: editorUsable)
        return (engines, route)
    }

    /// 使用者自己的整理服務（智慧整理開著而且有 key）；沒開就不讀 Keychain。語音翻譯（modes-1）與 Edit Selection（modes-v1）共用。
    private func cloudRoute() -> DictationTranslation.CloudRoute? {
        guard preferences.cleanupEnabled,
              let provider = SmartCleanup.Provider(rawValue: preferences.cleanupProvider.rawValue) else { return nil }
        let key = cleanupKeyLookup(provider).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        return .init(provider: provider, key: key,
                     customEndpoint: provider == .dashscope ? preferences.bailianFormatterEndpoint
                                                            : preferences.customCleanupEndpoint,
                     customModel: preferences.customCleanupModel)
    }

    private enum TranslationOutcome {
        case translated(String, DictationTranslation.Engine)
        /// 全部失敗：`source` 是要改貼的原文（雲端整理過就是整理版）。
        case failed(source: String, triedCloud: Bool)
    }

    /// 語音翻譯（modes-1）：照 `engines` 的順序試，第一個成功的就用。
    private func translateDictation(transcript: String, text: String, context: LimitedAppContext,
                                    dictionary: [String: String], target: TranslationTarget,
                                    engines: [DictationTranslation.Engine], cloud: DictationTranslation.CloudRoute?,
                                    cleanFirst: Bool, token: UUID) async -> TranslationOutcome {
        var source = text
        for engine in engines {
            guard token == operationToken else { break }
            switch engine {
            case .cloud:
                guard let cloud else { continue }
                // 第一步：照聽寫一樣整理，同一道忠實度把關；被擋或失敗就用本機整理版。譯文本身不過把關。
                if cleanFirst {
                    source = await cleanedForTranslation(transcript, original: text, context: context, dictionary: dictionary)
                }
                guard token == operationToken else { break }
                let names = DictationTranslation.promptNames(target)
                let system = TranslatePrompt.system(targetZh: names.zh, targetEn: names.en)
                if let raw = try? await cloudTranslationRunner(system, source, cloud) {
                    let translated = TranslatePrompt.cleanOutput(raw)
                    if !translated.isEmpty { return .translated(translated, .cloud) }
                }
            case .system:
                if let translated = await systemTranslationRunner(source, preferences.transcriptionLanguage.rawValue,
                                                                  target.rawValue) {
                    return .translated(translated, .system)
                }
            case .localEditor:
                if let translated = await translateOutput(source, target: target) {
                    return .translated(translated, .localEditor)
                }
            }
        }
        return .failed(source: source, triedCloud: engines.contains(.cloud))
    }

    /// 翻譯的第一步：整理（同 `pasteWithoutCapture` 的把關：數字寫法先對齊，Claude 用寬鬆把關）。
    private func cleanedForTranslation(_ transcript: String, original: String, context: LimitedAppContext,
                                       dictionary: [String: String]) async -> String {
        let config = cleanupConfig(original: original, context: context, dictionary: dictionary)
        guard let checked = await cleanupRunner(transcript, config).map(Normalizer.normalizeNumbers),
              SmartCleanup.accepts(original: original, cleaned: checked, relaxed: config.provider == .claude) else {
            return original
        }
        return applyingVocabulary(checked, dictionary: dictionary)
    }

    static func backgroundEligible(mode: FormatterMode, translation: TranslationTarget, autoSubmit: AutoSubmit, enabled: Bool, language: String) -> Bool {
        enabled && mode == .smart && translation == .off && autoSubmit == .off && SmartCleanup.supportsLanguage(language)
    }

    func prepareDictation(mode: FormatterMode, expectedPID: Int32? = nil) {
        invalidateBackground()
        editAnchor = nil
        activeMode = mode
        capturedPID = expectedPID ?? (preferences.isolation == nil ? NSWorkspace.shared.frontmostApplication?.processIdentifier : nil)
        destination = captureDestination(capturedPID)
        // context-awareness-v1：脈絡跟目的地同一刻抓（Typeless 也是開始時抓），不是 ASR 結束後才讀。
        capturedContext = (operationToken, captureContext(preferences.includeSurroundingContext,
                                                          preferences.contextBlockedSites))
        onDeliveryEvent?(destination == nil ? "refused" : "capture")
    }

    private func invalidateBackground() {
        operationToken = UUID()
        capturedContext = nil
        speculation?.asr.cancel(); speculation?.cleanup?.task.cancel(); speculation = nil
        pendingCleanupTask?.cancel(); pendingCleanupTask = nil
        destination?.invalidate(); destination = nil
    }

    /// Test/QA entry: same production formatting and delivery, never records audio.
    func completeSyntheticDictation(_ text: String, translation: TranslationTarget = .off) async {
        guard preferences.isolation != nil else { return }
        await formatAndPaste(transcript: text, audioDuration: 0, asrError: nil,
                             token: operationToken, historyID: UUID(), translation: translation)
    }

    /// Test/QA entry（delivery-learning-1／app-shell-3）：從「錄音已停、辨識中」開始跑正式的收尾——失敗紀錄、
    /// 取消紀錄、靜音刪檔、孤兒錄音。`transcribe` 代替真的辨識；在裡面呼叫 `cancelProcessing()` 就是「辨識途中取消」。
    /// 只在隔離模式有作用；不開麥克風。`audioURL` 是暫存錄音，跟正式路徑一樣收尾後會被搬走或刪掉。
    func completeSyntheticCapture(audioURL: URL, duration: TimeInterval, soundsSilent: Bool = false,
                                  transcribe: @MainActor () async -> (text: String, error: Error?)) async {
        guard preferences.isolation != nil else { return }
        isProcessing = true
        let token = operationToken
        let origin = captureOrigin()
        let (text, error) = await transcribe()
        await concludeCapture(CapturedAudio(audioURL: audioURL, transcript: text, asrError: error, duration: duration,
                                            soundsSilent: soundsSilent, peakDBFS: soundsSilent ? -60 : -12,
                                            micName: "Synthetic", origin: origin), token: token)
        if token == operationToken { isProcessing = false; notify() }
    }

    /// 測試等歷史重試跑完。
    func waitForHistoryRetry() async { await historyRetryTask?.value }

    func waitForBackgroundCleanup() async { await pendingCleanupTask?.value }

    /// Read-only update barrier; a new dictation invalidates the earlier idle check.
    func readyForUpdateRestart() async -> Bool {
        let turn = operationToken
        await pendingCleanupTask?.value
        return turn == operationToken && !isRecording && !isProcessing
    }

    /// 句尾語氣規則是中文／英文的（日文也用「。」、也有「誰」這類字）：其他轉錄語言、以及「自動偵測」
    /// （可能偵測成任何語言）照原樣。
    private var moodApplies: Bool {
        [.traditionalChinese, .english].contains(preferences.transcriptionLanguage)
    }

    private func deliverImmediate(_ original: String, raw: String, duration: TimeInterval,
                                  historyID: UUID, audioPath: String?, token: UUID, context: LimitedAppContext,
                                  dictionary: [String: String], useLocalFormatter: Bool,
                                  countsTowardStats: Bool = true) async {
        let (original, originalMark) = (deliveryOriginal(original), finishDroppedMark(original))
        let trailing = preferences.appendTrailingSpace ? " " : ""
        let config = cleanupConfig(original: original, context: context, dictionary: dictionary)
        let presented = config.autoList ? OutputShape.expandingInlineNumberedList(original) : original
        guard token == operationToken else { return }
        let lateCheck = destination
        // context-awareness-2：游標前就是上一段的結尾 → 先補空白／拿掉的「，」（不補「。」）。插入、事後替換、晚到檢查都算同一個前綴；
        // 歷史、最後結果、修改追蹤只記聽寫內容本身。
        let before = destination?.textBeforeCursor
        let previous = continuationPrevious()
        let prefix = SentenceMood.joinPrefix(before: before, previous: previous?.text, next: presented,
                                             droppedMark: previous?.mark)
        guard let target = destination, await target.insert(prefix + presented + trailing) else {
            // 2026-09-24 實機（苑涵 0.1.5）：Chrome／LINE／Electron 等欄位不是原生 AX 文字框，或錄音中按了鍵／點了滑鼠，
            // 這裡原本直接 return——不貼字、不寫歷史。改成跟 Fast 一樣走剪貼簿貼上（仍檢查前景 App 沒換）；
            // 貼之前先在同一個時限內整理，能整理就貼整理版，否則貼本機整理版。
            await pasteWithoutCapture(original: original, originalMark: originalMark, raw: raw, duration: duration,
                                      historyID: historyID,
                                      audioPath: audioPath, token: token, context: context, dictionary: dictionary,
                                      config: config, useLocalFormatter: useLocalFormatter,
                                      sink: .newEntry(countsTowardStats: countsTowardStats),
                                      latePayload: prefix + presented + trailing,
                                      alreadyDelivered: { lateCheck?.textPresent(prefix + presented + trailing) ?? false })
            return
        }
        guard token == operationToken else { return }
        rememberDelivered(presented, droppedMark: originalMark, target: target, payload: prefix + presented + trailing)
        lastOutput = presented
        preferences.appendHistory(HistoryRecord(id: historyID, rawTranscript: raw, output: presented,
            duration: duration, mode: activeMode, appName: context.appName,
            bundleIdentifier: context.foregroundBundleIdentifier, audioPath: audioPath),
            countsTowardStats: countsTowardStats)
        isProcessing = false
        statusMessage = preferences.tr("已貼上", "Inserted")
        logDeliveryTiming("ax-insert")
        watchEdits(presented)
        onDeliveryEvent?("inserted")
        notify()
        guard target.supportsCorrection else { onDeliveryEvent?("refused"); target.invalidate(); return }
        let run = useLocalFormatter ? nil : cleanupWork(raw: raw, config: config)
        let localRun = localBackgroundRunner
        pendingCleanupTask = Task { [weak self] in
            let cleaned: String?
            if useLocalFormatter {
                cleaned = await SmartCleanup.withinDeadline { [weak self] in
                    if let localRun { return await localRun(raw, context, dictionary) }
                    guard let self else { return nil }
                    return await self.localBackgroundCleanup(raw, context: context, dictionary: dictionary)
                }
            } else {
                cleaned = await run?()
            }
            guard let self else { target.invalidate(); return }
            // 整理模型讀的是原始逐字稿（「三點」），先貼出的版本已轉成「3點」：數字格式先對齊，否則把關會把整段擋掉。
            guard !Task.isCancelled, token == self.operationToken, !self.isRecording,
                  let checked = cleaned.map(Normalizer.normalizeNumbers),
                  SmartCleanup.accepts(original: original, cleaned: checked,
                                       relaxed: !useLocalFormatter && config.provider == .claude),
                  case let named = self.applyingVocabulary(checked, dictionary: dictionary),
                  case let listed = config.autoList ? OutputShape.expandingInlineNumberedList(named) : named,
                  case let cleaned = self.moodApplies ? SentenceMood.finish(listed) : listed,
                  case let cleanedPrefix = prefix.isEmpty ? ""
                      : SentenceMood.joinPrefix(before: before, previous: previous?.text, next: cleaned,
                                                droppedMark: previous?.mark),
                  target.replaceInsertedText(with: cleanedPrefix + cleaned + trailing) else {
                target.invalidate()
                if token == self.operationToken { self.onDeliveryEvent?("refused") }
                return
            }
            self.lastOutput = cleaned
            self.rememberDelivered(cleaned, droppedMark: self.finishDroppedMark(named), target: target,
                                   payload: cleanedPrefix + cleaned + trailing)
            self.watchEdits(cleaned)   // 背景整理換字後，追蹤的是換過的版本
            self.preferences.replaceHistoryOutput(id: historyID, with: cleaned)
            self.statusMessage = self.preferences.tr("背景整理已套用", "Background cleanup applied")
            self.onDeliveryEvent?("applied")
            self.notify()
        }
    }

    private func logDeliveryTiming(_ path: String) {
        guard let stopPressedAt else { return }
        let total = Int(Date().timeIntervalSince(stopPressedAt) * 1000)
        deliveryLog.info("timing: delivered[\(path, privacy: .public)] \(total, privacy: .public) ms after stop")
    }

    /// Smart 模式的目的地不能安全插入／事後替換時的退路：整理（有時限）→ 寫歷史 → 剪貼簿貼一次。
    /// - `originalMark`：`original` 被 `SentenceMood.finish` 拿掉的句尾標點（接續聽寫用）。
    /// - `latePayload`：AX 先前寫入的完整字串（含前綴與結尾空白）；`alreadyDelivered` 成立時游標停在它後面。
    private func pasteWithoutCapture(original: String, originalMark: String = "", raw: String, duration: TimeInterval,
                                     historyID: UUID,
                                     audioPath: String?, token: UUID, context: LimitedAppContext,
                                     dictionary: [String: String], config: CleanupConfig, useLocalFormatter: Bool,
                                     sink: ResultSink = .newEntry(countsTowardStats: true),
                                     latePayload: String? = nil,
                                     alreadyDelivered: () -> Bool = { false }) async {
        // 開始時抓到的欄位：剪貼簿貼上仍貼在那裡（前景 App 沒換、游標沒動時），下一段才接得上。重試沒有這一次的欄位。
        let captured = sink.isRetry ? nil : destination
        destination?.invalidate(); destination = nil
        statusMessage = preferences.tr("整理中…", "Cleaning up…")
        let started = Date()
        let rawCleaned: String?
        if useLocalFormatter {
            let localRun = localBackgroundRunner
            rawCleaned = await SmartCleanup.withinDeadline { [weak self] in
                if let localRun { return await localRun(raw, context, dictionary) }
                guard let self else { return nil }
                return await self.localBackgroundCleanup(raw, context: context, dictionary: dictionary)
            }
        } else {
            // This destination cannot safely replace already inserted text, so the user waits for
            // this one paste. Fixed budget even for long transcripts (SmartCleanup.clipboardPasteTimeout).
            let work = cleanupWork(raw: raw, config: config)
            rawCleaned = await SmartCleanup.withinDeadline(seconds: SmartCleanup.clipboardPasteTimeout) { await work() }
        }
        guard token == operationToken else { return }
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        let presented = config.autoList ? OutputShape.expandingInlineNumberedList(original) : original
        var output = presented
        var outputMark = originalMark
        // 重試沒有貼到欄位：不寫「已用剪貼簿貼上」這種原因。
        var note: String? = sink.isRetry ? nil
            : preferences.tr("此欄位不支援背景替換，已用剪貼簿貼上", "Field doesn't support background replacement; pasted via clipboard")
        // 2026-10-19 Typeless 對打：這裡再跑一次嚴格把關，會把 Claude 已經用寬鬆把關收下的修正丟掉 → 同一個 provider 規則。
        if let cleaned = rawCleaned.map(Normalizer.normalizeNumbers),
           SmartCleanup.accepts(original: original, cleaned: cleaned, relaxed: !useLocalFormatter && config.provider == .claude) {
            let named = applyingVocabulary(cleaned, dictionary: dictionary)
            let listed = config.autoList ? OutputShape.expandingInlineNumberedList(named) : named
            output = moodApplies ? SentenceMood.finish(listed) : listed
            outputMark = finishDroppedMark(named)
            deliveryLog.info("smart fallback paste: cleanup applied in \(elapsed, privacy: .public) ms")
        } else {
            note = preferences.tr("智慧整理沒有在時限內完成（或被把關擋下），已貼上本機整理結果",
                                  "Smart cleanup didn't finish in time (or was rejected); pasted the local result")
            deliveryLog.error("smart fallback paste: cleanup unavailable after \(elapsed, privacy: .public) ms; pasted deterministic text")
        }
        lastOutput = output
        guard commitResult(output: output, raw: raw, duration: duration, historyID: historyID,
                           audioPath: audioPath, context: context, note: note, sink: sink) else {
            isProcessing = false
            return
        }
        isProcessing = false
        onDeliveryEvent?("fallback")
        let pasteOutput = preferences.appendTrailingSpace ? output + " " : output
        // AX 寫入回報失敗、但字其實晚到了（整理等待的那幾秒內才出現）：不能再貼第二份。
        if alreadyDelivered() {
            // 欄位裡是先送出的原句，不是整理版：歷史與「最後結果」要記實際送達的那份。
            lastOutput = presented
            preferences.replaceHistoryOutput(id: historyID, with: presented)
            rememberDelivered(presented, droppedMark: originalMark, target: latePayload == nil ? nil : captured,
                              payload: latePayload ?? presented)
            watchEdits(presented)
            statusMessage = preferences.tr("已貼上", "Inserted")
            deliveryLog.info("smart fallback paste: AX text landed late; skipped clipboard paste")
            onDeliveryEvent?("delivered-late")
            return
        }
        guard preferences.isolation == nil else {
            statusMessage = preferences.tr("目的地已變更；可複製最後結果", "Destination changed; copy the last result")
            deliveryLog.error("smart fallback paste: destination app changed; result kept for copy")
            return
        }
        let plan = deliveryPlan()
        guard plan.paste else {
            deliveryLog.error("smart fallback paste: destination app changed; result kept on the card")
            keepUndelivered(output, historyID: historyID, reason: .destinationChanged)
            return
        }
        do {
            try ClipboardPaster.paste(pasteOutput, method: preferences.pasteMethod, handling: preferences.clipboardHandling)
            logDeliveryTiming("clipboard, cleanup \(elapsed) ms")
            if plan.showCard {
                keepUndelivered(output, historyID: historyID, reason: .notATextField)
                return
            }
            rememberDelivered(output, droppedMark: outputMark, target: captured, payload: pasteOutput)
            watchEdits(output)
            statusMessage = output == original
                ? preferences.tr("已貼上（智慧整理未完成）", "Pasted (Smart cleanup didn't finish)")
                : preferences.tr("已整理並貼上", "Formatted and pasted")
            notify()
        } catch {
            lastErrorMessage = error.localizedDescription
            deliveryLog.error("smart fallback paste failed: \(error.localizedDescription, privacy: .public)")
            keepUndelivered(output, historyID: historyID, reason: .pasteFailed)
        }
    }

    /// The caller bounds this background work without waiting for an uncooperative formatter to return.
    private func localBackgroundCleanup(_ text: String, context: LimitedAppContext,
                                        dictionary: [String: String]) async -> String? {
        let command = preferences.localEditorCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        let configuredModel = preferences.localEditorModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = configuredModel.isEmpty ? "local-qwen3-editor" : configuredModel
        let script = preferences.outputScript.rawValue
        do {
            let prompt = try await makePrompt(transcript: text, context: context, dictionary: dictionary)
            try Task.checkCancellation()
            let candidate: String
            if !command.isEmpty {
                candidate = try await LocalFormatterProcessClient(command: command, outputScript: script)
                    .format(prompt: prompt, model: model)
            } else {
                candidate = try await OllamaFormatterClient(model: model).format(prompt: prompt, model: model)
            }
            try Task.checkCancellation()
            return FormatterOutputGuard.sanitize(candidate, source: text, mode: .smart)
        } catch {
            return nil
        }
    }

    private func uniqueModels(from decision: RoutingDecision) -> [BailianModel] {
        var result: [BailianModel] = []
        for model in [decision.primaryModel].compactMap({ $0 }) + decision.fallbackChain {
            if !result.contains(model) { result.append(model) }
        }
        return result
    }

    private func makePrompt(
        transcript: String,
        context: LimitedAppContext,
        dictionary: [String: String]
    ) async throws -> String {
        let dictionaryText = dictionary
            .sorted { $0.key < $1.key }
            .map { "\($0.key) → \($0.value)" }
            .joined(separator: "\n")
        // 詞庫包：個人字典優先，再用 bigram／latin 相關度從已開啟 catalog 包篩入，上限 200。
        // pack terms 讀檔 + bigram score 在背景 actor 上跑，避免 408k 詞把 MainActor 卡住。
        let enabledPacks = preferences.enabledVocabularyPackIDs
        let cleanupTerms = await Task.detached(priority: .utility) {
            VocabularyPacks.termsForCleanup(text: transcript,
                                            personal: dictionary,
                                            enabled: enabledPacks)
        }.value
        let date = ISO8601DateFormatter().string(from: Date())
        let preferredPath = preferences.formatterPromptPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let template = try PromptStore.loadTemplate(preferredPath: preferredPath.isEmpty ? nil : preferredPath)
        var prompt = try PromptLoader.fillPlaceholders(template: template, values: [
            "transcript": transcript,
            "app": context.appName ?? "未知 App",
            "dictionary": dictionaryText,
            "selected": context.selectedText ?? "",
            "date": date
        ])
        if !cleanupTerms.isEmpty {
            prompt += "\n\n使用者開啟的詞庫（接近全用 / 個人字典寫法已寫進上面 dictionary）：\n"
            prompt += cleanupTerms.joined(separator: "、")
        }
        // app-shell-7：選了非預設的語言變體才多一行（`.none` 是空字串，提示詞不變）。
        prompt += preferences.effectiveLanguageVariant.promptBlock
        if let preset = preferences.preset(for: context.foregroundBundleIdentifier),
           !preset.promptHint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prompt += "\n\n目前 App preset（僅作語氣提示，不可新增事實）：\n"
            prompt += String(preset.promptHint.prefix(800))
        }
        if preferences.includeSurroundingContext {
            // context-awareness-1：游標前（最近的 500 字）與游標後（200 字）分開標，跟 iOS／Android 一樣。
            let before = ContextBounds.clampBeforeCursor(context.surroundingText)
            let after = ContextBounds.clampAfterCursor(context.textAfterCursor)
            if !before.isEmpty {
                prompt += "\n\n目前輸入欄位最近文字（游標前，僅供格式判斷）：\n" + before
            }
            if !after.isEmpty {
                prompt += "\n\n目前輸入欄位游標後文字（僅供格式判斷）：\n" + after
            }
        }
        if preferences.includeSurroundingContext {
            let where_ = [context.pageLocation.map { "網頁：\($0)" }, context.windowTitle.map { "視窗：\($0)" },
                          context.fieldPlaceholder.map { "欄位提示：\($0)" }].compactMap { $0 }
            if !where_.isEmpty {
                prompt += "\n\n目前輸入位置（僅供判斷語氣與格式，不可照抄進結果）：\n" + where_.joined(separator: "\n")
            }
        }
        return prompt
    }

    private func fail(_ message: String) {
        isRecording = false
        isProcessing = false
        askActive = false        // luna-review r1：失敗後不能讓下一次一般聽寫被當成 Ask
        askSelection = nil
        statusMessage = message
        lastErrorMessage = message
        notify()
    }

    /// Tests replace the delay and the stop action; production uses the preference and real server stop.
    var unloadDelayOverride: Duration?
    var stopRuntime: (() -> Void)?

    func scheduleRuntimeUnload() {
        guard preferences.isolation == nil || unloadDelayOverride != nil else { return }
        unloadTask?.cancel()
        guard preferences.unloadPolicy != .never else { return }
        let delay: Duration
        switch preferences.unloadPolicy {
        case .never: return
        case .afterFiveMinutes: delay = .seconds(300)
        case .afterFifteenMinutes: delay = .seconds(900)
        case .afterOneHour: delay = .seconds(3_600)
        }
        let wait = unloadDelayOverride ?? delay
        unloadTask = Task { @MainActor [weak self] in
            // 2026-09-24 實機（苑涵 0.1.5）：原本 `try? await Task.sleep`——被取消的舊計時器立刻醒來、
            // 當下 isProcessing 已經是 false，就把 server 殺掉 → 每次辨識完都重載模型。取消＝結束，不准往下跑。
            do { try await Task.sleep(for: wait) } catch { return }
            guard !Task.isCancelled, let self, !self.isRecording, !self.isProcessing else { return }
            if let stopRuntime = self.stopRuntime { stopRuntime() } else { self.preferences.stopLocalRuntimeServers() }
            self.statusMessage = self.preferences.tr(
                "本機模型已依設定卸載；下次使用會重新暖機",
                "Local models were unloaded per settings; the next use will warm up again"
            )
            self.notify()
        }
    }

    private func notify() {
        onStateChange?()
        objectWillChange.send()
    }
}

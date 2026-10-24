import ApplicationServices
import AppKit
import UTUVOTypeCore

/// 插入後追蹤使用者修改（2026-10-13，對齊 Typeless；2026-10-22 delivery-learning-3 加上送出／清空／換焦點的結算時機）。
///
/// 貼上後記住那個輸入欄位，開一回合 `EditSession`：
/// - 全域鍵盤監看（跟 `AXCapturedDestination` 同一種 NSEvent 監看）：每次按鍵後防抖 150 ms 讀一次欄位（先問字數，
///   超過 2 萬字不讀；讀一次超過 50 ms 的慢 App 之後就不再每鍵都讀）。
/// - 按 Return、欄位清空、焦點換走、閒置 15 秒、滿 60 秒、下一次開始聽寫：拿最後一份快照交給 `EditTracker` 比對。
/// 只在本機比對，欄位文字不保存、不送出；只把「原字 → 改後」的短詞配對交給 `onSuggestions`。
@MainActor
final class EditWatcher {
    /// 讀欄位的那幾個 AX 動作；測試換成假的（不碰真的 AX）。
    struct Field {
        /// 鍵盤焦點還在這個欄位。
        var isFocused: () -> Bool
        /// 欄位全文；讀不到或超過上限回 nil。
        var read: () -> String?
        /// 游標位置（UTF-16）。
        var caretOffset: () -> Int?
    }

    var onSuggestions: (([EditTracker.Correction]) -> Void)?
    /// 秒；測試可換。
    var clock: () -> Double = { ProcessInfo.processInfo.systemUptime }
    /// 防抖讀欄位之前等多久（測試縮短）。
    var readDelay: Duration = .milliseconds(Int(EditSession.readDebounce * 1000))
    /// ⌘V 是非同步送出的，貼上當下讀游標可能還是貼上前的位置；等目標 App 處理完再記（luna-review r4）。
    var caretDelay: Duration = .milliseconds(400)

    private(set) var session: EditSession?
    private var field: Field?
    private var pid: pid_t?
    private var keyMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private var readTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var caretTask: Task<Void, Never>?
    /// 這個欄位讀一次太慢：之後只在結算時讀，不再每次按鍵都讀。
    private(set) var slowReads = false
    /// 欄位太長就不讀（大型文件不需要、也比較慢）。
    static let maxFieldLength = 20_000

    func watch(inserted text: String) {
        cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, AXIsProcessTrusted(), let focused = Self.focusedTextElement() else { return }
        var owner: pid_t = 0
        let pid: pid_t? = AXUIElementGetPid(focused, &owner) == .success ? owner : nil
        begin(inserted: trimmed, field: Self.axField(focused))
        self.pid = pid
        installMonitors()
    }

    /// 不碰 AX 的那半：開一回合（`watch` 與測試共用）。
    func begin(inserted: String, field: Field) {
        cancel()
        let trimmed = inserted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return }
        session = EditSession(inserted: trimmed, at: clock())
        self.field = field
        caretTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.caretDelay)
            guard !Task.isCancelled, self.session != nil else { return }
            self.session?.expectedEnd = field.caretOffset()
            self.readIfFocused()
        }
        scheduleDeadline()
    }

    /// 全域鍵盤監看看到的按鍵（測試直接呼叫）。
    func handleKey(isReturn: Bool) {
        guard session != nil, let field else { return }
        if isReturn {
            // Return 不是在這個欄位按的＝焦點早就換了。
            guard field.isFocused() else { return focusLeft() }
            // 能讀就先讀一次：多行欄位（Return＝換行）或 App 還沒處理送出時，這份是最新的；已經清空就交給狀態機用上一份。
            if !slowReads { snapshotNow() }
            finish { $0.keyDown(isReturn: true, at: self.clock()) }
            return
        }
        session?.keyDown(isReturn: false, at: clock())
        scheduleDeadline()
        guard !slowReads else { return }
        readTask?.cancel()
        readTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.readDelay)
            guard !Task.isCancelled else { return }
            self.readIfFocused()
        }
    }

    /// 焦點換到別的欄位／App：先讀一次原本那個欄位（還讀得到就是最新的），再結算。
    func focusLeft() {
        guard session != nil else { return }
        snapshotNow()
        finish { $0.focusChanged() }
    }

    /// 下一次開始聽寫前呼叫：使用者已經改完上一段了，現在就比對。
    func checkNow() {
        guard session != nil else { return cancel() }
        snapshotNow()
        finish { $0.end() }
    }

    func cancel() {
        readTask?.cancel(); readTask = nil
        deadlineTask?.cancel(); deadlineTask = nil
        caretTask?.cancel(); caretTask = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        session = nil
        field = nil
        pid = nil
        slowReads = false
    }

    // MARK: - 內部

    private func readIfFocused() {
        guard session != nil, let field else { return }
        guard field.isFocused() else { return focusLeft() }
        snapshotNow()
        if session?.isFinished == true { finish { $0.end() } }
    }

    /// 讀一次欄位交給狀態機；欄位清空時狀態機會自己結算。
    private func snapshotNow() {
        guard session?.isFinished == false, let field else { return }
        let started = clock()
        let value = field.read()
        if clock() - started > EditSession.slowReadLimit { slowReads = true }
        session?.snapshot(value, at: clock())
    }

    private func scheduleDeadline() {
        deadlineTask?.cancel()
        guard let deadline = session?.deadline else { return }
        let wait = max(0, deadline - clock())
        deadlineTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(wait * 1000) + 10))
            guard !Task.isCancelled, let self else { return }
            self.timeUp()
        }
    }

    private func timeUp() {
        guard session != nil else { return }
        snapshotNow()
        finish { $0.tick(at: self.clock()) }
        if session != nil { scheduleDeadline() }   // 期間有按鍵：閒置時間往後延
    }

    /// 套用一個事件；狀態機結算了就比對、回報，然後收掉這一回合。
    private func finish(_ apply: (inout EditSession) -> EditSession.Outcome?) {
        guard var current = session else { return }
        _ = apply(&current)
        session = current
        guard let outcome = current.outcome else { return }
        cancel()
        if case let .evaluate(original, edited) = outcome {
            // 學字典用的版本：中文單字修改用整個詞當 key，不借不相干的鄰字（2026-10-22 修補）。
            let found = EditTracker.learnableCorrections(inserted: original, current: edited)
            if !found.isEmpty { onSuggestions?(found) }
        }
    }

    private func installMonitors() {
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let isReturn = event.keyCode == 36 || event.keyCode == 76   // Return、數字鍵盤 Enter
            MainActor.assumeIsolated { self?.handleKey(isReturn: isReturn) }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let activated = app?.processIdentifier
            MainActor.assumeIsolated {
                guard let self, activated != self.pid else { return }
                self.focusLeft()
            }
        }
    }

    private static func axField(_ element: AXUIElement) -> Field {
        Field(
            isFocused: {
                guard let now = focusedTextElement() else { return false }
                return CFEqual(now, element)
            },
            read: {
                // 先問字數再讀全文：超過上限就不讀（luna-review r1：讀 2 萬字以上的欄位會卡主執行緒）。
                guard let length = copy(element, kAXNumberOfCharactersAttribute) as? Int, length <= maxFieldLength,
                      let value = copy(element, kAXValueAttribute) as? String, value.count <= maxFieldLength else { return nil }
                return value
            },
            caretOffset: { caretOffset(element) }
        )
    }

    private static func caretOffset(_ element: AXUIElement) -> Int? {
        guard let value = copy(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetType(axValue) == .cfRange, AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range.location + range.length
    }

    /// 找出剛貼的那段（演算法搬到 core 的 `EditSession.locate`，狀態機與這裡共用同一份）。
    static func locate(_ inserted: String, in value: String, expectedEnd: Int? = nil) -> String? {
        EditSession.locate(inserted, in: value, expectedEnd: expectedEnd)
    }

    /// 目前焦點上的文字欄位；密碼欄位（AXSecureTextField）回 nil＝不追蹤。
    private static func focusedTextElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)
        guard let value = copy(system, kAXFocusedUIElementAttribute),
              CFGetTypeID(value as CFTypeRef) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.2)   // 先設逾時再讀任何屬性（luna-review r3／r4）
        if (copy(element, kAXSubroleAttribute) as? String) == "AXSecureTextField" { return nil }
        return element
    }

    private static func copy(_ element: AXUIElement, _ attribute: String) -> Any? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }
}

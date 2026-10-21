import ApplicationServices
import AppKit
import UTUVOTypeCore

/// 插入後追蹤使用者修改（2026-10-13，對齊 Typeless）。
///
/// 貼上後記住那個輸入欄位；20 秒後（或下一次開始聽寫時，先到先算）再讀一次欄位文字，
/// 找到剛才貼的那段，交給 `EditTracker` 比對。只在本機比對，欄位文字不保存、不送出；
/// 只把「原字 → 改後」的短詞配對留下來當字典建議，使用者按「加入」才進字典。
@MainActor
final class EditWatcher {
    var onSuggestions: (([EditTracker.Correction]) -> Void)?
    private var element: AXUIElement?
    private var inserted = ""
    /// 貼上後的游標位置（UTF-16 偏移）＝剛貼那段的結尾；比對時挑結尾最靠近這裡的候選（luna-review r2）。
    private var expectedEnd: Int?
    private var task: Task<Void, Never>?
    /// 欄位太長就不讀（大型文件不需要、也比較慢）。
    static let maxFieldLength = 20_000

    func watch(inserted text: String, after delay: Duration = .seconds(20)) {
        cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, AXIsProcessTrusted(), let focused = Self.focusedTextElement() else { return }
        element = focused
        inserted = trimmed
        task = Task { [weak self] in
            // luna-review r4：⌘V 是非同步送出的，貼上當下讀游標可能還是貼上前的位置；等目標 App 處理完再記。
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self, let element = self.element else { return }
            self.expectedEnd = Self.caretOffset(element)
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self.checkNow()
        }
    }

    /// 下一次開始聽寫前呼叫：使用者已經改完上一段了，現在就比對。
    func checkNow() {
        task?.cancel()
        task = nil
        defer { element = nil; inserted = ""; expectedEnd = nil }
        // 先問字數再讀全文：超過上限就不讀（luna-review r1：讀 2 萬字以上的欄位會卡主執行緒）。
        guard let element, !inserted.isEmpty,
              let length = Self.copy(element, kAXNumberOfCharactersAttribute) as? Int, length <= Self.maxFieldLength,
              let value = Self.copy(element, kAXValueAttribute) as? String,
              value.count <= Self.maxFieldLength,
              !value.contains(inserted),
              let slice = Self.locate(inserted, in: value, expectedEnd: expectedEnd) else { return }
        let found = EditTracker.corrections(inserted: inserted, current: slice)
        if !found.isEmpty { onSuggestions?(found) }
    }

    func cancel() {
        task?.cancel()
        task = nil
        element = nil
        inserted = ""
        expectedEnd = nil
    }

    private static func caretOffset(_ element: AXUIElement) -> Int? {
        guard let value = copy(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetType(axValue) == .cfRange, AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range.location + range.length
    }

    /// 用剛才貼的文字開頭、結尾各幾個字當錨點，在欄位裡找出所有候選段落。
    /// 有貼上當下的游標位置：挑結尾最靠近它的（使用者後來在前面改字也只偏幾個字）；
    /// 沒有游標位置：只有唯一候選才用。分不出來就放棄不猜（luna-review r1／r2）。
    static func locate(_ inserted: String, in value: String, expectedEnd: Int? = nil) -> String? {
        let anchor = min(4, max(1, inserted.count / 4))
        let head = String(inserted.prefix(anchor)), tail = String(inserted.suffix(anchor))
        var candidates: [(slice: String, end: Int)] = []
        var searchStart = value.startIndex
        while candidates.count < 20, let headRange = value.range(of: head, range: searchStart..<value.endIndex) {
            let rest = value[headRange.lowerBound...]
            var tailSearch = rest.startIndex
            while let tailRange = rest.range(of: tail, range: tailSearch..<rest.endIndex) {
                let slice = String(value[headRange.lowerBound..<tailRange.upperBound])
                let ratio = Double(slice.count) / Double(max(1, inserted.count))
                if ratio > 1.5 { break }
                if ratio >= 0.6 {
                    let end = value.utf16.distance(from: value.utf16.startIndex, to: tailRange.upperBound)
                    candidates.append((slice, end))
                    break
                }
                tailSearch = tailRange.upperBound
            }
            searchStart = value.index(after: headRange.lowerBound)
        }
        guard !candidates.isEmpty else { return nil }
        guard let expectedEnd else { return candidates.count == 1 ? candidates[0].slice : nil }
        let tolerance = max(8, inserted.utf16.count / 2)
        let near = candidates.map { ($0.slice, abs($0.end - expectedEnd)) }
            .filter { $0.1 <= tolerance }
            .sorted { $0.1 < $1.1 }
        guard let best = near.first else { return nil }
        if near.count > 1, near[1].1 == best.1, near[1].0 != best.0 { return nil }
        return best.0
    }

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

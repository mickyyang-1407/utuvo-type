import Foundation

/// 輸出形狀的 deterministic 修整（2026-09-11）。
///
/// 本機小型 editor（Qwen3-4B）會把單一敘述也加上 "- " 前綴——「等一下開會」
/// 變成「- 等一下開會」，貼進文件就是多一顆髒點。prompt 已經寫明單一敘述要用段落，
/// 但不能只靠模型守規矩，這裡用純函式再兜一層。
///
/// 放在 Core 是為了可測（App target 沒有測試 target）。
public enum OutputShape: Sendable {
    private static let bulletMarkers = ["- ", "* ", "• ", "・"]

    private static let inlineOrdinal = try! NSRegularExpression(
        pattern: #"(?:^|(?<=[ \t，,、：:；;]))([1-9][0-9]{0,2})[.、)](?![0-9])[ \t]*"#)
    private static let itemBridge = try! NSRegularExpression(
        pattern: #"(還有(?:最重要的)?|以及|最重要的)[ \t]*$"#)

    /// Only expand an explicit, contiguous 1…N list. Do not infer items from prose,
    /// decimal/version numbers, or code, and never invent or remove item content.
    public static func expandingInlineNumberedList(_ text: String) -> String {
        guard !text.contains("\n"), !text.contains("`") else { return text }
        let ns = text as NSString
        let markers = inlineOrdinal.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard markers.count >= 2,
              markers.enumerated().allSatisfy({ Int(ns.substring(with: $0.element.range(at: 1))) == $0.offset + 1 }) else { return text }
        var bodies: [String] = []
        for (index, marker) in markers.enumerated() {
            let start = NSMaxRange(marker.range)
            let end = index + 1 < markers.count ? markers[index + 1].range.location : ns.length
            let body = ns.substring(with: NSRange(location: start, length: end - start))
                .trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty else { return text }
            bodies.append(body)
        }
        // “5. 耳機還有最重要的 6. 耳朵”: keep the bridge with item 6.
        // Moving only the structural ordinal preserves the spoken word order.
        for index in 0..<(bodies.count - 1) {
            let body = bodies[index] as NSString
            if let bridge = itemBridge.firstMatch(in: bodies[index], range: NSRange(location: 0, length: body.length)),
               bridge.range.location > 0 {
                let before = body.substring(to: bridge.range.location).trimmingCharacters(in: .whitespaces)
                guard !before.isEmpty else { continue }
                bodies[index] = before
                bodies[index + 1] = body.substring(with: bridge.range).trimmingCharacters(in: .whitespaces) + bodies[index + 1]
            }
        }
        var intro = ns.substring(to: markers[0].range.location).trimmingCharacters(in: .whitespaces)
        if !intro.isEmpty, !intro.hasSuffix(":"), !intro.hasSuffix("：") { intro += "：" }
        let lines = bodies.enumerated().map { "\($0.offset + 1). \($0.element)" }
        return (intro.isEmpty ? lines : [intro] + lines).joined(separator: "\n")
    }

    /// 整段輸出恰好一行、而且那行是條列項時，剝掉條列符號。
    /// 兩行以上（真的多項條列）一律原樣返回。
    public static func stripLoneBullet(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count == 1 else { return text }
        let line = lines[0].trimmingCharacters(in: .whitespaces)
        for marker in bulletMarkers where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    /// 單行輸入框（Return＝送出／搜尋、或沒標成多行）：把分段／條列的換行接回一行（2026-09-19）。
    /// 換行在單行框裡可能直接觸發送出；前面是英文字元（含 . , !）、後面是英數字時補一個空白，其餘（中文、標點）直接接上。
    public static func singleLine(_ text: String) -> String {
        guard text.contains("\n") else { return text }
        let chars = Array(text)
        var out = ""
        var i = 0
        while i < chars.count {
            if chars[i] == "\n" {
                var j = i
                while j < chars.count, chars[j] == "\n" { j += 1 }
                let before = out.last
                let after = j < chars.count ? chars[j] : nil
                if let b = before, let a = after, b.isASCII, !b.isWhitespace, a.isASCII, a.isLetter || a.isNumber {
                    out.append(" ")
                } else if let b = before, b.isLetter || b.isNumber, startsNumberedItem(chars, at: j) {
                    // 編號清單接成一行（本機整理也會出「1. 」了，2026-10-22 W2-6）：「買牛奶\n2. 回信」→「買牛奶 2. 回信」，不要黏成「買牛奶2. 回信」。
                    out.append(" ")
                }
                i = j
                continue
            }
            out.append(chars[i])
            i += 1
        }
        return out
    }

    /// 從 `index` 開始是「數字＋. ＋空白」（編號清單的一項）。
    static func startsNumberedItem(_ chars: [Character], at index: Int) -> Bool {
        var k = index
        while k < chars.count, chars[k].isASCII, chars[k].isNumber { k += 1 }
        return k > index && k + 1 < chars.count && chars[k] == "." && chars[k + 1] == " "
    }
}

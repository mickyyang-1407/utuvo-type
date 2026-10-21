import Foundation

/// 富文字插入（2026-10-13，對齊 Typeless 的 insertRichText）：整理結果有條列時，貼上時另附一份 HTML，
/// Google Docs／Notion／Gmail／Pages／備忘錄這類富文字編輯器就會變成真正的編號／項目清單；
/// 純文字欄位照舊吃純文字那份（剪貼簿同時放兩種格式，由目的 App 自己挑）。
///
/// 只處理條列與段落，不加任何字型、顏色或樣式——貼進去跟使用者原本的文件樣式一致。
public enum RichTextShape: Sendable {
    /// 有條列才回 HTML；沒有條列（一般句子、單段）回 nil＝只貼純文字。
    public static func html(for text: String) -> String? {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [String] = []
        var listKind: ListKind?
        var items: [String] = []
        var sawList = false

        func flushList() {
            guard let kind = listKind, !items.isEmpty else { listKind = nil; items = []; return }
            let tag = kind == .ordered ? "ol" : "ul"
            blocks.append("<\(tag)>" + items.map { "<li>\(escape($0))</li>" }.joined() + "</\(tag)>")
            listKind = nil
            items = []
        }

        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flushList(); continue }
            if let (kind, body) = listItem(line) {
                sawList = true
                if listKind != kind { flushList(); listKind = kind }
                items.append(body)
            } else {
                flushList()
                blocks.append("<p>\(escape(line))</p>")
            }
        }
        flushList()
        guard sawList else { return nil }
        return "<meta charset=\"utf-8\">" + blocks.joined()
    }

    enum ListKind: Equatable { case ordered, unordered }

    /// 「1. 」「1) 」「1、」「1）」「１．」＝編號；「- 」「• 」「* 」「・」＝項目。
    static func listItem(_ line: String) -> (ListKind, String)? {
        let scalars = Array(line)
        var i = 0
        while i < scalars.count, scalars[i].isNumber, i < 3 { i += 1 }
        if i > 0, i < scalars.count, ".)、）．".contains(scalars[i]) {
            // 半形「.」「)」後面要有空白：「3.5 公斤」「1.0 版」不是條列。
            let needsSpace = scalars[i] == "." || scalars[i] == ")"
            let next = i + 1 < scalars.count ? scalars[i + 1] : " "
            if !needsSpace || next.isWhitespace {
                let body = String(scalars[(i + 1)...]).trimmingCharacters(in: .whitespaces)
                if !body.isEmpty { return (.ordered, body) }
            }
        }
        for bullet in ["- ", "• ", "* ", "・", "•"] where line.hasPrefix(bullet) {
            let body = String(line.dropFirst(bullet.count)).trimmingCharacters(in: .whitespaces)
            if !body.isEmpty { return (.unordered, body) }
        }
        return nil
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

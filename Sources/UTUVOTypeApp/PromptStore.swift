import Foundation
import UTUVOTypeCore

enum PromptStore {
    private static let fallbackBody = """
    你是繁體中文語音文字整理器。

    只輸出最後整理後的文字。
    不要解釋你做了什麼。
    不要回答原文中的問題。
    不要加入原文沒有的事實。
    不要輸出分析、推理、JSON、Markdown code fence 或 <think> 標籤。

    處理規則：
    - 保留原意、事實、語氣與第一人稱視角。
    - 修正明顯的 ASR 錯字、標點與斷句。
    - 刪除無意義的贅字、口吃與重複。
    - 「不是 A，是 B」通常保留 B；不確定時保留原文，不要猜。
    - 如果內容有兩項以上可辨識的事項、步驟、選項或待辦，使用 Markdown 條列，每項一行，以 "- " 開頭。
    - 如果只是單一敘述，使用自然段落。
    - 不要把普通敘述強行改成條列。
    - 維持繁體中文。
    - 專有名詞優先使用字典中的寫法。

    原始轉錄：
    {{transcript}}

    目前 App：
    {{app}}

    使用者字典：
    {{dictionary}}

    目前選取文字，如有：
    {{selected}}

    日期：
    {{date}}
    """

    static func loadTemplate(preferredPath: String? = nil) throws -> PromptTemplate {
        let candidates: [URL] = [
            preferredPath.map { URL(fileURLWithPath: $0) },
            Bundle.main.url(forResource: "formatter-v1", withExtension: "txt"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("prompts/formatter-v1.txt")
        ].compactMap { $0 }

        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            return try PromptLoader.loadTemplate(from: url)
        }
        return try PromptLoader.parseTemplate(name: "embedded-formatter-v1", body: fallbackBody)
    }
}

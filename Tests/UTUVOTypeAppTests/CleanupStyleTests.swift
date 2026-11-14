import XCTest
@testable import UTUVOTypeApp
import UTUVOTypeCore

/// 整理風格（2026-11-14，同 iOS TypelessW3Tests／Android CleanupStyleTest）：精簡＝新提示詞＋雲端一律寬鬆把關；忠實＝原本做法。
final class CleanupStyleTests: XCTestCase {
    func testGateMatrix() {
        for provider in SmartCleanupProvider.allCases {
            XCTAssertTrue(SmartCleanup.relaxedGate(style: .concise, provider: provider))
            XCTAssertEqual(SmartCleanup.relaxedGate(style: .faithful, provider: provider), provider == .claude)
        }
    }

    func testFaithfulPromptUnchangedConcisePromptHasListAndNoAnswerRules() {
        XCTAssertEqual(SmartCleanup.baseInstructions(style: .faithful, autoList: true),
                       CleanupPromptRules.apply(SmartCleanup.instructions, autoList: true))
        let concise = SmartCleanup.baseInstructions(style: .concise, autoList: true)
        XCTAssertTrue(concise.contains(SmartCleanup.conciseListRule))
        XCTAssertTrue(concise.contains("絕對不要回答"))
        XCTAssertFalse(SmartCleanup.baseInstructions(style: .concise, autoList: false).contains(SmartCleanup.conciseListRule))
    }

    func testDefaultStyleIsConciseAndConfigDefaultsToFaithful() {
        let suite = "cleanup-style-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(defaults.string(forKey: "utuvo.type.smart.style").flatMap(CleanupStyle.init(rawValue:)) ?? .concise, .concise)
        XCTAssertEqual(CleanupConfig(enabled: true, provider: .groq, customEndpoint: "", customModel: "", language: "zh-TW",
                                     personal: [:], enabledPacks: []).style, .faithful)
    }

    /// 真人錄音 lp01：清單＋「人生→人聲」「付→附」。寬鬆放行、嚴格照擋。
    func testRelaxedAcceptsListAndHomophoneFixes() {
        let raw = "這次案子分成三個部分,第一個部分是前期的素材整理,主要把客戶給的Multi-Track收進來,然後檢查每一軌的完整性。另外第二個部分是實際的混音,這部分大概會花三天,重點在於人生的空間感。總之交付的時候記得付一份Mixing Note"
        let reply = "這次案子分成三個部分：\n1. 前期素材整理，主要把客戶給的 Multi-Track 收進來，並檢查每一軌的完整性\n2. 實際混音，大概會花三天，重點在於人聲的空間感\n交付時記得附一份 Mixing Note。"
        XCTAssertTrue(SmartCleanup.accepts(original: raw, cleaned: reply, relaxed: true))
        XCTAssertFalse(SmartCleanup.accepts(original: raw, cleaned: reply, relaxed: false))
    }

    func testRelaxedStillBlocksAnswersNumbersAndPerson() {
        XCTAssertFalse(SmartCleanup.accepts(original: "你能不能幫我確認一下檔案是不是最新版?",
                                            cleaned: "我沒辦法確認你的檔案是不是最新版，我看不到你的電腦。", relaxed: true))
        XCTAssertFalse(SmartCleanup.accepts(original: "總共是1250塊先付三成當定金", cleaned: "總共是1,520塊，先付三成當定金。", relaxed: true))
        XCTAssertFalse(SmartCleanup.accepts(original: "我這邊沒有收到你的檔案", cleaned: "你那邊沒有收到我的檔案。", relaxed: true))
    }

    /// 真 API 對打（沒有 key 就跳過）：`LIVE_CLAUDE_KEY`、`LIVE_BENCH_IN`（{id: 逐字稿}）、`LIVE_BENCH_OUT`。走 App 的 SmartCleanup.run。
    func testLiveConciseVersusFaithfulWithClaude() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let key = env["LIVE_CLAUDE_KEY"], !key.isEmpty, let input = env["LIVE_BENCH_IN"], let output = env["LIVE_BENCH_OUT"] else {
            throw XCTSkip("no live key")
        }
        let cases = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: input)))
        var rows: [[String: String]] = []
        for style in CleanupStyle.allCases {
            var ok = 0
            for id in cases.keys.sorted() {
                let text = cases[id]!
                let start = Date()
                var out = ""
                var accepted = false
                do {
                    out = try await SmartCleanup.run(text, provider: .claude, key: key, personal: [:], enabledPacks: [],
                                                     traditional: true, transport: StrictCleanupSession.shared, style: style)
                    accepted = true; ok += 1
                } catch {}
                rows.append(["id": id, "style": style.rawValue, "accepted": accepted ? "yes" : "no", "out": out,
                             "ms": String(Int(Date().timeIntervalSince(start) * 1000))])
            }
            print("LIVEBENCH|mac|\(style.rawValue)|accepted=\(ok)/\(cases.count)")
        }
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
    }
}

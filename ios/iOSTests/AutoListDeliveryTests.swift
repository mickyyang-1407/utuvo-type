import Testing
import UIKit
@testable import UTUVOTypeiOS
import UTUVOTypeCore

@MainActor
struct AutoListDeliveryTests {
    static let raw = "明天的錄音要帶 1.麥克風 2.輔駕 3.腳架 4.個人監聽器 5.耳機還有最重要的 6.耳朵"

    @Test(arguments: [true, false])
    func localUnavailableStillRespectsListPreference(_ lists: Bool) async {
        let result = await SmartCleanup.finalize(Self.raw, language: "zh-TW", forceLocal: true, autoList: lists,
            configuration: { .init(enabled: true, provider: .groq, endpoint: "", model: "", key: "") },
            terms: { _ in [] }, transport: { _ in Issue.record("Unexpected network"); throw CancellationError() },
            onDevice: nil, log: { _, _, _, _ in })
        #expect(result == (lists ? OutputShape.expandingInlineNumberedList(Self.raw) : Self.raw))
    }

    @Test func rejectedModelCannotEraseEmphasisFromFallback() async throws {
        let result = await SmartCleanup.finalize(Self.raw, language: "zh-TW", forceLocal: true, autoList: true,
            configuration: { .init(enabled: true, provider: .groq, endpoint: "", model: "", key: "") },
            terms: { _ in [] }, transport: { _ in Issue.record("Unexpected network"); throw CancellationError() },
            onDevice: { _, _ in "明天的錄音要帶：\n1. 麥克風\n2. 輔駕\n3. 腳架\n4. 個人監聽器\n5. 耳機\n6. 耳朵" },
            log: { _, _, _, _ in })
        let output = try #require(result)
        #expect(output == OutputShape.expandingInlineNumberedList(Self.raw))
        let final = TextPipeline(dictionary: [:], latinTerms: [], variant: .zhTW).clean(output).output
        #expect(final.filter { $0 == "\n" }.count == 6)
        #expect(final.contains("還有最重要的耳朵"))
        #expect(ToneHint.allowsLineBreaks(returnKeyType: .send, keyboardType: .default))
        #expect(ToneHint.allowsLineBreaks(returnKeyType: .done, keyboardType: .default))
        #expect(!ToneHint.allowsLineBreaks(returnKeyType: .send, keyboardType: .emailAddress))
        #expect(!ToneHint.allowsLineBreaks(returnKeyType: .search, keyboardType: .default))
    }
}

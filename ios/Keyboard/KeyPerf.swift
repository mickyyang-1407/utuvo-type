#if DEBUG
import Foundation
import os

/// 打字路徑計時（只在 DEBUG 編進來；2026-09-20 Micky：「打字回饋有點慢，應該是頓頓的」→ 先量再改）。
/// 讀法：模擬器跑打字 UI 測試後
///   /usr/bin/log show --predicate 'subsystem == "com.utuvo.type.keyboard"' --last 5m --style compact
enum KeyPerf {
    static let log = Logger(subsystem: "com.utuvo.type.keyboard", category: "perf")

    @discardableResult
    static func measure<T>(_ name: StaticString, _ body: () -> T) -> T {
        let start = CFAbsoluteTimeGetCurrent()
        let out = body()
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        log.notice("\(name, privacy: .public) \(ms, format: .fixed(precision: 2)) ms")
        return out
    }
}
#endif

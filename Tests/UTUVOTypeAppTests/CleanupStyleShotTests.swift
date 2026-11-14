import XCTest
import SwiftUI
import AppKit
@testable import UTUVOTypeApp

/// 設定 → 雲端 → 智慧整理卡的截圖（離屏渲染，不開視窗、不搶焦點）。`SETTINGS_SHOT_DIR` 有設才跑。
@MainActor
final class CleanupStyleShotTests: XCTestCase {
    func testRenderCleanupStyleSetting() throws {
        guard let dir = ProcessInfo.processInfo.environment["SETTINGS_SHOT_DIR"] else { throw XCTSkip("no shot dir") }
        for (language, tag) in [(AppLanguageChoice.traditionalChinese, "zh"), (.english, "en")] {
            let context = try IsolatedContext.make(); defer { context.tearDown() }
            let preferences = AppPreferences(isolation: context)
            preferences.appLanguage = language
            preferences.cleanupEnabled = true
            preferences.cleanupStyle = .concise
            let model = AppModel(preferences: preferences)
            let view = SettingsView(model: model, initialSection: .cloud).frame(width: 980, height: 3200)
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 980, height: 3200)
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("mac-\(tag)-cleanup-style-full.png"))
        }
    }
}

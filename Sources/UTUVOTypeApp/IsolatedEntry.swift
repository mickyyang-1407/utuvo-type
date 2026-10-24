import AppKit
import Foundation
import SwiftUI

/// Dispatched before any normal AppDelegate/AppModel is constructed.
@MainActor
enum IsolatedEntry {
    static func runIfRequested() -> Bool {
        let args = Array(CommandLine.arguments.dropFirst())
        let legacySnapshot = ProcessInfo.processInfo.environment["UTUVO_TYPE_SNAPSHOT_DIR"] != nil
        guard args.contains("--preview-settings") || args.contains("--preview-orb") || args.contains("--ax-qa") || legacySnapshot else { return false }
        do {
            let context = try IsolatedContext.make()
            let delegate = IsolatedDelegate(context: context, arguments: args, legacySnapshot: legacySnapshot)
            let app = NSApplication.shared
            app.delegate = delegate
            app.setActivationPolicy(args.contains("--ax-qa") ? .accessory : .regular)
            withExtendedLifetime(delegate) { app.run() }
            context.tearDown()
        } catch {
            FileHandle.standardError.write(Data("Isolated entry failed.\n".utf8))
        }
        return true
    }
}

@MainActor
private final class IsolatedDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let context: IsolatedContext
    let arguments: [String]
    let legacySnapshot: Bool
    var window: NSWindow?
    var model: AppModel?
    private let orbOverlay = OverlayWindowController()

    init(context: IsolatedContext, arguments: [String], legacySnapshot: Bool) {
        self.context = context; self.arguments = arguments; self.legacySnapshot = legacySnapshot
    }
    private func value(_ option: String) -> String? {
        guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let preferences = AppPreferences(isolation: context)
        let model = AppModel(preferences: preferences)
        self.model = model
        if arguments.contains("--ax-qa") {
            guard let raw = value("--ax-qa"), let pid = Int32(raw), pid > 0,
                  let inserted = value("--insert"), let replacement = value("--replacement"),
                  !inserted.isEmpty, inserted.utf16.count <= 16_384, replacement.utf16.count <= 16_384 else {
                emit("refused", details: "Require explicit host PID, --insert and --replacement"); NSApp.terminate(nil); return
            }
            let delay = min(8_000, max(0, Int(value("--delay-ms") ?? "500") ?? 500))
            preferences.cleanupEnabled = true
            preferences.mode = .smart
            preferences.appendTrailingSpace = arguments.contains("--trailing-space")
            model.captureDestination = { AXAdapter.shared.capture(expectedPID: $0) }
            model.cleanupRunner = { text, config in
                await SmartCleanup.clean(text, config: config,
                    transport: FixtureCleanupTransport(replacement: replacement, delayMilliseconds: delay),
                    credentialLookup: { _ in "synthetic-fixture-credential" }, log: InMemoryCleanupLog())
            }
            model.onDeliveryEvent = { [weak self] event in self?.emit(event) }
            model.prepareDictation(mode: .smart, expectedPID: pid)
            Task { @MainActor in
                await model.completeSyntheticDictation(inserted)
                await model.waitForBackgroundCleanup()
                self.emit("finished", details: model.lastOutput)
                NSApp.terminate(nil)
            }
        } else if arguments.contains("--preview-orb") {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 340),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "UTUVO Type — Isolated Orb Preview"
            window.isRestorable = false; window.isReleasedWhenClosed = false; window.delegate = self
            window.contentView = NSHostingView(rootView: OrbPreviewGallery(model: model, overlay: orbOverlay))
            self.window = window
            window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            emit("preview-orb", details: "Synthetic levels only; no microphone/keychain/cloud/hotkeys/network")
        } else {
            let requested = value("--preview-settings")
            let section: SettingsSection = requested == "cleanup" ? .cloud
                : SettingsSection(rawValue: requested ?? "") ?? .dictionary
            if requested == "insights" {
                // 隔離預覽填一點假的使用數據，畫面才看得出熱圖與數字（只寫隔離 suite）。
                let cal = Calendar.current
                for offset in stride(from: 0, to: 120, by: 1) where offset % 3 != 1 {
                    guard let day = cal.date(byAdding: .day, value: -offset, to: Date()) else { continue }
                    model.preferences.appendHistory(HistoryRecord(date: day, rawTranscript: "",
                        output: String(repeating: "字", count: 40 + (offset * 37) % 260), duration: Double(10 + offset % 50), mode: .smart))
                }
            }
            if requested == "history" || requested == "advanced" {
                // 隔離預覽的假紀錄（只寫隔離 suite）：正常、辨識失敗（錄音留著）、處理中取消各一筆。
                let prefs = model.preferences
                let failedID = UUID()
                let failedAudio = prefs.recordingsDirectory.appendingPathComponent("\(failedID.uuidString).caf")
                try? FileManager.default.createDirectory(at: prefs.recordingsDirectory, withIntermediateDirectories: true)
                try? Data("synthetic".utf8).write(to: failedAudio)
                prefs.appendHistory(HistoryRecord(date: Date().addingTimeInterval(-3_600), rawTranscript: "合成測試文字",
                    output: "合成測試文字。", duration: 4, mode: .smart, appName: "Notes"))
                prefs.appendHistory(HistoryRecord(id: failedID, date: Date().addingTimeInterval(-600), rawTranscript: "",
                    output: "", duration: 7, mode: .fast, appName: "Mail", audioPath: failedAudio.path,
                    note: "The network connection was lost.", status: .failed), countsTowardStats: false)
                prefs.appendHistory(HistoryRecord(date: Date().addingTimeInterval(-60), rawTranscript: "取消前已經辨識好的一段話",
                    output: "", duration: 5, mode: .smart, appName: "Slack", status: .cancelled), countsTowardStats: false)
            }
            if requested == "dictionary" {
                model.preferences.addSuggestions([.init(from: "元山", to: "圓山"), .init(from: "Atmus", to: "Atmos")])
                // 隔離預覽的假詞條（只寫隔離 suite），看得到搜尋框、詞條與「復原」列。
                for (source, output) in [("Atmos", ""), ("cloud code", "Claude Code"), ("除值", "儲值"), ("pik", "Pik")] {
                    model.preferences.addDictionaryTerm(source: source, output: output)
                }
            }
            if requested == "answer" {
                AnswerCardController.shared.show(.init(question: "台北到高雄高鐵大概要多久？",
                    answer: "直達車約 1 小時 30 分；停站較多的班次約 2 小時。", zh: true, onInsert: {}))
                emit("preview", details: "answer card")
                return
            }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "UTUVO Type — Isolated Settings Preview"
            window.isRestorable = false
            window.isReleasedWhenClosed = false
            window.delegate = self
            if arguments.contains("--preview-zh") { model.preferences.appLanguage = .traditionalChinese }
            let comps = Calendar.current.dateComponents([.year, .month], from: Date())
            let thisMonth = String(format: "%04d-%02d", comps.year ?? 0, comps.month ?? 0)
            window.contentView = NSHostingView(rootView: SettingsView(model: model, initialSection: section,
                expandedHistoryMonths: requested == "history" ? [thisMonth] : []))
            self.window = window
            window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            if let raw = value("--preview-scroll"), let fraction = Double(raw) {
                // 截圖用：把內容區捲到指定比例（0＝頂、1＝底）。
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak window] in
                    guard let root = window?.contentView else { return }
                    func scrollViews(_ view: NSView) -> [NSScrollView] {
                        (view as? NSScrollView).map { [$0] } ?? [] + view.subviews.flatMap(scrollViews)
                    }
                    guard let scroll = scrollViews(root).max(by: {
                        ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }),
                          let document = scroll.documentView else { return }
                    let maxY = max(0, document.frame.height - scroll.contentView.bounds.height)
                    let y = document.isFlipped ? maxY * min(1, max(0, fraction)) : maxY * (1 - min(1, max(0, fraction)))
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
            }
            emit("preview", details: "Unique suite and storage; safe controls enabled; no keychain/cloud/microphone/hotkeys/network")
        }
    }
    private func emit(_ event: String, details: String? = nil) {
        var object: [String: Any] = ["event": event, "suite": context.suiteName,
                                     "storage": context.applicationSupportDirectory.path]
        if let details { object["details"] = details }
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
            FileHandle.standardOutput.write(data + Data([0x0A]))
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { NSApp.terminate(nil); return true }
    func applicationWillTerminate(_ notification: Notification) { orbOverlay.hide(); model?.cancelProcessing(); context.tearDown() }
}

/// Only instantiated by the explicit synthetic QA command; never performs network IO.
private struct FixtureCleanupTransport: CleanupTransport {
    let replacement: String
    let delayMilliseconds: Int
    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await Task.sleep(for: .milliseconds(delayMilliseconds))
        let data = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": replacement]]]])
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
            throw URLError(.badURL)
        }
        return (data, response)
    }
}

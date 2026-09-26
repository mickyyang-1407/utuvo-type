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
            let section: SettingsSection = value("--preview-settings") == "cleanup" ? .cloud : .dictionary
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "UTUVO Type — Isolated Settings Preview"
            window.isRestorable = false
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: SettingsView(model: model, initialSection: section))
            self.window = window
            window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
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

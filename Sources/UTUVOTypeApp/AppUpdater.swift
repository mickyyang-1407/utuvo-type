import AppKit
import Combine
import Sparkle
import SwiftUI

/// One deferred restart, after all dictation work has drained. Never polls user data.
@MainActor
final class UpdateRestartGate {
    private let busy: () -> Bool
    private let prepare: () async -> Bool
    private var pending: (() -> Void)?
    private var preparing = false
    var isWaiting: Bool { pending != nil }

    init(busy: @escaping () -> Bool, prepare: @escaping () async -> Bool) {
        self.busy = busy; self.prepare = prepare
    }
    func postpone(_ restart: @escaping () -> Void) {
        pending = restart
        resumeIfIdle()
    }
    func resumeIfIdle() {
        guard pending != nil, !busy(), !preparing else { return }
        preparing = true
        Task { [weak self] in
            guard let self else { return }
            let ready = await prepare()
            preparing = false
            if ready && !busy() {
                let restart = pending
                pending = nil
                restart?()
            } else if !busy() {
                resumeIfIdle()
            }
        }
    }
}

@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    private(set) var controller: SPUStandardUpdaterController!
    private let busy: () -> Bool
    private let gate: UpdateRestartGate
    private var observation: AnyCancellable?
    private(set) var isRelaunching = false
    var updater: SPUUpdater { controller.updater }
    var canCheck: Bool { updater.canCheckForUpdates && !busy() }

    init(busy: @escaping () -> Bool, prepareForRestart: @escaping () async -> Bool) {
        self.busy = busy
        self.gate = UpdateRestartGate(busy: busy, prepare: prepareForRestart)
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        observation = updater.publisher(for: \.canCheckForUpdates)
            .merge(with: updater.publisher(for: \.automaticallyChecksForUpdates), updater.publisher(for: \.automaticallyDownloadsUpdates))
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.objectWillChange.send() } }
    }
    func start() { controller.startUpdater() }
    func check() {
        guard canCheck else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
    func resumeIfIdle() { gate.resumeIfIdle() }
    func terminateAfterWork(_ reply: @escaping () -> Void) { gate.postpone(reply) }
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) { isRelaunching = true }
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if busy() { throw NSError(domain: "com.utuvo.type.updates", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "正在錄音或整理，完成後再檢查更新。"] ) }
    }
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        gate.postpone(installHandler)
        return true
    }
}

struct UpdateSettingsView: View {
    @ObservedObject var updates: AppUpdater
    let zh: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(zh ? "軟體更新" : "Software Updates").font(.headline)
            Toggle(zh ? "自動檢查更新" : "Automatically check for updates", isOn: Binding(
                get: { updates.updater.automaticallyChecksForUpdates },
                set: { updates.updater.automaticallyChecksForUpdates = $0 }))
            Toggle(zh ? "自動下載並於結束 App 時安裝" : "Download updates and install when quitting", isOn: Binding(
                get: { updates.updater.automaticallyDownloadsUpdates },
                set: { updates.updater.automaticallyDownloadsUpdates = $0 }))
            Button(zh ? "檢查更新…" : "Check for Updates…") { updates.check() }.disabled(!updates.canCheck)
            Text(zh ? "錄音、轉錄與背景整理完成前，不會為了更新重新啟動。" : "Updates wait for recording, transcription and cleanup before restarting.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(16)
    }
}

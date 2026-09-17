import AppKit
import SwiftUI
import UTUVOTypeCore

/// 本機引擎安裝狀態：popover 的首次啟動卡與設定頁共用同一個，避免兩邊各跑一個 bootstrap。
@MainActor
final class EngineInstaller: ObservableObject {
    static let shared = EngineInstaller()

    @Published private(set) var isInstalling = false
    @Published private(set) var log = ""
    @Published private(set) var lastLine = ""
    @Published private(set) var installed = false
    @Published private(set) var failed = false
    /// 失敗原因的人話版（EngineInstallDiagnosis）；成功／未跑＝nil。
    @Published private(set) var diagnosis: EngineInstallDiagnosis?
    private var cancelledByUser = false
    /// 找不到引擎腳本（既非 repo 也非 bundle 內建）就是 nil；此時不顯示安裝步驟。
    @Published private(set) var root: String?

    private init() {
        refresh()
        #if DEBUG
        // 截圖／走查用：UTUVO_TYPE_DEBUG_INSTALL_FAILURE=xcodeLicense|network|wheel|unknown
        // 把 installer 擺成「剛失敗」的樣子（引擎視為未安裝），不真的跑 bootstrap。
        if let scenario = ProcessInfo.processInfo.environment["UTUVO_TYPE_DEBUG_INSTALL_FAILURE"] {
            seedFailure(scenario: scenario)
        }
        #endif
    }

    #if DEBUG
    private func seedFailure(scenario: String) {
        let logs: [String: String] = [
            "xcodeLicense": """
            [bootstrap] venv 已存在，跳過建立
            [bootstrap] 安裝相依套件（requirements.txt）
              × Building wheel for webrtcvad (pyproject.toml) did not run successfully.
              You have not agreed to the Xcode license agreements. Please run 'sudo xcodebuild -license' from within a Terminal window to review and agree to the Xcode and Apple SDKs license.
              error: Command '['clang', ...]' returned non-zero exit status 69.
            ERROR: Failed building wheel for webrtcvad
            [bootstrap] ERROR: pip 安裝失敗
            """,
            "network": "curl: (28) Failed to connect to github.com port 443 after 30001 ms\n[bootstrap] ERROR: 下載獨立版 Python 失敗；請檢查網路後重跑",
            "wheel": "ERROR: No matching distribution found for some-package==1.0\n[bootstrap] ERROR: pip 安裝失敗",
            "unknown": "[bootstrap] ERROR: something new happened",
        ]
        log = logs[scenario] ?? logs["unknown"]!
        failed = true
        installed = false
        diagnosis = EngineInstallDiagnosis.diagnose(log: log)
    }
    #endif

    func refresh() {
        root = RuntimeBootstrap.locateRepoRoot()
        #if DEBUG
        if ProcessInfo.processInfo.environment["UTUVO_TYPE_DEBUG_INSTALL_FAILURE"] != nil { installed = false; return }
        #endif
        installed = root.map { RuntimeBootstrap.isEngineInstalled(root: $0) } ?? false
    }

    func install(tr: @escaping (String, String) -> String) {
        guard !isInstalling, let root else { return }
        isInstalling = true
        failed = false
        diagnosis = nil
        cancelledByUser = false
        log = ""
        lastLine = tr("準備安裝…", "Preparing…")
        // 字串先算好再進 @Sendable closure（closure 不能抓非 Sendable 的 tr）。
        let doneText = tr("\n[install] 完成。本機引擎已可用。\n", "\n[install] Done. The local engine is ready.\n")
        let failText = tr("\n[install] 安裝失敗；依上方訊息修正後重跑。\n", "\n[install] Failed; fix per the messages above and rerun.\n")
        RuntimeBootstrap.run(
            root: root,
            onChunk: { [weak self] chunk in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.log += chunk
                    let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { self.lastLine = trimmed }
                }
            },
            completion: { [weak self] ok in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isInstalling = false
                    self.failed = !ok
                    self.diagnosis = ok ? nil : EngineInstallDiagnosis.diagnose(log: self.log, cancelled: self.cancelledByUser)
                    self.log += ok ? doneText : failText
                    self.refresh()
                }
            }
        )
    }

    func cancel() {
        cancelledByUser = true
        RuntimeBootstrap.terminateActive()
    }
}

/// 首次啟動三步驟卡（popover）：權限 → 本機引擎 → 試一次。
/// 三步全綠就自動收起並記住；也可以手動略過。之後權限掉了由原本的 permissionCard 接手。
struct OnboardingCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var preferences: AppPreferences
    @ObservedObject private var installer = EngineInstaller.shared
    let onCompleted: () -> Void

    /// 截圖／預覽用：不管實際狀態都畫出來（步驟勾勾照真實狀態）。
    nonisolated(unsafe) static var forceShow = false

    static let completedKey = "utuvo.type.app.onboardingCompleted"
    static var isCompleted: Bool {
        UserDefaults.standard.bool(forKey: completedKey)
    }
    static func markCompleted() {
        UserDefaults.standard.set(true, forKey: completedKey)
    }

    private var permissionsDone: Bool { model.microphonePermissionReady && model.accessibilityPermissionReady }
    private var engineDone: Bool { installer.installed || preferences.backend == .bailian }
    private var triedDone: Bool { !model.lastOutput.isEmpty || !preferences.historyRecords.isEmpty }
    private var allDone: Bool { permissionsDone && engineDone && triedDone }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "hand.wave.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppBrand.accent)
                Text(preferences.tr("三步驟開始聽寫", "Three steps to start dictating"))
                    .font(AppBrand.ui(13, weight: .semibold))
                    .foregroundStyle(AppBrand.retroText)
                Spacer()
                Button(preferences.tr("略過", "Skip")) { finish() }
                    .font(AppBrand.ui(10, weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(AppBrand.retroMuted)
            }

            step(1, done: permissionsDone,
                 title: preferences.tr("允許麥克風與輔助使用", "Allow Microphone and Accessibility"),
                 detail: preferences.tr("錄音要麥克風；貼回輸入框要輔助使用。App 從不讀整個螢幕。",
                                        "Microphone to record; Accessibility to paste back. The app never reads the screen.")) {
                if !permissionsDone {
                    actionButton(preferences.tr("開啟系統設定", "Open System Settings"), icon: "arrow.up.forward.app") {
                        model.openMissingPermissionSettings()
                    }
                }
            }

            step(2, done: engineDone,
                 title: preferences.tr("安裝本機引擎", "Install the local engine"),
                 detail: engineDetail) {
                engineAction
            }

            step(3, done: triedDone,
                 title: preferences.tr("說一句試試", "Say something"),
                 detail: preferences.tr("按 \(shortcutName)，說完再按一次（或放開），文字就貼到游標所在的地方。",
                                        "Press \(shortcutName), speak, press again (or release). The text lands at your cursor.")) {
                EmptyView()
            }
        }
        .padding(14)
        .popoverCard(cornerRadius: 16, rim: AppBrand.accent, rimOpacity: 0.55)
        .onChange(of: allDone) { _, done in
            if done { finish() }
        }
        .onAppear {
            installer.refresh()
            // 已經三步全綠的使用者（升級上來的）第一次看到就直接收起；截圖強制顯示時不寫入。
            if allDone && !Self.forceShow { finish() }
        }
    }

    private var shortcutName: String {
        preferences.activeFallbackShortcut
            ?? (preferences.globalShortcut.isEmpty ? preferences.tr("快捷鍵", "the shortcut") : preferences.globalShortcut)
    }

    private var engineDetail: String {
        if installer.installed {
            return preferences.tr("Qwen3-ASR 0.6B 已就緒，聽寫完全在本機。", "Qwen3-ASR 0.6B is ready; dictation stays on this Mac.")
        }
        if preferences.backend == .bailian {
            return preferences.tr("你選了雲端後端，可略過本機引擎。", "Cloud backend selected; the local engine is optional.")
        }
        if !HardwareProfile.isAppleSilicon {
            return preferences.tr("這台不是 Apple Silicon，跑不了本機引擎；請到設定 → 雲端加入 API key。",
                                  "This Mac is not Apple silicon, so the local engine can't run; add an API key under Settings → Cloud.")
        }
        if installer.isInstalling {
            return installer.lastLine
        }
        if installer.failed {
            // 原因與修法由下方 EngineInstallFailureView 講，這裡只留一句。
            return preferences.tr("安裝沒有完成，下面有原因與修法。", "The install didn’t finish; cause and fix are below.")
        }
        let memory = Int(HardwareProfile.physicalMemoryGB.rounded())
        let base = preferences.tr("下載 Qwen3-ASR 0.6B（約 1.2 GB，一次性）到你的 Application Support。",
                                  "Downloads Qwen3-ASR 0.6B (about 1.2 GB, once) into your Application Support folder.")
        if memory < 8 {
            return base + preferences.tr(" 記憶體 \(memory) GB：建議只用 Fast 模式。", " With \(memory) GB of memory, Fast mode is recommended.")
        }
        return base
    }

    @ViewBuilder
    private var engineAction: some View {
        if engineDone || !HardwareProfile.isAppleSilicon || installer.root == nil {
            EmptyView()
        } else if installer.isInstalling {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(preferences.tr("安裝中…可以先關掉這個面板", "Installing… you can close this panel"))
                    .font(AppBrand.ui(10))
                    .foregroundStyle(AppBrand.retroMuted)
                Spacer()
                Button(preferences.tr("取消", "Cancel")) { installer.cancel() }
                    .font(AppBrand.ui(10, weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(AppBrand.retroMuted)
            }
        } else if installer.failed, let diagnosis = installer.diagnosis {
            EngineInstallFailureView(preferences: preferences, diagnosis: diagnosis, log: installer.log, compact: true) {
                installer.install(tr: preferences.tr)
            }
            .padding(.top, 4)
        } else {
            actionButton(
                installer.failed ? preferences.tr("重試安裝", "Retry install") : preferences.tr("安裝本機引擎", "Install local engine"),
                icon: "arrow.down.circle.fill"
            ) {
                installer.install(tr: preferences.tr)
            }
        }
    }

    private func step<Action: View>(
        _ number: Int, done: Bool, title: String, detail: String, @ViewBuilder action: () -> Action
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle().fill(done ? AppBrand.retroGreen.opacity(0.18) : AppBrand.accent.opacity(0.14))
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(AppBrand.retroGreen)
                } else {
                    Text("\(number)")
                        .font(AppBrand.ui(11, weight: .bold))
                        .foregroundStyle(AppBrand.accent)
                }
            }
            .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(AppBrand.ui(12, weight: .semibold))
                    .foregroundStyle(done ? AppBrand.retroMuted : AppBrand.retroText)
                    .strikethrough(done, color: AppBrand.retroMuted.opacity(0.6))
                Text(detail)
                    .font(AppBrand.ui(10))
                    .foregroundStyle(AppBrand.retroMuted)
                    .fixedSize(horizontal: false, vertical: true)
                action()
            }
            Spacer(minLength: 0)
        }
    }

    private func actionButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(AppBrand.ui(11, weight: .semibold))
        }
        .glassProminentButton()
        .controlSize(.small)
        .padding(.top, 2)
    }

    private func finish() {
        Self.markCompleted()
        onCompleted()
    }
}

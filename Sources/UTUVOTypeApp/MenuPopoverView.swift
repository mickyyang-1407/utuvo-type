import AppKit
import SwiftUI
import UTUVOTypeCore

struct MenuPopoverView: View {
    @ObservedObject var model: AppModel
    // mode／backend 等狀態住在 preferences（另一個 ObservableObject）；
    // 不宣告 @ObservedObject 的話點模式卡有改值但畫面不重繪，看起來像壞掉。
    @ObservedObject private var preferences: AppPreferences
    // 首次啟動硬體判定卡：看過／套用過就不再出現，設定裡永遠可以改。
    @State private var hardwareCardDismissed = UserDefaults.standard.bool(forKey: AppPreferences.Keys.hardwareCardDismissed)
    // 首次啟動三步驟卡：三步全綠或按略過就收起；之後權限掉了由 permissionCard 接手。
    @State private var onboardingCompleted = OnboardingCard.isCompleted
    let onOpenSettings: () -> Void
    let onClose: () -> Void
    let onQuit: () -> Void

    init(
        model: AppModel,
        onOpenSettings: @escaping () -> Void,
        onClose: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.model = model
        self._preferences = ObservedObject(wrappedValue: model.preferences)
        self.onOpenSettings = onOpenSettings
        self.onClose = onClose
        self.onQuit = onQuit
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(spacing: 14) {
                    if !onboardingCompleted || OnboardingCard.forceShow {
                        OnboardingCard(model: model, preferences: preferences) {
                            onboardingCompleted = true
                        }
                    } else {
                        if model.needsPermissionSetup {
                            permissionCard
                        }
                        if !hardwareCardDismissed {
                            hardwareCard
                        }
                    }
                    if let conflict = preferences.hotkeyConflict {
                        hotkeyConflictCard(conflict)
                    }
                    statusCard
                    modeGrid
                    primaryAction
                    quickActions

                    if !model.lastOutput.isEmpty {
                        recentResult
                    }

                    footer
                }
                .padding(16)
            }
            .scrollIndicators(.hidden)
        }
        .frame(width: 370, height: 570)
        .tint(AppBrand.accent)
        .popoverSurface()
        .colorScheme(AppBrand.colorScheme)
    }

    private var header: some View {
        HStack(spacing: 12) {
            brandMark
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 3) {
                Text("UTUVO Type")
                    .font(AppBrand.ui(16, weight: .semibold))
                    .foregroundStyle(AppBrand.retroText)
                HStack(spacing: 6) {
                    statusBadge(
                        model.preferences.backend == .local
                            ? preferences.tr("本機", "Local")
                            : preferences.tr("雲端", "Cloud"),
                        color: model.preferences.backend == .local ? AppBrand.retroGreen : AppBrand.accent
                    )
                    statusBadge(
                        model.isRecording ? preferences.tr("錄音中", "Live") : preferences.tr("就緒", "Ready"),
                        color: model.isRecording ? AppBrand.accent : AppBrand.retroGreen
                    )
                }
            }

            Spacer()

            Button(action: {
                onClose()
                onOpenSettings()
            }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AppBrand.retroMuted)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(AppBrand.retroPanel.opacity(0.6)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(preferences.tr("開啟設定", "Open Settings"))
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    /// 小徽章：狀態一眼看得到，但不搶主角。
    private func statusBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(AppBrand.ui(10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(color.opacity(0.14)))
    }

    /// 品牌 icon 本身就是 Liquid Glass 質感的 squircle，不再包一層玻璃框。
    private var brandMark: some View {
        Group {
            if let url = Bundle.main.url(forResource: "utuvo-type-logo", withExtension: "png"),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "character.cursor.ibeam")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AppBrand.accent)
            }
        }
        .shadow(color: AppBrand.accent.opacity(0.25), radius: 6, y: 3)
        .pulseGlow(active: model.isRecording, color: AppBrand.accent)
    }

    private var statusCard: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.18))
                    .overlay(Circle().strokeBorder(statusColor.opacity(0.5), lineWidth: 1))
                Image(systemName: statusIcon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(statusColor)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 3) {
                Text(statusTitle)
                    .font(AppBrand.ui(14, weight: .semibold))
                    .foregroundStyle(AppBrand.retroText)
                Text(statusSubtitle)
                    .font(AppBrand.ui(11))
                    .foregroundStyle(AppBrand.retroMuted)
                    .lineLimit(2)
                Text(preferences.tr("貼到 \(model.currentAppName)", "Paste into \(model.currentAppName)"))
                    .font(AppBrand.ui(10, weight: .medium))
                    .foregroundStyle(AppBrand.retroMuted.opacity(0.85))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .popoverCard(cornerRadius: 16, rim: AppBrand.accent, rimOpacity: 0.25)
        .pulseGlow(active: model.isRecording, color: AppBrand.accent)
    }

    private var permissionCard: some View {
        let microphoneMissing = !model.microphonePermissionReady
        let accessibilityMissing = !model.accessibilityPermissionReady
        let title: String = {
            if microphoneMissing && accessibilityMissing {
                return preferences.tr("先完成一次系統授權", "One-time system permissions needed")
            }
            if microphoneMissing {
                return preferences.tr("還缺麥克風權限", "Microphone permission missing")
            }
            return preferences.tr("還缺輔助使用權限", "Accessibility permission missing")
        }()
        let detail: String = {
            if microphoneMissing && accessibilityMissing {
                return preferences.tr(
                    "需要麥克風與輔助使用，才能錄音並貼回目前輸入框。",
                    "Microphone and Accessibility are required to record and paste into the current input field."
                )
            }
            if microphoneMissing {
                return preferences.tr(
                    "輔助使用已完成；只需要開啟麥克風即可開始聽寫。",
                    "Accessibility is done; just enable the microphone to start dictating."
                )
            }
            return preferences.tr(
                "麥克風已完成；只需要開啟輔助使用即可貼回文字。",
                "Microphone is done; just enable Accessibility to paste text back."
            )
        }()
        let buttonTitle: String = {
            if microphoneMissing && accessibilityMissing {
                return preferences.tr("開啟系統權限", "Open System Permissions")
            }
            if microphoneMissing {
                return preferences.tr("開啟麥克風設定", "Open Microphone Settings")
            }
            return preferences.tr("開啟輔助使用設定", "Open Accessibility Settings")
        }()

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppBrand.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(AppBrand.ui(12, weight: .semibold))
                        .foregroundStyle(AppBrand.retroText)
                    Text(detail)
                        .font(AppBrand.ui(10))
                        .foregroundStyle(AppBrand.retroMuted)
                }
            }

            Button {
                model.openMissingPermissionSettings()
            } label: {
                Label(buttonTitle, systemImage: "arrow.up.forward.app")
                    .font(.callout.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .glassProminentButton()
        }
        .padding(14)
        .popoverCard(cornerRadius: 16, rim: AppBrand.accent, rimOpacity: 0.60)
    }

    /// 開源防呆：首次啟動依硬體判定建議路徑（判定表見 docs/OPEN-SOURCE-READINESS.md §一）。
    /// 一鍵套用後永遠可在設定改；按過任一鈕就不再出現。
    private var hardwareCard: some View {
        let recommendation = HardwareProfile.recommendation()
        let title: String
        let detail: String
        let buttonTitle: String
        let icon: String
        switch recommendation {
        case .fullLocal:
            title = preferences.tr("你的電腦可以完全本機使用 ✓", "This Mac is ready for fully-local use ✓")
            detail = preferences.tr(
                "Apple Silicon、記憶體充足。聽寫不需要網路與 API key。",
                "Apple Silicon with plenty of memory. Dictation needs no network and no API key."
            )
            buttonTitle = preferences.tr("套用完全本機", "Use fully local")
            icon = "checkmark.seal.fill"
        case .localASROnly:
            title = preferences.tr("建議本機聽寫＋快速模式", "Local dictation with Fast mode recommended")
            detail = preferences.tr(
                "記憶體偏小（\(Int(HardwareProfile.physicalMemoryGB.rounded())) GB）。建議用 Fast 模式，避免同時載入本機整理模型。",
                "Limited memory (\(Int(HardwareProfile.physicalMemoryGB.rounded())) GB). Fast mode is recommended; avoid loading the local editor model."
            )
            buttonTitle = preferences.tr("知道了", "Got it")
            icon = "memorychip"
        case .cloudPreferred:
            title = preferences.tr("這台 Mac 建議搭配雲端", "Cloud pairing recommended on this Mac")
            detail = preferences.tr(
                "非 Apple Silicon 無法跑本機 mlx 引擎；可在設定加入雲端 API key，或使用 macOS 內建語音辨識。",
                "Non-Apple Silicon cannot run the local mlx engine. Add a cloud API key in Settings or use built-in macOS speech recognition."
            )
            buttonTitle = preferences.tr("知道了", "Got it")
            icon = "cloud"
        }

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(recommendation == .fullLocal ? AppBrand.retroGreen : AppBrand.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(AppBrand.ui(12, weight: .semibold))
                        .foregroundStyle(AppBrand.retroText)
                    Text(detail)
                        .font(AppBrand.ui(10))
                        .foregroundStyle(AppBrand.retroMuted)
                }
            }

            Button {
                if recommendation == .fullLocal {
                    preferences.backend = .local
                }
                dismissHardwareCard()
            } label: {
                Label(buttonTitle, systemImage: recommendation == .fullLocal ? "sparkles" : "hand.wave")
                    .font(.callout.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .glassProminentButton()
        }
        .padding(14)
        .popoverCard(cornerRadius: 16, rim: AppBrand.accent, rimOpacity: 0.35)
    }

    private func dismissHardwareCard() {
        hardwareCardDismissed = true
        UserDefaults.standard.set(true, forKey: AppPreferences.Keys.hardwareCardDismissed)
    }

    private func hotkeyConflictCard(_ conflict: HotkeyConflictInfo) -> some View {
        let suspectName = conflict.suspectsDisplayName(zh: preferences.isChineseUI)
        // 退路模式（initial -9878 / Carbon 註冊失敗）：抄 HK1 舊文案，沒人自動取回。
        // 執行期被搶（onStolen）：標題加「已自動取回」，副標說 Type 會持續 reclaim。
        let inFallbackMode = preferences.activeFallbackShortcut != nil
        let title: String
        let reclaimedLine: String?
        if inFallbackMode {
            title = preferences.tr(
                "\(conflict.shortcut) 已被 \(suspectName) 佔用",
                "\(conflict.shortcut) is taken by \(suspectName)"
            )
            reclaimedLine = nil
        } else {
            title = preferences.tr(
                "\(conflict.shortcut) 與 \(suspectName) 撞鍵（已自動取回）",
                "\(conflict.shortcut) collides with \(suspectName) (reclaimed)"
            )
            reclaimedLine = preferences.tr(
                "Type 每次被搶都會自動取回；想根治請到下面路徑解除。",
                "Type reclaims this shortcut every time it gets taken; unbind it at the path below for a permanent fix."
            )
        }
        let unbindHint: String? = preferences.isChineseUI ? conflict.firstUnbindHintZH : conflict.firstUnbindHintEN
        let fallbackLine = preferences.activeFallbackShortcut.map { fallback in
            preferences.tr(
                "目前暫用 \(fallback)，解除後按重試即可回到 \(conflict.shortcut)",
                "Temporarily using \(fallback); press Retry after unbind to go back to \(conflict.shortcut)"
            )
        }

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "keyboard.badge.ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppBrand.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(AppBrand.ui(12, weight: .semibold))
                        .foregroundStyle(AppBrand.retroText)
                    if let unbindHint {
                        Text(preferences.tr("解除路徑：\(unbindHint)", "How to free it: \(unbindHint)"))
                            .font(AppBrand.ui(10))
                            .foregroundStyle(AppBrand.retroMuted)
                    } else {
                        Text(preferences.tr(
                            "找不到確切來源；請檢查其他啟動中的 App 或登出再試一次。",
                            "No known culprit; check other running apps or retry after closing them."
                        ))
                        .font(AppBrand.ui(10))
                        .foregroundStyle(AppBrand.retroMuted)
                    }
                    if let fallbackLine {
                        Text(fallbackLine)
                            .font(AppBrand.ui(10, weight: .medium))
                            .foregroundStyle(AppBrand.accent.opacity(0.85))
                    }
                    if let reclaimedLine {
                        Text(reclaimedLine)
                            .font(AppBrand.ui(10, weight: .medium))
                            .foregroundStyle(AppBrand.retroGreen.opacity(0.90))
                    }
                }
            }

            HStack(spacing: 8) {
                Button {
                    preferences.onShortcutRetry?()
                } label: {
                    Label(
                        preferences.tr("重試", "Retry"),
                        systemImage: "arrow.clockwise"
                    )
                    .font(.callout.weight(.semibold))
                    .frame(maxWidth: .infinity)
                }
                .glassProminentButton()

                Button {
                    preferences.globalShortcut = AppPreferences.conflictFallbackShortcut
                } label: {
                    Label(
                        preferences.tr("改用 \(AppPreferences.conflictFallbackShortcut)", "Use \(AppPreferences.conflictFallbackShortcut)"),
                        systemImage: "keyboard"
                    )
                    .font(.callout.weight(.semibold))
                    .frame(maxWidth: .infinity)
                }
                .glassButton()

                Button {
                    preferences.hotkeyConflict = nil
                } label: {
                    Label(
                        preferences.tr("知道了", "Dismiss"),
                        systemImage: "checkmark"
                    )
                    .font(.callout.weight(.semibold))
                    .frame(maxWidth: .infinity)
                }
                .glassButton()
            }
        }
        .padding(14)
        .popoverCard(cornerRadius: 16, rim: AppBrand.accent, rimOpacity: 0.60)
    }

    private var modeGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(preferences.tr("模式", "Modes"))
                .font(AppBrand.ui(11, weight: .semibold))
                .foregroundStyle(AppBrand.retroMuted)
                .padding(.leading, 4)

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                spacing: 8
            ) {
                modeTile(.fast, title: "Fast Dictate", subtitle: preferences.tr("最快・不呼叫 LLM", "Fastest · no LLM call"), icon: "bolt.fill")
                modeTile(.smart, title: "Smart Dictate", subtitle: preferences.tr("本機小型 editor", "Small on-device editor"), icon: "sparkles")
                modeTile(.editSelection, title: "Edit Selection", subtitle: preferences.tr("改寫目前選取", "Rewrite current selection"), icon: "text.badge.checkmark")
                modeTile(.deep, title: "Deep / Long Note", subtitle: deepModeSubtitle, icon: "doc.text")
            }
        }
    }

    /// Deep 到底走什麼，照當下設定據實顯示（D8-2，2026-09-11）。
    /// 舊文案寫死「手動模式・27B 關閉」，設了本機 model 之後就是假的。
    private var deepModeSubtitle: String {
        if !preferences.localDeepModel.isEmpty {
            return preferences.tr("本機 Deep・\(preferences.localDeepModel)", "Local deep · \(preferences.localDeepModel)")
        }
        if preferences.backend == .bailian {
            return preferences.tr("雲端 qwen3.7-plus", "Cloud qwen3.7-plus")
        }
        return preferences.tr("未設 Deep model・照 Smart 走", "No deep model set · behaves like Smart")
    }

    private func modeTile(
        _ mode: FormatterMode,
        title: String,
        subtitle: String,
        icon: String
    ) -> some View {
        let selected = model.preferences.mode == mode
        return Button {
            model.preferences.mode = mode
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    ZStack {
                        Circle().fill(selected ? AppBrand.accent.opacity(0.16) : AppBrand.retroMuted.opacity(0.12))
                        Image(systemName: icon)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(selected ? AppBrand.accent : AppBrand.retroMuted)
                    }
                    .frame(width: 26, height: 26)
                    Spacer(minLength: 0)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(selected ? AppBrand.accent : AppBrand.retroMuted.opacity(0.45))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(AppBrand.ui(12, weight: .semibold))
                        .foregroundStyle(AppBrand.retroText)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(AppBrand.ui(10))
                        .foregroundStyle(AppBrand.retroMuted)
                        .lineLimit(1)
                }
            }
            .padding(11)
            .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
            .popoverTile(selected: selected, cornerRadius: 12)
        }
        .buttonStyle(.plain)
    }

    private var primaryAction: some View {
        Button {
            model.toggleRecordingFromUI()
            onClose()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: model.isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 17, weight: .bold))
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.isRecording
                         ? preferences.tr("停止・整理貼上", "Stop · Clean up & paste")
                         : preferences.tr("開始聽寫", "Start dictation"))
                        .font(AppBrand.ui(14, weight: .semibold))
                    Text(model.isRecording
                         ? preferences.tr("完成轉錄後貼到目前輸入框", "Pastes into the current input field after transcription")
                         : (model.preferences.globalShortcut.isEmpty
                            ? preferences.tr("未設定快捷鍵・仍可點擊按鈕", "No shortcut set · you can still click this button")
                            : preferences.tr("快捷鍵  \(model.preferences.globalShortcut)", "Shortcut  \(model.preferences.globalShortcut)")))
                        .font(AppBrand.ui(10))
                        .opacity(0.85)
                }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 13, weight: .bold))
                    .opacity(0.75)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 70)
            .popoverPrimary(
                color: model.isRecording ? Color.red : AppBrand.accent,
                gradient: model.isRecording ? nil : AppBrand.accentGradient,
                cornerRadius: 14
            )
            .pulseGlow(active: model.isRecording, color: AppBrand.accent)
        }
        .buttonStyle(.plain)
        .disabled(model.isProcessing)
    }

    private var quickActions: some View {
        HStack(spacing: 8) {
            quickAction(
                title: "Edit Selection",
                icon: "square.and.pencil",
                action: { model.startRecording(mode: .editSelection); onClose() }
            )
            quickAction(
                title: "Deep / Long Note",
                icon: "doc.text",
                action: { model.startRecording(mode: .deep); onClose() }
            )
        }
    }

    private func quickAction(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .glassButton()
        .controlSize(.large)
        .foregroundStyle(AppBrand.retroText)
        .disabled(model.isRecording || model.isProcessing)
    }

    private var recentResult: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(preferences.tr("最近結果", "Recent result"), systemImage: "text.alignleft")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button(preferences.tr("複製", "Copy")) { model.copyLastOutput() }
                    .font(.caption.weight(.medium))
                    .buttonStyle(.borderless)
            }

            Text(model.lastOutput)
                .font(AppBrand.ui(11))
                .foregroundStyle(AppBrand.retroText)
                .lineLimit(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .popoverCard(cornerRadius: 14)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 10, weight: .semibold))
            Text(model.preferences.pushToTalkEnabled
                 ? preferences.tr("Push to Talk・本機優先", "Push to Talk · local-first")
                 : preferences.tr("本機優先・Fast 不呼叫大模型", "Local-first · Fast never calls a large model"))
                .font(AppBrand.ui(10))
            Spacer()
            if model.isProcessing {
                Button(preferences.tr("取消", "Cancel")) { model.cancelProcessing() }
                    .font(.caption2.weight(.semibold))
                    .buttonStyle(.borderless)
            }
            Button(preferences.tr("結束", "Quit")) { onQuit() }
                .font(.caption2.weight(.semibold))
                .buttonStyle(.borderless)
        }
        .foregroundStyle(AppBrand.retroMuted)
        .padding(.horizontal, 2)
    }

    private var statusTitle: String {
        if model.isRecording { return preferences.tr("正在聆聽", "Listening") }
        if model.isProcessing { return preferences.tr("正在整理並貼上", "Cleaning up & pasting") }
        return preferences.tr("準備就緒", "Ready")
    }

    private var statusSubtitle: String {
        if model.isRecording {
            return preferences.tr("說完後再次按下停止；本機 ASR 會接手轉錄", "Press again to stop; local ASR takes over transcription")
        }
        if model.isProcessing { return model.statusMessage }
        if model.preferences.pushToTalkEnabled {
            let shortcut = model.preferences.globalShortcut.isEmpty
                ? preferences.tr("快捷鍵", "the shortcut")
                : model.preferences.globalShortcut
            return preferences.tr("按住 \(shortcut) 說話，放開即停止並貼上", "Hold \(shortcut) to talk; release to stop and paste")
        }
        return "Qwen3-ASR 0.6B  →  deterministic normalizer"
    }

    private var statusIcon: String {
        if model.isRecording { return "record.circle" }
        if model.isProcessing { return "hourglass" }
        return "checkmark.seal"
    }

    private var statusColor: Color {
        if model.isRecording { return AppBrand.accent }
        if model.isProcessing { return .yellow }
        return AppBrand.retroGreen
    }
}

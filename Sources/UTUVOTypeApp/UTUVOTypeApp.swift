@preconcurrency import AppKit
import Carbon.HIToolbox
import OSLog
import ServiceManagement
import SwiftUI
import UTUVOTypeCore

@main
struct UTUVOTypeAppMain {
    // CLI 介面：第二個進程只發通知給運行中的 app 然後退出。
    static let cliNotification = Notification.Name("com.utuvo.type.cli-command")
    private static let cliCommands: Set<String> = [
        "--toggle-transcription", "--cancel", "--toggle-post-process"
    ]

    static func main() {
        let arguments = CommandLine.arguments.dropFirst()
        if let command = arguments.first(where: { cliCommands.contains($0) }) {
            DistributedNotificationCenter.default().postNotificationName(
                cliNotification,
                object: command,
                userInfo: nil,
                deliverImmediately: true
            )
            exit(0)
        }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let logger = Logger(subsystem: "com.utuvo.type", category: "appdelegate")
    private let model = AppModel()
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var settingsWindow: NSWindow?
    private var globalShortcut: GlobalShortcut?
    private var translationShortcuts: [GlobalShortcut] = []
    private var postProcessingShortcut: GlobalShortcut?
    private var escapeGlobalMonitor: Any?
    private var escapeLocalMonitor: Any?
    private var appearanceObservation: NSKeyValueObservation?
    private let overlayController = OverlayWindowController()
    /// 同一個 session 內重複被搶只在 60 秒後才再刷一次狀態列；衝突卡每次都更新
    /// （搶的對象可能換了）。
    private var lastStealNotice: Date?
    private let stealNoticeInterval: TimeInterval = 60

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 截圖模式：只建 status item＋popover＋設定視窗，拍完就退出。
        // 不裝熱鍵、不碰 TCC、不寫 preferences——跟正式安裝版共用同一個 defaults domain。
        if let snapshotDirectory = ProcessInfo.processInfo.environment["UTUVO_TYPE_SNAPSHOT_DIR"] {
            runSnapshotMode(outputDirectory: snapshotDirectory)
            return
        }
        model.onStateChange = { [weak self] in
            self?.rebuildMenu()
            self?.updateOverlay()
        }
        model.preferences.onShortcutChange = { [weak self] in
            self?.installGlobalShortcut(announce: true)
        }
        model.preferences.onShortcutRetry = { [weak self] in
            self?.retryPreferredShortcut()
        }
        model.preferences.onPostProcessingShortcutChange = { [weak self] in
            self?.installPostProcessingShortcut()
        }
        model.preferences.onAppBehaviorChange = { [weak self] in
            self?.applyAppBehaviorPreferences()
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.isVisible = true
        item.button?.image = brandImage()
        if let button = item.button {
            configureStatusButton(button)
        }
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        item.button?.sendAction(on: [.leftMouseUp])
        statusItem = item
        applyAppBehaviorPreferences()
        installEscapeMonitors()

        // CLI 命令（--toggle-transcription／--cancel／--toggle-post-process）：
        // 只接受固定白名單，object 內容非白名單一律忽略。--start-hidden／--no-tray
        // 由本進程啟動參數處理（見下）。
        DistributedNotificationCenter.default().addObserver(
            forName: UTUVOTypeAppMain.cliNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let command = notification.object as? String
            Task { @MainActor in
                switch command {
                case "--toggle-transcription": self?.model.toggleRecordingFromUI()
                case "--cancel": self?.model.cancelRecording()
                case "--toggle-post-process":
                    self?.model.preferences.postProcessingEnabled.toggle()
                default: break
                }
            }
        }
        if CommandLine.arguments.contains("--no-tray") {
            statusItem?.isVisible = false
        }

        // 錄製快捷鍵期間暫停自家全域熱鍵：否則按目前綁定的鍵（F14）會被 Carbon
        // 搶去開始錄音，錄製器永遠錄不到同一顆鍵。結束（含取消）後恢復。
        NotificationCenter.default.addObserver(
            forName: HotkeyCaptureButton.captureDidBegin, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.model.shortcutReleased()
                self.globalShortcut = nil
                self.translationShortcuts = []
                self.postProcessingShortcut = nil
            }
        }
        NotificationCenter.default.addObserver(
            forName: HotkeyCaptureButton.captureDidEnd, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.globalShortcut == nil { self.installGlobalShortcut() }
                if self.postProcessingShortcut == nil { self.installPostProcessingShortcut() }
            }
        }

        // 主題「跟隨系統」要能跟著 macOS 深淺色即時切換；
        // palette 是在重繪時讀 AppBrand，這裡只要促發重繪。
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in
                self?.model.preferences.objectWillChange.send()
                self?.model.onStateChange?()
            }
        }

        self.popover = makePopover()
        rebuildMenu()
        installGlobalShortcut()
        installPostProcessingShortcut()
    }

    private func makePopover() -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentSize = NSSize(width: 370, height: 570)
        popover.contentViewController = NSHostingController(
            rootView: MenuPopoverView(
                model: model,
                onOpenSettings: { [weak self] in self?.showSettings(nil) },
                onClose: { [weak self] in self?.popover?.performClose(nil) },
                onQuit: { NSApp.terminate(nil) }
            )
        )
        return popover
    }

    /// 設定視窗：macOS 26／27 語彙——標題列透明、內容延伸到頂，側欄與卡片浮在 AmbientBackdrop 上。
    private func makeSettingsWindow(initialSection: SettingsSection = .general) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_100, height: 760),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = model.preferences.tr("\(AppBrand.displayName) 設定", "\(AppBrand.displayName) Settings")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = AppBrand.nsAppearance
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: SettingsView(model: model, initialSection: initialSection))
        // 不讓 SwiftUI 替視窗算 min／max size：那個 pass 會對整個 ScrollView 內容做一次
        // 無上限的 sizeThatFits，一般分頁量到約 1 s（09-17 sample 抓到：
        // NSHostingView.viewDidMoveToWindow → updateWindowContentSizeExtrema → minSize），
        // 而且內容一變就重算＝切分頁也卡。視窗大小限制自己給。
        hosting.sizingOptions = []
        window.contentView = hosting
        window.minSize = NSSize(width: 1_020, height: 680)
        window.center()
        return window
    }

    /// UTUVO_TYPE_SNAPSHOT_DIR=<dir>：拍 popover／設定頁／overlay 膠囊（淡＋深各一輪）後退出。
    private func runSnapshotMode(outputDirectory: String) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.isVisible = true
        item.button?.image = brandImage()
        if let button = item.button { configureStatusButton(button) }
        statusItem = item
        let popover = makePopover()
        self.popover = popover
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await SnapshotRunner.run(
                    outputDirectory: outputDirectory,
                    model: model,
                    showPopover: { [weak self] in
                        guard let self, let popover = self.popover, let button = self.statusItem?.button else { return }
                        popover.appearance = AppBrand.nsAppearance
                        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                    },
                    popoverWindow: { [weak self] in self?.popover?.contentViewController?.view.window },
                    hidePopover: { [weak self] in self?.popover?.performClose(nil) },
                    makeSettingsWindow: { [weak self] section in self?.makeSettingsWindow(initialSection: section) },
                    overlay: overlayController
                )
            } catch {
                FileHandle.standardError.write(Data("[snapshot] failed: \(error)\n".utf8))
            }
            NSApp.terminate(nil)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // System Settings changes TCC outside this process. Re-read the state
        // whenever the user returns instead of showing a stale onboarding card.
        model.refreshPermissionState()
    }

    func applicationWillTerminate(_ notification: Notification) {
        globalShortcut = nil
        postProcessingShortcut = nil
        if let escapeGlobalMonitor { NSEvent.removeMonitor(escapeGlobalMonitor) }
        if let escapeLocalMonitor { NSEvent.removeMonitor(escapeLocalMonitor) }
        // 安裝進行中就退出：terminate bootstrap 子進程，避免孤兒下載（腳本 idempotent，重跑安全）。
        RuntimeBootstrap.terminateActive()
    }

    private func applyAppBehaviorPreferences() {
        statusItem?.isVisible = model.preferences.showTrayIcon
        updateOverlay()
        if #available(macOS 13.0, *) {
            do {
                if model.preferences.launchOnStartup {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                // An ad-hoc development build may not be eligible for a
                // login-item registration. The preference remains saved and
                // the rest of the app is unaffected.
            }
        }
    }

    private func updateOverlay() {
        overlayController.update(model: model, preferences: model.preferences)
    }

    private func installEscapeMonitors() {
        escapeGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == UInt16(kVK_Escape) else { return }
            Task { @MainActor in
                self?.model.cancelRecording()
            }
        }
        escapeLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == UInt16(kVK_Escape) else { return event }
            let shouldConsume = self?.model.isRecording == true || self?.model.isProcessing == true
            Task { @MainActor in
                self?.model.cancelRecording()
            }
            return shouldConsume ? nil : event
        }
    }

    private func rebuildMenu() {
        guard let button = statusItem?.button else { return }
        button.image = brandImage()
        configureStatusButton(button)
    }

    // 只留圖示（2026-08-21 產品決定拿掉「Type」文字）；錄音狀態由 overlay 表達。
    private func configureStatusButton(_ button: NSStatusBarButton) {
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.attributedTitle = NSAttributedString(string: "")
        button.toolTip = model.isProcessing
            ? "\(AppBrand.displayName)：\(model.statusMessage)"
            : AppBrand.displayName
        // 圖本身已是品牌橘（非 template）；tint 留 nil，macOS 26／27 對 template 圖會無視 tint。
        button.contentTintColor = nil
        button.isEnabled = true
    }

    private func brandImage() -> NSImage {
        AppBrand.menuBarImage()
    }

    private func installGlobalShortcut(announce: Bool = false) {
        model.shortcutReleased()
        globalShortcut = nil
        translationShortcuts = []
        // 換鍵時把上一輪的退路／衝突狀態先歸零，success 路徑結束前不再覆寫。
        let hadConflict = model.preferences.hotkeyConflict != nil
            || model.preferences.activeFallbackShortcut != nil
        model.preferences.hotkeyConflict = nil
        model.preferences.activeFallbackShortcut = nil
        guard let spec = ShortcutSpec.parse(model.preferences.globalShortcut) else {
            if announce || hadConflict {
                model.reportShortcutStatus(model.preferences.tr(
                    "快捷鍵已清除；仍可用 menu bar 按鈕開始聽寫",
                    "Shortcut cleared; you can still start dictation from the menu bar button"
                ))
            }
            return
        }
        do {
            globalShortcut = try GlobalShortcut(
                spec: spec,
                onPress: { [weak self] in self?.model.shortcutPressed() },
                onRelease: { [weak self] in
                    self?.model.shortcutReleased(
                        mainKeyStillDown: Self.isKeyDown(spec.keyCode),
                        mainKeyCode: spec.keyCode
                    )
                },
                onStolen: { [weak self] in
                    self?.handleShortcutStolen(spec: spec, translation: .off)
                }
            )
            installTranslationVariants(baseSpec: spec)
            if announce {
                model.reportShortcutStatus(model.preferences.tr(
                    "快捷鍵已更新：\(spec.displayName)",
                    "Shortcut updated: \(spec.displayName)"
                ))
            }
        } catch {
            // 出廠預設被搶：填衝突卡；若屬於出廠預設，再嘗試退路鍵 ⌥\`。
            if case ProviderError.hotkeyTaken = error {
                let conflict = HotkeyConflictInfo(
                    shortcut: spec.displayName,
                    suspects: HotkeyConflictSuspects.running()
                )
                model.preferences.hotkeyConflict = conflict
                if model.preferences.globalShortcut == AppPreferences.factoryDefaultShortcut,
                   let fallbackSpec = ShortcutSpec.parse(AppPreferences.conflictFallbackShortcut) {
                    do {
                        let fallback = try GlobalShortcut(
                            spec: fallbackSpec,
                            onPress: { [weak self] in self?.model.shortcutPressed() },
                            onRelease: { [weak self] in
                                self?.model.shortcutReleased(
                                    mainKeyStillDown: Self.isKeyDown(fallbackSpec.keyCode),
                                    mainKeyCode: fallbackSpec.keyCode
                                )
                            },
                            onStolen: { [weak self] in
                                self?.handleShortcutStolen(spec: fallbackSpec, translation: .off)
                            }
                        )
                        globalShortcut = fallback
                        installTranslationVariants(baseSpec: fallbackSpec)
                        model.preferences.activeFallbackShortcut = fallbackSpec.displayName
                        if announce {
                            model.reportShortcutStatus(model.preferences.tr(
                                "\(spec.displayName) 已被佔用；目前暫用 \(fallbackSpec.displayName)",
                                "\(spec.displayName) is taken; temporarily using \(fallbackSpec.displayName)"
                            ))
                        }
                        model.onStateChange?()
                        return
                    } catch {
                        // 退路也註冊不了：保留衝突卡，使用者必須自己換。
                        if announce {
                            model.reportShortcutStatus(model.preferences.tr(
                                "\(spec.displayName) 被佔用，退路 \(AppPreferences.conflictFallbackShortcut) 也無法註冊：\(error.localizedDescription)",
                                "\(spec.displayName) is taken and fallback \(AppPreferences.conflictFallbackShortcut) also failed: \(error.localizedDescription)"
                            ))
                        }
                    }
                } else if announce {
                    // 使用者自訂鍵被搶：不退路，只告訴他誰搶的。
                    model.reportShortcutStatus(model.preferences.tr(
                        "\(spec.displayName) 已被佔用，請改用別的快捷鍵",
                        "\(spec.displayName) is taken; please pick a different shortcut"
                    ))
                }
                model.onStateChange?()
                return
            }
            if announce {
                model.reportShortcutStatus(error.localizedDescription)
            }
            model.onStateChange?()
        }
    }

    /// 衝突卡「重試」按鈕回呼：直接再走一次註冊流程，announce=true 讓狀態列更新。
    func retryPreferredShortcut() {
        installGlobalShortcut(announce: true)
    }

    /// Listen-only tap 偵測到「使用者按了這顆鍵但 Carbon 沒送 hotKeyPressed」→
    /// 重新註冊（變成最後一個註冊者，拿回熱鍵）、更新衝突卡、補上本次被吃掉的按壓。
    /// 同一 session 重複被搶只每 60 秒刷一次 status（狀態列不再被洗版），衝突卡每次都更新
    /// 因為嫌犯清單會變。
    @MainActor
    private func handleShortcutStolen(spec: ShortcutSpec, translation: TranslationTarget) {
        Self.logger.info("steal-detected keyCode=\(spec.keyCode, privacy: .public) modifier=\(spec.modifiers, privacy: .public)")
        // 1. reclaim：先 main，再 translation variants（fallback 已經是 globalShortcut）
        if let globalShortcut {
            _ = globalShortcut.reclaim()
        }
        for variant in translationShortcuts {
            _ = variant.reclaim()
        }
        // 2. 衝突卡：嫌犯用 running() 重新掃一次。
        let conflict = HotkeyConflictInfo(
            shortcut: spec.displayName,
            suspects: HotkeyConflictSuspects.running()
        )
        model.preferences.hotkeyConflict = conflict
        model.preferences.hotkeyStealCount += 1
        // 3. 狀態列節流 60 秒
        let now = Date()
        let shouldAnnounce: Bool
        if let lastStealNotice {
            shouldAnnounce = now.timeIntervalSince(lastStealNotice) >= stealNoticeInterval
        } else {
            shouldAnnounce = true
        }
        if shouldAnnounce {
            lastStealNotice = now
            let suspectName = conflict.suspectsDisplayName(zh: model.preferences.isChineseUI)
            model.reportShortcutStatus(model.preferences.tr(
                "\(spec.displayName) 被 \(suspectName) 搶走，已自動取回",
                "\(spec.displayName) was taken by \(suspectName); reclaimed"
            ))
        }
        // 4. 補按：使用者按了就該開始錄音，不能讓第一次按壓蒸發。
        model.shortcutPressed(translation: translation)
        // 5. PTT 下 release 也可能收不到（因為 Carbon 沒收到這次 press），
        //    用既有的硬體 watchdog 機制接 release。
        if model.preferences.pushToTalkEnabled,
           let baseSpec = ShortcutSpec.parse(model.preferences.globalShortcut) {
            model.shortcutReleased(
                mainKeyStillDown: true,
                mainKeyCode: baseSpec.keyCode
            )
        }
    }

    /// 即時翻譯：⇧／⌘／⌃＋聽寫快捷鍵各掛一個變體熱鍵。
    /// base 已含該修飾鍵時跳過（避免撞同一組合）；註冊失敗只記狀態不擋主熱鍵。
    private func installTranslationVariants(baseSpec: ShortcutSpec) {
        let slots: [(UInt32, String, UInt32, TranslationTarget)] = [
            (UInt32(shiftKey), "⇧", 3, model.preferences.translationSlotShift),
            (UInt32(cmdKey), "⌘", 4, model.preferences.translationSlotCommand),
            (UInt32(controlKey), "⌃", 5, model.preferences.translationSlotControl)
        ]
        for (modifier, symbol, identifier, target) in slots {
            guard target != .off, baseSpec.modifiers & modifier == 0 else { continue }
            let variant = ShortcutSpec(
                displayName: symbol + baseSpec.displayName,
                keyCode: baseSpec.keyCode,
                modifiers: baseSpec.modifiers | modifier,
                requiresFn: baseSpec.requiresFn
            )
            do {
                let shortcut = try GlobalShortcut(
                    spec: variant,
                    onPress: { [weak self] in self?.model.shortcutPressed(translation: target) },
                    onRelease: { [weak self] in
                        self?.model.shortcutReleased(
                            mainKeyStillDown: Self.isKeyDown(variant.keyCode),
                            mainKeyCode: variant.keyCode
                        )
                    },
                    onStolen: { [weak self] in
                        self?.handleShortcutStolen(spec: variant, translation: target)
                    },
                    identifier: identifier
                )
                translationShortcuts.append(shortcut)
            } catch {
                model.reportShortcutStatus(model.preferences.tr(
                    "翻譯快捷鍵 \(variant.displayName) 無法註冊：\(error.localizedDescription)",
                    "Translation shortcut \(variant.displayName) could not be registered: \(error.localizedDescription)"
                ))
            }
        }
    }

    /// 主鍵此刻是否仍被壓著（硬體狀態）；PTT 靠它分辨「換修飾鍵」與「真的放開」。
    private static func isKeyDown(_ keyCode: UInt32) -> Bool {
        CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(keyCode))
    }

    private func installPostProcessingShortcut() {
        postProcessingShortcut = nil
        guard let spec = ShortcutSpec.parse(model.preferences.postProcessingShortcut) else { return }
        do {
            postProcessingShortcut = try GlobalShortcut(
                spec: spec,
                onPress: { [weak self] in self?.model.reprocessLastResult() },
                identifier: 2
            )
        } catch {
            model.reportShortcutStatus(model.preferences.tr(
                "Post-processing 快捷鍵無法註冊：\(error.localizedDescription)",
                "Post-processing shortcut could not be registered: \(error.localizedDescription)"
            ))
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let popover, let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.appearance = AppBrand.nsAppearance
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            Task { @MainActor in
                await model.ensureFirstUsePermissions()
            }
        }
    }

    @objc private func showSettings(_ sender: Any?) {
        popover?.performClose(sender)
        if let settingsWindow {
            settingsWindow.appearance = AppBrand.nsAppearance
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = makeSettingsWindow()
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }
}

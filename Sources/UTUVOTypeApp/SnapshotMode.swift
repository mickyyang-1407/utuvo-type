import AppKit
import SwiftUI

/// 自己視窗自己拍：CGWindowListCreateImage 抓本進程的視窗不需要螢幕錄製權限
/// （Paw 09-16 同一招）。每個畫面淡色＋深色各一張，輸出 2× PNG。
@MainActor
enum SnapshotRunner {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func run(
        outputDirectory: String,
        model: AppModel,
        showPopover: @MainActor () -> Void,
        popoverWindow: @MainActor () -> NSWindow?,
        hidePopover: @MainActor () -> Void,
        makeSettingsWindow: @MainActor (SettingsSection) -> NSWindow?,
        overlay: OverlayWindowController
    ) async throws {
        let out = URL(fileURLWithPath: outputDirectory)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        NSApp.activate(ignoringOtherApps: true)
        // 自家桌布視窗墊在底下：玻璃要有東西折射，而且 .optionOnScreenBelowWindow 拍到的
        // 就是它，不需要螢幕錄製權限（其他 app 的視窗在它之下、被它蓋住）。
        let backdrop = makeBackdropWindow()
        backdrop.orderFrontRegardless()
        try await settle(ms: 600) // status item 要先掛進 menu bar 視窗，popover 才有錨點
        model.overrideCurrentAppNameForSnapshot("Notes")

        for (suffix, dark) in [("light", false), ("dark", true)] {
            AppBrand.themeChoice = dark ? .dark : .light
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            model.preferences.objectWillChange.send()

            // Popover（首次啟動卡強制顯示）：先拍 onboarding 版
            OnboardingCard.forceShow = true
            model.preferences.objectWillChange.send()
            showPopover()
            try await settle()
            if let window = popoverWindow() {
                try capture(window, to: out.appendingPathComponent("popover-onboarding-\(suffix).png"))
            }
            hidePopover()
            try await settle(ms: 200)
            OnboardingCard.forceShow = false
            model.preferences.objectWillChange.send()

            // Popover：從 status item 真的彈出來，拍到的是 NSPopover 自己的玻璃。
            showPopover()
            try await settle()
            if let window = popoverWindow() {
                try capture(window, to: out.appendingPathComponent("popover-\(suffix).png"))
                // 只含 popover 視窗本身：RGB 不可信（玻璃沒東西折射），但 alpha 是正確的遮罩，
                // 行銷合成圖拿它把桌布切掉。
                try capture(window, to: out.appendingPathComponent("popover-\(suffix)-mask.png"), windowOnly: true)
                hidePopover()
                try await settle(ms: 200)
            } else {
                throw Failure(description: "popover window missing")
            }

            // 設定頁：三個代表性分頁。
            for section in [SettingsSection.general, .models, .cloud] {
                guard let window = makeSettingsWindow(section) else { continue }
                window.level = .modalPanel // 要在 backdrop（.floating）之上
                let t0 = CFAbsoluteTimeGetCurrent()
                window.makeKeyAndOrderFront(nil)
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                let openMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                FileHandle.standardError.write(Data(String(format: "[snapshot] settings-%@-%@ first-frame %.0f ms (glass=%d)\n", section.rawValue, suffix, openMs, TypeGlass.enabled ? 1 : 0).utf8))
                try await settle()
                try capture(window, to: out.appendingPathComponent("settings-\(section.rawValue)-\(suffix).png"))
                window.orderOut(nil)
            }

            // Overlay 膠囊：聆聽中＋處理中。
            for (name, listening) in [("listening", true), ("processing", false)] {
                let panel = overlay.showPreview(model: model, listening: listening, position: .bottom)
                try await settle(ms: 500)
                try capture(panel, to: out.appendingPathComponent("overlay-\(name)-\(suffix).png"))
                overlay.hide()
            }
        }
    }

    private static func settle(ms: Int = 900) async throws {
        try await Task.sleep(for: .milliseconds(ms))
    }

    private static func makeBackdropWindow() -> NSWindow {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .floating
        window.isOpaque = true
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.contentView = NSHostingView(rootView: SnapshotBackdrop())
        return window
    }

    private static func capture(_ window: NSWindow, to url: URL, windowOnly: Bool = false) throws {
        let id = CGWindowID(window.windowNumber)
        // CG 座標：原點在主螢幕左上；window.frame 是 AppKit 座標（左下）。
        let primary = NSScreen.screens[0].frame
        // 留一圈陰影；上緣不擴（popover 貼著 menu bar，擴上去會拍到別人的 status item）
        var frame = window.frame.insetBy(dx: -24, dy: 0)
        frame.origin.y -= 24; frame.size.height += 24
        let cgRect = CGRect(x: frame.minX, y: primary.maxY - frame.maxY, width: frame.width, height: frame.height)
        let options: CGWindowListOption = windowOnly
            ? [.optionIncludingWindow]
            : [.optionOnScreenBelowWindow, .optionIncludingWindow]
        guard let image = CGWindowListCreateImage(cgRect, options, id, [.bestResolution]) else {
            throw Failure(description: "no image for \(url.lastPathComponent)")
        }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw Failure(description: "png encode failed for \(url.lastPathComponent)")
        }
        try data.write(to: url)
        FileHandle.standardError.write(Data("[snapshot] \(url.path) \(image.width)x\(image.height)\n".utf8))
    }
}

/// 截圖用桌布：macOS 26 風的柔和漸層＋色團，讓玻璃有東西折射；也直接當行銷圖底。
private struct SnapshotBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: AppBrand.isDark
                    ? [Color(red: 0.09, green: 0.08, blue: 0.14), Color(red: 0.16, green: 0.10, blue: 0.12)]
                    : [Color(red: 0.93, green: 0.90, blue: 1.0), Color(red: 1.0, green: 0.90, blue: 0.80)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            Circle().fill(AppBrand.amber.opacity(0.55)).frame(width: 900).blur(radius: 140).offset(x: -500, y: -300)
            Circle().fill(AppBrand.lavender.opacity(0.55)).frame(width: 800).blur(radius: 140).offset(x: 500, y: -100)
            Circle().fill(AppBrand.accent.opacity(0.35)).frame(width: 700).blur(radius: 140).offset(x: 300, y: 420)
            Circle().fill(Color(red: 0.55, green: 0.80, blue: 1.0).opacity(0.45)).frame(width: 700).blur(radius: 140).offset(x: -400, y: 400)
        }
        .ignoresSafeArea()
    }
}

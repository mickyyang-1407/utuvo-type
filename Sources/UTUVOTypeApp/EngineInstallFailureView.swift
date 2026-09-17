import AppKit
import SwiftUI
import UTUVOTypeCore

/// 本機引擎安裝失敗時給使用者看的卡：講原因、講修法、給一鍵指令／回報。
/// popover 首次啟動卡與設定頁共用；raw log 留在設定頁的可折疊區，這裡不放。
struct EngineInstallFailureView: View {
    @ObservedObject var preferences: AppPreferences
    let diagnosis: EngineInstallDiagnosis
    let log: String
    let compact: Bool
    let onRetry: () -> Void

    @State private var copied = false
    @State private var launchedTerminal = false

    static let issuesURL = URL(string: "https://github.com/mickyyang-1407/utuvo-type/issues/new")!

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: compact ? 11 : 13, weight: .semibold))
                    .foregroundStyle(AppBrand.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(preferences.tr(diagnosis.summaryZh, diagnosis.summaryEn))
                        .font(AppBrand.ui(compact ? 11 : 12, weight: .semibold))
                        .foregroundStyle(AppBrand.retroText)
                    Text(preferences.tr(diagnosis.fixZh, diagnosis.fixEn))
                        .font(AppBrand.ui(compact ? 10 : 11))
                        .foregroundStyle(AppBrand.retroMuted)
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            if let command = diagnosis.command {
                HStack(spacing: 8) {
                    Text(command)
                        .font(AppBrand.mono(compact ? 10 : 11))
                        .foregroundStyle(AppBrand.retroText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.primary.opacity(0.06))
                        )
                        .textSelection(.enabled)
                    Button {
                        copy(command)
                    } label: {
                        Label(copied ? preferences.tr("已複製", "Copied") : preferences.tr("複製", "Copy"),
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .glassButton()
                    .controlSize(.small)
                }
            }

            HStack(spacing: 8) {
                if let command = diagnosis.command {
                    Button {
                        runInTerminal(command)
                    } label: {
                        Label(launchedTerminal ? preferences.tr("已送到終端機", "Sent to Terminal") : preferences.tr("在終端機執行", "Run in Terminal"),
                              systemImage: "terminal")
                    }
                    .glassProminentButton()
                    .controlSize(.small)
                }
                if diagnosis.retryable {
                    Button {
                        onRetry()
                    } label: {
                        Label(preferences.tr("重試安裝", "Retry install"), systemImage: "arrow.clockwise")
                    }
                    .modifier(RetryStyle(prominent: diagnosis.command == nil))
                    .controlSize(.small)
                }
                if diagnosis.needsReport {
                    Button {
                        report()
                    } label: {
                        Label(preferences.tr("回報問題", "Report issue"), systemImage: "paperplane")
                    }
                    .glassButton()
                    .controlSize(.small)
                }
            }
        }
        .padding(compact ? 8 : 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppBrand.accent.opacity(0.08))
        )
        .accessibilityIdentifier("engineInstallFailure")
    }

    private struct RetryStyle: ViewModifier {
        let prominent: Bool
        func body(content: Content) -> some View {
            if prominent { content.glassProminentButton() } else { content.glassButton() }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }

    /// 打開終端機、把指令貼進去執行（sudo 會在終端機裡要密碼，app 不碰密碼）。
    /// 指令同時放進剪貼簿：使用者若拒絕自動化權限，還能自己貼。
    private func runInTerminal(_ command: String) {
        copy(command)
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        var error: NSDictionary?
        if let script = NSAppleScript(source: source) {
            script.executeAndReturnError(&error)
        }
        if error != nil {
            // 自動化權限被拒或 Terminal 不在：至少把 Terminal 帶到前面，指令已在剪貼簿。
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
                NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
            }
        }
        launchedTerminal = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { launchedTerminal = false }
    }

    /// 開 GitHub issue 頁，標題與 log 摘要（去家目錄）先填好；使用者看過再送出。
    private func report() {
        let excerpt = EngineInstallDiagnosis.reportExcerpt(log: log)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let body = """
        **Local engine install failed** (\(diagnosis.kind.rawValue))
        UTUVO Type \(version) · macOS \(os) · \(HardwareProfile.isAppleSilicon ? "Apple silicon" : "Intel")

        <details><summary>bootstrap log (last lines)</summary>

        ```
        \(excerpt)
        ```
        </details>
        """
        var comps = URLComponents(url: Self.issuesURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "title", value: "Local engine install failed: \(diagnosis.kind.rawValue)"),
            URLQueryItem(name: "labels", value: "engine-install"),
            URLQueryItem(name: "body", value: body),
        ]
        if let url = comps.url { NSWorkspace.shared.open(url) }
    }
}

import SwiftUI

/// 鍵盤叫起主 app 後的提示：告訴使用者回到剛剛的 app；工作階段期間常駐，可手動結束。
struct KeyboardSessionBanner: View {
    @ObservedObject var host: KeyboardVoiceHost

    var body: some View {
        if host.isActive || host.lastError != nil {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: host.lastError == nil ? "keyboard.badge.waveform" : "exclamationmark.triangle.fill")
                        .font(.title3)
                        .foregroundStyle(Aurora.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if host.isActive {
                        Button("結束") { host.endSession() }
                            .font(.caption.weight(.semibold))
                            .auroraGlassButton()
                    }
                }
                if host.isActive && host.lastError == nil {
                    Label("點左上角「◀︎」回到剛剛的 app，光球就能直接用", systemImage: "arrow.up.left")
                        .font(.caption)
                        .foregroundStyle(Aurora.orange)
                }
            }
            .padding(12)
            .auroraCard(cornerRadius: 16)
            .accessibilityIdentifier("keyboardSessionBanner")
        }
    }

    private var title: String {
        if let error = host.lastError { return error }
        switch host.phase {
        case .recording: return "鍵盤正在聽"
        case .finishing: return "整理中…"
        default: return "鍵盤語音已開啟"
        }
    }

    private var detail: String {
        if host.lastError != nil { return "修好後回鍵盤再點一次光球" }
        if let ends = host.idleEndsAt {
            let minutes = max(1, Int(ceil(ends.timeIntervalSinceNow / 60)))
            return "閒置 \(minutes) 分鐘後自動關麥克風"
        }
        return "麥克風只在工作階段期間開啟"
    }
}

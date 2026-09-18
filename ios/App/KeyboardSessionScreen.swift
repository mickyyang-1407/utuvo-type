import SwiftUI

/// 鍵盤叫起主 app 後的專用畫面：主 app 此時只是「替鍵盤開麥克風」，不給麥克風按鈕，
/// 避免使用者在這裡點聽寫（真機回報：會想點，而且點了會出事）。
struct KeyboardSessionScreen: View {
    @ObservedObject var host: KeyboardVoiceHost

    var body: some View {
        ZStack {
            Aurora.Backdrop()
            VStack(spacing: 22) {
                Spacer(minLength: 40)
                ZStack {
                    Circle()
                        .fill(Aurora.orange.opacity(0.16))
                        .frame(width: 150, height: 150)
                        .blur(radius: 20)
                    Image(systemName: host.lastError == nil ? "keyboard.badge.waveform" : "exclamationmark.triangle.fill")
                        .font(.system(size: 54, weight: .semibold))
                        .foregroundStyle(Aurora.orange)
                        .symbolEffect(.pulse, options: .repeating, isActive: host.phase == .recording)
                }
                VStack(spacing: 8) {
                    Text(title)
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                    Text(detail)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 28)

                if host.returnTarget != nil && host.lastError == nil {
                    Button {
                        host.returnNow()
                    } label: {
                        Label("回到剛剛的 app", systemImage: "arrow.uturn.backward")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .auroraProminentButton()
                    .tint(Aurora.orange)
                    .padding(.horizontal, 32)
                }

                Label("或點左上角「◀︎」回去，在鍵盤上點光球說話", systemImage: "arrow.up.left")
                    .font(.footnote)
                    .foregroundStyle(Aurora.orange)
                    .padding(.horizontal, 24)
                    .multilineTextAlignment(.center)

                Spacer()

                VStack(spacing: 10) {
                    if let ends = host.idleEndsAt {
                        Text("閒置 \(max(1, Int(ceil(ends.timeIntervalSinceNow / 60)))) 分鐘後自動關麥克風")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("結束鍵盤語音") { host.endSession() }
                        .font(.subheadline.weight(.medium))
                        .auroraGlassButton()
                }
                .padding(.bottom, 28)
            }
        }
        .accessibilityIdentifier("keyboardSessionScreen")
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
        if host.lastError != nil { return "修好後回到鍵盤，再點一次光球。" }
        return "麥克風由 UTUVO Type 替鍵盤開著，你不用在這裡操作。"
    }
}

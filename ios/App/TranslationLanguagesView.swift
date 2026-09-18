import SwiftUI
#if canImport(Translation)
import Translation
#endif

/// 鍵盤長按翻譯要出現哪些語言：勾選、照勾選順序排在光球上方的弧上，最多 5 個。
/// 每個語言標示「裝置端翻譯包」狀態；沒下載的可以直接下載（下載後翻譯快很多，也不用雲端）。
struct TranslationLanguagesView: View {
    @State private var selected: [String] = QuickPickStore.codes()
    @State private var status: [String: String] = [:]
    @State private var downloadCode: String?
    @State private var configuration: AnyObject?

    private var sourceRaw: String {
        KeyboardPresence.defaults.string(forKey: "utuvo.type.keyboard.language") ?? "zh-TW"
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 8) {
                    ForEach(Array(selected.enumerated()), id: \.element) { index, code in
                        Text(name(code))
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Aurora.orange.opacity(index == selected.count / 2 ? 0.28 : 0.14)))
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("鍵盤上的順序（中間那個是長按時預選的）")
            } footer: {
                Text("長按鍵盤的光球，這些語言會排在光球上方；滑到語言放開、講中文，就貼上翻譯。最多 \(QuickPickStore.maxCount) 個，至少 1 個。")
            }

            Section("語言") {
                ForEach(TranslationTarget.all) { target in
                    row(target)
                }
            }
        }
        .navigationTitle("鍵盤翻譯語言")
        .task { await refreshStatus() }
        .modifier(DownloadModifier(code: $downloadCode, sourceRaw: sourceRaw) {
            Task { await refreshStatus() }
        })
    }

    private func row(_ target: TranslationTarget) -> some View {
        let index = selected.firstIndex(of: target.code)
        let full = index == nil && selected.count >= QuickPickStore.maxCount
        return HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(index != nil ? Aurora.orange : Color.secondary.opacity(0.15))
                    .frame(width: 26, height: 26)
                if let index {
                    Text("\(index + 1)").font(.caption.weight(.bold)).foregroundStyle(.white)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(target.displayName)
                Text(statusText(target.code))
                    .font(.caption)
                    .foregroundStyle(status[target.code] == "installed" ? Aurora.mint : .secondary)
            }
            Spacer()
            if status[target.code] == "supported" {
                Button("下載") { downloadCode = target.code }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
            }
        }
        .contentShape(Rectangle())
        .opacity(full ? 0.45 : 1)
        .onTapGesture {
            let next = QuickPickStore.toggled(target.code, in: selected)
            guard next != selected else { return }
            selected = next
            QuickPickStore.setCodes(next)
        }
        .accessibilityAddTraits(index != nil ? .isSelected : [])
    }

    private func name(_ code: String) -> String {
        TranslationTarget.all.first { $0.code == code }?.displayName ?? code
    }

    private func statusText(_ code: String) -> String {
        switch status[code] {
        case "installed": return String(localized: "裝置端翻譯包已下載")
        case "supported": return String(localized: "可下載裝置端翻譯包（沒下載時用 Apple Intelligence）")
        case "unsupported": return String(localized: "這個方向系統不支援，會用 Apple Intelligence")
        case "same": return String(localized: "與辨識語言相同")
        default: return String(localized: "檢查中…")
        }
    }

    private func refreshStatus() async {
        #if canImport(Translation)
        guard #available(iOS 18.0, *) else { return }
        let availability = LanguageAvailability()
        let srcID = FastTranslator.languageIdentifier(forDictation: sourceRaw)
        let src = Locale.Language(identifier: srcID)
        var next: [String: String] = [:]
        for target in TranslationTarget.all {
            if target.code == srcID { next[target.code] = "same"; continue }
            let result = await availability.status(from: src, to: Locale.Language(identifier: target.code))
            switch result {
            case .installed: next[target.code] = "installed"
            case .supported: next[target.code] = "supported"
            case .unsupported: next[target.code] = "unsupported"
            @unknown default: next[target.code] = "unsupported"
            }
        }
        status = next
        #endif
    }
}

/// 系統的翻譯包下載面板（Translation framework 只提供 SwiftUI 版）。
private struct DownloadModifier: ViewModifier {
    @Binding var code: String?
    let sourceRaw: String
    let onDone: () -> Void

    func body(content: Content) -> some View {
        #if canImport(Translation)
        if #available(iOS 18.0, *) {
            content.translationTask(configuration) { session in
                await Self.prepare(PreparingSession(session))
                await MainActor.run {
                    code = nil
                    onDone()
                }
            }
        } else {
            content
        }
        #else
        content
        #endif
    }

    #if canImport(Translation)
    /// TranslationSession 不是 Sendable；只在下載這一步序列使用，用盒子跨隔離區。
    @available(iOS 18.0, *)
    final class PreparingSession: @unchecked Sendable {
        let session: TranslationSession
        init(_ session: TranslationSession) { self.session = session }
    }

    @available(iOS 18.0, *)
    nonisolated private static func prepare(_ box: PreparingSession) async {
        try? await box.session.prepareTranslation()
    }

    @available(iOS 18.0, *)
    private var configuration: TranslationSession.Configuration? {
        guard let code else { return nil }
        return TranslationSession.Configuration(
            source: Locale.Language(identifier: FastTranslator.languageIdentifier(forDictation: sourceRaw)),
            target: Locale.Language(identifier: code)
        )
    }
    #endif
}

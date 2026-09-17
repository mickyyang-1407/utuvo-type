import SwiftUI

/// 聽寫主畫面（Aurora 視覺）：光球＋波形＋玻璃卡。
struct DictateView: View {
    @StateObject private var model = DictationModel()
    @State private var translationTarget = "en"
    @State private var translating = false
    @State private var translatedText: String?
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ZStack {
                Aurora.Backdrop()
                ScrollView {
                    VStack(spacing: 22) {
                        languagePicker
                        WaveformBars(isRecording: model.isRecording)
                        micButton
                        routeBadge
                        transcriptSection
                        outputSection
                    }
                    .padding(16)
                }
            }
            .navigationTitle("UTUVO TYPE")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .onDisappear { model.finalizeNow() }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Subviews

    private var languagePicker: some View {
        Picker("語言", selection: $model.language) {
            ForEach(DictationLanguage.allCases) { lang in
                Text(lang.localizedName(zh: true)).tag(lang)
            }
        }
        .pickerStyle(.segmented)
        .disabled(model.isRecording)
    }

    /// IOS2：這次辨識走本機還是雲端，講在畫面上，不讓使用者用猜的。
    @ViewBuilder
    private var routeBadge: some View {
        if let route = model.route {
            Label(route.badgeText, systemImage: route.isPrivate ? "lock.fill" : "cloud.fill")
                .font(.caption)
                .foregroundStyle(route.isPrivate ? .green : .orange)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill((route.isPrivate ? Color.green : Color.orange).opacity(0.14))
                )
        }
    }

    private var micButton: some View {
        Button {
            model.toggle()
            if model.isRecording { translatedText = nil }
        } label: {
            MicOrb(isRecording: model.isRecording)
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var transcriptSection: some View {
        if !model.liveTranscript.isEmpty {
            card(title: "逐字稿", text: model.liveTranscript, secondary: true)
        }
        if !model.finalText.isEmpty {
            card(title: "輸出", text: model.finalText, secondary: false)
        }
        if let translated = translatedText {
            card(title: "翻譯", text: translated, secondary: false)
        }
        if let error = model.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
        }
    }

    @ViewBuilder
    private var outputSection: some View {
        if !model.finalText.isEmpty {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    actionButton(
                        icon: copied ? "checkmark" : "doc.on.doc",
                        label: copied ? "已複製" : "複製"
                    ) {
                        UIPasteboard.general.string = model.finalText
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    }
                    Menu {
                        ForEach(TranslationService.targets, id: \.code) { target in
                            Button(target.zh) {
                                translationTarget = target.zh
                                runTranslation(targetName: target.zh)
                            }
                        }
                    } label: {
                        Label(translating ? "翻譯中…" : "翻譯", systemImage: "character.book.closed")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Aurora.violet)
                    .disabled(translating || !TranslationService.shared.isConfigured)
                }
                if !TranslationService.shared.isConfigured {
                    Text("翻譯需先在「設定 → 雲端翻譯」輸入 API key")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Pieces

    private func actionButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(.white)
    }

    private func runTranslation(targetName: String) {
        translating = true
        translatedText = nil
        Task {
            defer { translating = false }
            do {
                translatedText = try await TranslationService.shared.translate(model.finalText, to: targetName)
            } catch {
                translatedText = "⚠️ \(error.localizedDescription)"
            }
        }
    }

    /// Aurora 玻璃卡片：標題＋可選取內文。
    private func card(title: String, text: String, secondary: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.bold))
                .kerning(1.2)
                .foregroundStyle(Aurora.orange.opacity(0.9))
            Text(text)
                .font(.body)
                .foregroundStyle(secondary ? Color.white.opacity(0.55) : Color.white)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(Aurora.GlassCard())
    }
}

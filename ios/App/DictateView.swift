import SwiftUI

/// 聽寫主畫面：品牌列、用量統計（Typeless Home insights）、鍵盤啟用教學、光球＋波形、輸出卡。
struct DictateView: View {
    @StateObject private var model = DictationModel()
    @ObservedObject private var voiceHost = KeyboardVoiceHost.shared
    @State private var translating = false
    @State private var translatedText: String?
    @State private var copied = false
    @State private var insights = UsageInsights.compute(records: HistoryStore.shared.load())
    @State private var keyboardSeen = KeyboardPresence.seen
    @AppStorage("utuvo.type.ios.keyboardGuideDismissed") private var keyboardGuideDismissed = false

    var body: some View {
        NavigationStack {
            ZStack {
                Aurora.Backdrop()
                ScrollView {
                    VStack(spacing: 18) {
                        header
                        KeyboardSessionBanner(host: voiceHost)
                        insightsStrip
                        if !keyboardSeen && !keyboardGuideDismissed {
                            keyboardGuideCard
                        }
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
            .toolbar(.hidden, for: .navigationBar)
            .onAppear {
                insights = UsageInsights.compute(records: HistoryStore.shared.load())
                keyboardSeen = KeyboardPresence.seen
            }
            .onChange(of: model.finalText) { _, _ in
                insights = UsageInsights.compute(records: HistoryStore.shared.load())
            }
            .onDisappear { model.finalizeNow() }
        }
    }

    // MARK: - Header / insights

    private var header: some View {
        HStack(spacing: 12) {
            Image("BrandMark")
                .resizable()
                .scaledToFit()
                .frame(width: 44, height: 44)
                .shadow(color: Aurora.orange.opacity(0.25), radius: 6, y: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text("UTUVO Type")
                    .font(.title3.weight(.semibold))
                Text("你只需要說話")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.top, 6)
    }

    private var insightsStrip: some View {
        HStack(spacing: 10) {
            insightTile(value: "\(insights.weekWords)", label: "本週字數")
            insightTile(value: "\(insights.sessions)", label: "次聽寫")
            insightTile(value: minutesText(insights.minutesSaved), label: "省下打字")
        }
    }

    private func insightTile(value: String, label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .auroraGlass(cornerRadius: 16)
    }

    private func minutesText(_ minutes: Double) -> String {
        if minutes < 1 { return "<1 分" }
        if minutes < 60 { return "\(Int(minutes.rounded())) 分" }
        return String(format: "%.1f 時", minutes / 60)
    }

    /// 鍵盤還沒在任何 app 裡出現過＝很可能還沒啟用；教三步驟並直接開系統設定。
    private var keyboardGuideCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "keyboard.badge.ellipsis")
                    .foregroundStyle(Aurora.orange)
                Text("在任何 app 裡用說的打字")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("略過") { keyboardGuideDismissed = true }
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            guideStep(1, "設定 → 一般 → 鍵盤 → 鍵盤 → 加入新鍵盤 → UTUVO Type")
            guideStep(2, "點進 UTUVO Type，打開「允許完整存取」（語音辨識需要）")
            guideStep(3, "在任何輸入框按 🌐 切到 UTUVO Type，點麥克風開始說")
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Label("打開設定", systemImage: "arrow.up.forward.app")
                    .frame(maxWidth: .infinity)
            }
            .auroraProminentButton()
            .tint(Aurora.orange)
        }
        .auroraCard()
    }

    private func guideStep(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(n)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Aurora.orbGradient))
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Dictation

    private var languagePicker: some View {
        Picker("語言", selection: $model.language) {
            ForEach(DictationLanguage.allCases) { lang in
                Text(lang.localizedName(zh: true)).tag(lang)
            }
        }
        .pickerStyle(.segmented)
        .disabled(model.isRecording)
    }

    /// 這次辨識走本機還是雲端，講在畫面上，不讓使用者用猜的。
    @ViewBuilder
    private var routeBadge: some View {
        if let route = model.route {
            Label(route.badgeText, systemImage: route.isPrivate ? "lock.fill" : "cloud.fill")
                .font(.caption)
                .foregroundStyle(route.isPrivate ? Aurora.mint : Aurora.orange)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill((route.isPrivate ? Aurora.mint : Aurora.orange).opacity(0.14)))
        }
    }

    private var micButton: some View {
        VStack(spacing: 8) {
            Button {
                model.toggle()
                if model.isRecording { translatedText = nil }
            } label: {
                MicOrb(isRecording: model.isRecording)
            }
            .disabled(model.isRewriting)
            .accessibilityLabel(model.isRecording ? "停止" : "開始聽寫")
            Text(micHint)
                .font(.footnote)
                .foregroundStyle(model.intent.isEdit ? Aurora.orange : Color.secondary)
                .animation(.default, value: micHint)
        }
        .padding(.vertical, 6)
    }

    /// 跟鍵盤同一套文案（KeyboardMode 的 idle／recording hint），主 app 與鍵盤講同一種話。
    private var micHint: String {
        if model.isRewriting { return "改寫中…（\(OnDeviceAssistant.currentEngine().badge)）" }
        switch (model.intent, model.isRecording) {
        case (.edit, true): return "說出要怎麼改，說完再點一下"
        case (.edit, false): return KeyboardMode.edit(selection: "").idleHint
        case (.dictate, true): return KeyboardMode.dictate.recordingHint
        case (.dictate, false): return KeyboardMode.dictate.idleHint
        }
    }

    @ViewBuilder
    private var transcriptSection: some View {
        if !model.liveTranscript.isEmpty {
            card(title: model.intent.isEdit ? "你的指示" : "逐字稿", text: model.liveTranscript, secondary: true)
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
                .foregroundStyle(Aurora.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
        }
    }

    @ViewBuilder
    private var outputSection: some View {
        if !model.finalText.isEmpty {
            VStack(spacing: 10) {
                // Typeless「Speak to edit」主 app 版：對整段輸出下口頭指示（改語氣、加一句、換字）。
                HStack(spacing: 10) {
                    Button {
                        translatedText = nil
                        model.startEdit()
                    } label: {
                        Label(model.intent.isEdit ? "說吧，我在聽" : "說出要怎麼改", systemImage: "wand.and.stars")
                            .frame(maxWidth: .infinity)
                    }
                    .auroraProminentButton()
                    .tint(Aurora.orange)
                    .disabled(model.isRecording || model.isRewriting || engineUnavailable)
                    .accessibilityIdentifier("speakToEdit")

                    if model.previousText != nil {
                        Button {
                            model.undoEdit()
                        } label: {
                            Label("還原", systemImage: "arrow.uturn.backward")
                        }
                        .auroraGlassButton()
                        .disabled(model.isRecording || model.isRewriting)
                    }
                }
                HStack(spacing: 10) {
                    Button {
                        UIPasteboard.general.string = model.finalText
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    } label: {
                        Label(copied ? "已複製" : "複製", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .auroraGlassButton()

                    Menu {
                        ForEach(TranslationTarget.all) { target in
                            Button(target.zh) { runTranslation(to: target) }
                        }
                    } label: {
                        Label(translating ? "翻譯中…" : "翻譯", systemImage: "character.book.closed")
                            .frame(maxWidth: .infinity)
                    }
                    .auroraProminentButton()
                    .tint(Aurora.violet)
                    .disabled(translating || engineUnavailable)
                }
                Text(engineLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var engineUnavailable: Bool {
        if case .unavailable = OnDeviceAssistant.currentEngine() { return true }
        return false
    }

    private var engineLine: String {
        switch OnDeviceAssistant.currentEngine() {
        case .appleIntelligence: return "翻譯與改寫走 Apple Intelligence，文字不離機"
        case .cloud: return "翻譯與改寫走你自己的雲端 key"
        case .unavailable(let why): return why
        }
    }

    private func runTranslation(to target: TranslationTarget) {
        translating = true
        translatedText = nil
        Task {
            defer { translating = false }
            do {
                translatedText = try await OnDeviceAssistant.translate(model.finalText, to: target, sourceRaw: model.language.rawValue)
            } catch {
                translatedText = "⚠️ \(error.localizedDescription)"
            }
        }
    }

    private func card(title: String, text: String, secondary: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Aurora.orange)
            Text(text)
                .font(.body)
                .foregroundStyle(secondary ? Color.secondary : Color.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .auroraCard()
    }
}

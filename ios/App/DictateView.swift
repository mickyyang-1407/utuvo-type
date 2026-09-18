import SwiftUI

/// 聽寫主畫面（2026-09-18 重設計）：上＝品牌＋語言選單；中＝光球獨佔畫面中心（輸出卡接在下面）；
/// 下＝安靜的用量一行。整頁撐滿螢幕高度，不再全擠在上半部。
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
                GeometryReader { proxy in
                    ScrollView {
                        VStack(spacing: 18) {
                            header
                            if !keyboardSeen && !keyboardGuideDismissed {
                                keyboardGuideCard
                            }
                            Spacer(minLength: 8)
                            micButton
                            routeBadge
                            transcriptSection
                            outputSection
                            Spacer(minLength: 8)
                            insightsStrip
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        .padding(.bottom, 12)
                        .frame(minHeight: proxy.size.height)
                    }
                    .scrollBounceBehavior(.basedOnSize)
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
            #if DEBUG
            // 真機重現用：`-utuvo.type.debug.micAfterSession YES` 搭配 utuvotype://voice 啟動，
            // 等工作階段開好後，照使用者路徑「結束工作階段 → 點主 app 麥克風」。
            .task {
                guard UserDefaults.standard.bool(forKey: "utuvo.type.debug.micAfterSession") else { return }
                try? await Task.sleep(for: .seconds(4))
                print("[debug] host active=\(KeyboardVoiceHost.shared.isActive) → tap mic")
                model.toggle()
                try? await Task.sleep(for: .seconds(4))
                print("[debug] after toggle recording=\(model.isRecording) error=\(model.errorMessage ?? "-")")
            }
            #endif
        }
    }

    // MARK: - Header / insights

    private var header: some View {
        HStack(spacing: 14) {
            Image("BrandMark")
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                .shadow(color: Aurora.orange.opacity(0.25), radius: 12, y: 6)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("UTUVO Type")
                    .font(.title2.weight(.bold))
                Text("你只需要說話")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            languageMenu
        }
        .padding(.top, 6)
    }

    /// 用量：頁尾一行安靜的數字（不是卡片、不搶光球）。
    private var insightsStrip: some View {
        HStack(spacing: 0) {
            insightTile(value: "\(insights.weekWords)", label: String(localized: "本週字數"))
            Divider().frame(height: 30)
            insightTile(value: "\(insights.sessions)", label: String(localized: "次聽寫"))
            Divider().frame(height: 30)
            insightTile(value: minutesText(insights.minutesSaved), label: String(localized: "省下打字"))
        }
        .padding(.horizontal, 8)
        .opacity(0.9)
    }

    private func insightTile(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func minutesText(_ minutes: Double) -> String {
        if minutes < 1 { return String(localized: "<1 分") }
        if minutes < 60 { return String(localized: "\(Int(minutes.rounded())) 分") }
        let hours = String(format: "%.1f", minutes / 60)
        return String(localized: "\(hours) 時")
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
            guideStep(1, String(localized: "設定 → 一般 → 鍵盤 → 鍵盤 → 加入新鍵盤 → UTUVO Type"))
            guideStep(2, String(localized: "點進 UTUVO Type，打開「允許完整存取」（語音辨識需要）"))
            guideStep(3, String(localized: "在任何輸入框按 🌐 切到 UTUVO Type，點光球開始說"))
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
                .background(Circle().fill(Aurora.orange))
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Dictation

    /// 語言：右上一顆膠囊選單（取代整排分段控制）。
    private var languageMenu: some View {
        Menu {
            Picker("語言", selection: $model.language) {
                ForEach(DictationLanguage.allCases) { lang in
                    Text(lang.localizedName(zh: true)).tag(lang)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "globe")
                Text(model.language.shortLabel)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.thinMaterial, in: Capsule())
        }
        .disabled(model.isRecording)
        .accessibilityLabel("聽寫語言：\(model.language.localizedName(zh: true))")
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

    /// 光球取代麥克風：點一下開始／停止；講話時跟著音量動，改寫時轉薰衣草。
    private var micButton: some View {
        VStack(spacing: 4) {
            Button {
                model.toggle()
                if model.isRecording { translatedText = nil }
            } label: {
                LiveOrb(phase: orbPhase, editPalette: model.intent.isEdit, sphereFraction: 0.58, level: { [model] in model.liveLevel() })
                    .frame(width: 320, height: 320)
                    .contentShape(Circle().inset(by: 64))
            }
            .buttonStyle(OrbPressStyle())
            .disabled(model.isRewriting)
            .sensoryFeedback(trigger: model.isRecording) { _, recording in
                recording ? .impact(weight: .medium) : .impact(flexibility: .rigid)
            }
            .accessibilityLabel(model.isRecording ? String(localized: "停止") : String(localized: "開始聽寫"))
            .padding(.vertical, -44) // 光暈留白不佔版面
            Text(micHint)
                .font(.footnote)
                .foregroundStyle(model.intent.isEdit ? Aurora.violet : Color.secondary)
                .animation(.default, value: micHint)
        }
    }

    private var orbPhase: OrbView.Phase {
        #if DEBUG
        // 截圖／錄影：`-utuvo.type.ios.orbDemo YES` 擺出聆聽姿態（搭配合成音量）。
        if UserDefaults.standard.bool(forKey: "utuvo.type.ios.orbDemo") { return .listening }
        #endif
        if model.isRecording { return .listening }
        if model.isRewriting { return .processing }
        if model.errorMessage != nil { return .error }
        return .idle
    }

    /// 跟鍵盤同一套文案（KeyboardMode 的 idle／recording hint），主 app 與鍵盤講同一種話。
    private var micHint: String {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "utuvo.type.ios.orbDemo") { return KeyboardMode.dictate.recordingHint }
        #endif
        if model.isRewriting { return String(localized: "改寫中…（\(OnDeviceAssistant.currentEngine().badge)）") }
        switch (model.intent, model.isRecording) {
        case (.edit, true): return String(localized: "說出要怎麼改，說完再點一下")
        case (.edit, false): return KeyboardMode.edit(selection: "").idleHint
        case (.dictate, true): return KeyboardMode.dictate.recordingHint
        case (.dictate, false): return KeyboardMode.dictate.idleHint
        }
    }

    @ViewBuilder
    private var transcriptSection: some View {
        if !model.liveTranscript.isEmpty {
            card(title: model.intent.isEdit ? String(localized: "你的指示") : String(localized: "逐字稿"), text: model.liveTranscript, secondary: true)
        }
        if !model.finalText.isEmpty {
            card(title: String(localized: "輸出"), text: model.finalText, secondary: false)
        }
        if let translated = translatedText {
            card(title: String(localized: "翻譯"), text: translated, secondary: false)
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
                        Label(model.intent.isEdit ? String(localized: "說吧，我在聽") : String(localized: "說出要怎麼改"), systemImage: "wand.and.stars")
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
                        Label(copied ? String(localized: "已複製") : String(localized: "複製"), systemImage: copied ? "checkmark" : "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .auroraGlassButton()

                    Menu {
                        ForEach(TranslationTarget.all) { target in
                            Button(target.displayName) { runTranslation(to: target) }
                        }
                    } label: {
                        Label(translating ? String(localized: "翻譯中…") : String(localized: "翻譯"), systemImage: "character.book.closed")
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
        case .appleIntelligence: return String(localized: "翻譯與改寫走 Apple Intelligence，文字不離機")
        case .cloud: return String(localized: "翻譯與改寫走你自己的雲端 key")
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

import SwiftUI

/// 一步一步教學（10-15 Micky：「如何設置、如何申請 Groq API，都要一步一步用手指頭教學，讓使用者不會害怕」）。
///
/// 一頁一個動作：上面一張示意畫面、手指指著要點的地方，下面一句話說要做什麼，
/// 再一句「放心」說明這一步不會怎樣。能直接帶過去的步驟（打開設定、打開 Groq、貼上 key）
/// 在那一頁就有按鈕，不用自己找。
enum TutorialKind: String, CaseIterable, Identifiable {
    case keyboard, groqKey, firstUse

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keyboard: return String(localized: "加入 UTUVO Type 鍵盤")
        case .groqKey: return String(localized: "申請免費的 Groq key")
        case .firstUse: return String(localized: "第一次用說的打字")
        }
    }

    var subtitle: String {
        switch self {
        case .keyboard: return String(localized: "約 1 分鐘，只要做一次")
        case .groqKey: return String(localized: "約 3 分鐘，不用信用卡")
        case .firstUse: return String(localized: "約 1 分鐘")
        }
    }

    var symbol: String {
        switch self {
        case .keyboard: return "keyboard"
        case .groqKey: return "key.horizontal"
        case .firstUse: return "mic"
        }
    }

    var steps: [TutorialStep] {
        switch self {
        case .keyboard: return TutorialStep.keyboard
        case .groqKey: return TutorialStep.groqKey
        case .firstUse: return TutorialStep.firstUse
        }
    }
}

struct TutorialStep: Identifiable {
    enum Action { case openSettings, openGroq, pasteGroqKey }

    let id: Int
    let title: String
    let detail: String
    /// 「放心」那一句：這一步為什麼安全、做錯了怎麼辦。
    let reassurance: String?
    let illustration: TutorialIllustration
    var action: Action?

    static let keyboard: [TutorialStep] = [
        TutorialStep(id: 0, title: String(localized: "按下面的「打開設定」"),
                     detail: String(localized: "會打開 iPhone 的「設定」。如果直接看到 UTUVO Type 那一頁，就跳到第 3 步。"),
                     reassurance: String(localized: "設定完按左上角「◀︎ UTUVO Type」就會回到這裡。"),
                     illustration: .appButton(String(localized: "打開設定")), action: .openSettings),
        TutorialStep(id: 1, title: String(localized: "點「App」，再點「UTUVO Type」"),
                     detail: String(localized: "在設定首頁往下滑，點「App」；在清單裡找到「UTUVO Type」點進去。也可以在最上面的搜尋框打「UTUVO」。"),
                     reassurance: nil,
                     illustration: .settings(title: String(localized: "tutorial.settings.apps", defaultValue: "App"), rows: [
                        .init(String(localized: "行事曆"), .chevron),
                        .init(String(localized: "提醒事項"), .chevron),
                        .init("UTUVO Type", .chevron, highlighted: true)
                     ])),
        TutorialStep(id: 2, title: String(localized: "點「鍵盤」"),
                     detail: String(localized: "在 UTUVO Type 那一頁，找到「鍵盤」這一列，點進去。"),
                     reassurance: nil,
                     illustration: .settings(title: "UTUVO Type", rows: [
                        .init(String(localized: "麥克風"), .toggle(true)),
                        .init(String(localized: "語音辨識"), .toggle(true)),
                        .init(String(localized: "tutorial.settings.keyboards", defaultValue: "鍵盤"), .chevron, highlighted: true)
                     ])),
        TutorialStep(id: 3, title: String(localized: "打開「UTUVO Type」"),
                     detail: String(localized: "把「UTUVO Type」右邊的開關打開（變成綠色）。"),
                     reassurance: nil,
                     illustration: .settings(title: String(localized: "tutorial.settings.keyboards", defaultValue: "鍵盤"), rows: [
                        .init("UTUVO Type", .toggle(false), highlighted: true),
                        .init(String(localized: "允許完整取用"), .toggle(false))
                     ])),
        TutorialStep(id: 4, title: String(localized: "打開「允許完整取用」"),
                     detail: String(localized: "再打開下面的「允許完整取用」，跳出提醒時按「允許」。"),
                     reassurance: String(localized: "這是 iOS 對每個語音鍵盤都會跳的標準提醒。UTUVO 沒有自己的伺服器，你打的字只留在這支手機；密碼欄位一律不讀。"),
                     illustration: .alert(title: String(localized: "要允許「UTUVO Type」鍵盤完整取用嗎？"),
                                          buttons: [String(localized: "不允許"), String(localized: "允許")], highlighted: 1)),
        TutorialStep(id: 5, title: String(localized: "完成，回到 UTUVO Type"),
                     detail: String(localized: "點左上角「◀︎ UTUVO Type」回來。接著看「第一次用說的打字」。"),
                     reassurance: nil,
                     illustration: .settings(title: String(localized: "tutorial.settings.keyboards", defaultValue: "鍵盤"), rows: [
                        .init("UTUVO Type", .toggle(true)),
                        .init(String(localized: "允許完整取用"), .toggle(true))
                     ], backLabel: "UTUVO Type"))
    ]

    static let groqKey: [TutorialStep] = [
        TutorialStep(id: 0, title: String(localized: "為什麼要 key？"),
                     detail: String(localized: "「幫我寫」「改寫」「問問題」和雲端整理要用大模型。Groq 有免費額度、速度很快，申請一把 key 就能用。"),
                     reassurance: String(localized: "免費方案不用填信用卡。key 只存在這支手機的鑰匙圈，不會傳給 UTUVO。"),
                     illustration: .appButton(String(localized: "打開 Groq 申請頁"))),
        TutorialStep(id: 1, title: String(localized: "打開 Groq 申請頁"),
                     detail: String(localized: "按下面的按鈕，會用 Safari 打開 Groq 的網站。"),
                     reassurance: nil,
                     illustration: .appButton(String(localized: "打開 Groq 申請頁")), action: .openGroq),
        TutorialStep(id: 2, title: String(localized: "登入：按「Continue with Google」"),
                     detail: String(localized: "用 Google 帳號最快。沒有的話，在下面輸入 Email、按「Continue with email」，再到信箱點驗證連結。"),
                     reassurance: String(localized: "這是 Groq 官方網站（console.groq.com），登入只是建立免費帳號。"),
                     illustration: .groq(.login)),
        TutorialStep(id: 3, title: String(localized: "按「Create API Key」"),
                     detail: String(localized: "登入後會在「API Keys」頁，按「Create API Key」。"),
                     reassurance: nil,
                     illustration: .groq(.keys)),
        TutorialStep(id: 4, title: String(localized: "隨便取個名字，按「Submit」"),
                     detail: String(localized: "名字只是給你自己看的，例如「UTUVO」。"),
                     reassurance: nil,
                     illustration: .groq(.name)),
        TutorialStep(id: 5, title: String(localized: "按「Copy」複製 key"),
                     detail: String(localized: "畫面會出現一長串 gsk_ 開頭的字，按「Copy」複製。"),
                     reassurance: String(localized: "這串只會顯示一次。沒複製到也沒關係，回上一頁再建一把就好。"),
                     illustration: .groq(.copy)),
        TutorialStep(id: 6, title: String(localized: "回到 UTUVO Type，按「貼上」"),
                     detail: String(localized: "回到這一頁按下面的「貼上」，會自動存好並測試能不能用。"),
                     reassurance: String(localized: "存好後，UTUVO Type 的鍵盤也會用這把 key。"),
                     illustration: .appButton(String(localized: "貼上")), action: .pasteGroqKey)
    ]

    static let firstUse: [TutorialStep] = [
        TutorialStep(id: 0, title: String(localized: "切到 UTUVO Type 鍵盤"),
                     detail: String(localized: "在任何 App 點輸入框，按鍵盤左下角的 🌐，選「UTUVO Type」。"),
                     reassurance: String(localized: "按住 🌐 會跳出清單，可以直接選。"),
                     illustration: .keyboard(.globe)),
        TutorialStep(id: 1, title: String(localized: "點中間的光球"),
                     detail: String(localized: "第一次（或很久沒用）會跳到 UTUVO Type 打開麥克風，這是正常的。"),
                     reassurance: String(localized: "iOS 不讓鍵盤直接用麥克風，所有語音鍵盤都要這一步。"),
                     illustration: .keyboard(.orb)),
        TutorialStep(id: 2, title: String(localized: "回到原本的 App"),
                     detail: String(localized: "有些 App 會自動跳回去；沒有的話，點螢幕左上角「◀︎ 原本 App 的名字」就回去。"),
                     reassurance: nil,
                     illustration: .backToApp),
        TutorialStep(id: 3, title: String(localized: "再點光球，開始說"),
                     detail: String(localized: "講完再點一下光球，字就會出現在游標的位置。"),
                     reassurance: String(localized: "說錯了直接改口就好，例如「三點，不對，四點」，只會留下「四點」。也可以按「復原」。"),
                     illustration: .keyboard(.orb)),
        TutorialStep(id: 4, title: String(localized: "想讓它幫你寫，點右上的模式鈕"),
                     detail: String(localized: "可以選「幫我寫」「改寫」「問問題」。鈕變橘色就代表不是普通聽寫。"),
                     reassurance: String(localized: "講完一句會自動回到聽寫。"),
                     illustration: .keyboard(.mode))
    ]
}

// MARK: - 教學頁

struct GuidedTutorialView: View {
    let kind: TutorialKind
    @State private var index = 0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let steps = kind.steps
        VStack(spacing: 0) {
            TabView(selection: $index) {
                ForEach(steps) { step in
                    TutorialStepPage(step: step, number: step.id + 1, total: steps.count)
                        .tag(step.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .feedbackOnChange(of: index)

            HStack(spacing: 12) {
                Button {
                    TapPulse.shared.fire()
                    withAnimation { index = max(0, index - 1) }
                } label: {
                    Text("上一步").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(index == 0)
                .accessibilityIdentifier("tutorialBack")

                Button {
                    TapPulse.shared.fire()
                    if index == steps.count - 1 { dismiss() } else { withAnimation { index += 1 } }
                } label: {
                    Text(index == steps.count - 1 ? String(localized: "完成") : String(localized: "下一步"))
                        .frame(maxWidth: .infinity)
                }
                .auroraProminentButton()
                .controlSize(.large)
                .tint(Aurora.orange)
                .accessibilityIdentifier("tutorialNext")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct TutorialStepPage: View {
    let step: TutorialStep
    let number: Int
    let total: Int

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("第 \(number) 步，共 \(total) 步")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Aurora.orange)
                    .accessibilityIdentifier("tutorialProgress")
                TutorialIllustrationView(illustration: step.illustration)
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
                Text(step.title)
                    .font(.title2.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("tutorialStepTitle")
                Text(step.detail)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                if let action = step.action {
                    TutorialActionButton(action: action)
                }
                if let reassurance = step.reassurance {
                    Label {
                        Text(reassurance).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "checkmark.shield.fill").foregroundStyle(.green)
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .padding(20)
        }
    }
}

/// 步驟裡「直接帶過去」的按鈕。
private struct TutorialActionButton: View {
    let action: TutorialStep.Action
    @AppStorage(SmartCleanup.enabledKey) private var cleanupEnabled = true
    @State private var status: String?
    @State private var statusIsError = false
    @State private var checking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch action {
            case .openSettings:
                prominent(String(localized: "打開設定"), symbol: "gear", id: "tutorialOpenSettings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            case .openGroq:
                prominent(String(localized: "打開 Groq 申請頁"), symbol: "safari", id: "tutorialOpenGroq") {
                    if let url = SmartCleanup.Provider.groq.signupURL { UIApplication.shared.open(url) }
                }
            case .pasteGroqKey:
                // PasteButton：使用者自己按的貼上，iOS 不會再跳「允許貼上」的詢問。
                PasteButton(payloadType: String.self) { strings in
                    let pasted = strings.first ?? ""
                    Task { @MainActor in await save(pasted) }
                }
                .tint(Aurora.orange)
                .labelStyle(.titleAndIcon)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .accessibilityIdentifier("tutorialPasteKey")
                if checking { ProgressView() }
            }
            if let status {
                Label(status, systemImage: statusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(statusIsError ? .red : .green)
                    .accessibilityIdentifier("tutorialKeyStatus")
            }
        }
    }

    private func prominent(_ title: String, symbol: String, id: String, perform: @escaping () -> Void) -> some View {
        Button {
            TapPulse.shared.fire()
            perform()
        } label: {
            Label(title, systemImage: symbol).frame(maxWidth: .infinity)
        }
        .auroraProminentButton()
        .controlSize(.large)
        .tint(Aurora.orange)
        .accessibilityIdentifier(id)
    }

    private func save(_ raw: String) async {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard GroqKeyCheck.looksLikeGroqKey(key) else {
            status = String(localized: "剪貼簿裡不是 Groq key（應該是 gsk_ 開頭的一長串）。回 Groq 再按一次「Copy」。")
            statusIsError = true
            return
        }
        guard SmartCleanup.saveKey(key, for: .groq) else {
            status = String(localized: "存不進這支手機的鑰匙圈，請再按一次「貼上」。")
            statusIsError = true
            return
        }
        SmartCleanup.provider = .groq
        cleanupEnabled = true
        checking = true
        defer { checking = false }
        do {
            _ = try await SmartCleanup.complete(system: "Reply with OK.", user: "ping", provider: .groq, key: key, timeout: 15)
            status = String(localized: "存好了，也測試過可以用！")
            statusIsError = false
        } catch {
            status = GroqKeyCheck.message(for: error)
            statusIsError = true
        }
    }
}

/// 貼上的 key 檢查與錯誤說明（純邏輯，可測）。
enum GroqKeyCheck {
    static func looksLikeGroqKey(_ text: String) -> Bool {
        text.hasPrefix("gsk_") && text.count >= 40 && !text.contains(where: \.isWhitespace)
    }

    static func message(for error: Error) -> String {
        if let failure = error as? SmartCleanup.Failure {
            switch failure {
            case .http(401), .http(403):
                return String(localized: "Groq 說這把 key 不對。回 Groq 重新建一把，再按「貼上」。")
            case .http(429), .rateLimited:
                return String(localized: "key 已存好，但 Groq 這分鐘的免費額度用完了，等一下就能用。")
            default:
                break
            }
        }
        return String(localized: "key 已存好，但這次連不上 Groq（網路不穩？）。等一下到「智慧整理」按「測試」再試一次。")
    }
}

// MARK: - 示意畫面

enum TutorialIllustration {
    struct Row {
        enum Kind { case chevron, toggle(Bool) }
        let label: String
        let kind: Kind
        var highlighted = false
        init(_ label: String, _ kind: Kind, highlighted: Bool = false) {
            self.label = label; self.kind = kind; self.highlighted = highlighted
        }
    }
    enum GroqScreen { case login, keys, name, copy }
    enum KeyboardFocus { case globe, orb, mode }

    case appButton(String)
    case settings(title: String, rows: [Row], backLabel: String? = nil)
    case alert(title: String, buttons: [String], highlighted: Int)
    case groq(GroqScreen)
    case keyboard(KeyboardFocus)
    case backToApp
}

private struct TutorialIllustrationView: View {
    let illustration: TutorialIllustration

    var body: some View {
        MockFrame(dark: isGroq) {
            switch illustration {
            case .appButton(let title):
                VStack {
                    Spacer()
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 28).padding(.vertical, 12)
                        .background(Capsule().fill(Aurora.orange))
                        .tapTarget()
                    Spacer()
                }
            case .settings(let title, let rows, let backLabel):
                settings(title: title, rows: rows, backLabel: backLabel)
            case .alert(let title, let buttons, let highlighted):
                alert(title: title, buttons: buttons, highlighted: highlighted)
            case .groq(let screen):
                groq(screen)
            case .keyboard(let focus):
                keyboard(focus)
            case .backToApp:
                VStack(alignment: .leading, spacing: 10) {
                    Text(verbatim: "◀︎ LINE")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.blue)
                        .tapTarget()
                    Text(verbatim: "UTUVO Type").font(.headline)
                    RoundedRectangle(cornerRadius: 10).fill(.quaternary).frame(height: 60)
                    RoundedRectangle(cornerRadius: 10).fill(.quaternary).frame(height: 40)
                    Spacer()
                }
            }
        }
    }

    private var isGroq: Bool { if case .groq = illustration { return true } else { return false } }

    private func settings(title: String, rows: [TutorialIllustration.Row], backLabel: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let backLabel {
                Text("◀︎ \(backLabel)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.blue)
                    .tapTarget()
            }
            Text(title).font(.headline)
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    HStack {
                        Text(row.label).font(.subheadline)
                        Spacer()
                        switch row.kind {
                        case .chevron:
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        case .toggle(let on):
                            Capsule().fill(on ? Color.green : Color(.systemGray4))
                                .frame(width: 42, height: 26)
                                .overlay(alignment: on ? .trailing : .leading) {
                                    Circle().fill(.white).padding(2).shadow(radius: 1)
                                }
                                .if(row.highlighted) { $0.tapTarget() }
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(row.highlighted ? Aurora.orange.opacity(0.10) : .clear)
                    .if(row.highlighted && isChevron(row)) { $0.tapTarget() }
                    if i < rows.count - 1 { Divider().padding(.leading, 12) }
                }
            }
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Spacer(minLength: 0)
        }
    }

    private func isChevron(_ row: TutorialIllustration.Row) -> Bool {
        if case .chevron = row.kind { return true } else { return false }
    }

    private func alert(title: String, buttons: [String], highlighted: Int) -> some View {
        VStack {
            Spacer()
            VStack(spacing: 0) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .padding(14)
                Divider()
                HStack(spacing: 0) {
                    ForEach(Array(buttons.enumerated()), id: \.offset) { i, title in
                        Text(title)
                            .font(.subheadline.weight(i == highlighted ? .semibold : .regular))
                            .foregroundStyle(.blue)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .if(i == highlighted) { $0.tapTarget() }
                        if i < buttons.count - 1 { Divider() }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 24)
            Spacer()
        }
    }

    @ViewBuilder
    private func groq(_ screen: TutorialIllustration.GroqScreen) -> some View {
        let gray = Color.white.opacity(0.12)
        VStack(alignment: .leading, spacing: screen == .login ? 7 : 12) {
            Text(verbatim: "groq").font(.headline.weight(.heavy)).foregroundStyle(.white)
            switch screen {
            case .login:
                Text(verbatim: "Create an account or login").font(.caption).foregroundStyle(.white.opacity(0.7))
                groqButton("Continue with Google", highlighted: true)
                groqButton("Continue with GitHub")
                RoundedRectangle(cornerRadius: 8).stroke(gray).frame(height: 26)
                    .overlay(alignment: .leading) { Text("你的 Email").font(.caption).foregroundStyle(.white.opacity(0.4)).padding(.leading, 8) }
                groqButton("Continue with email")
            case .keys:
                HStack {
                    Text(verbatim: "API Keys").font(.headline).foregroundStyle(.white)
                    Spacer()
                    Text(verbatim: "Create API Key")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(.white))
                        .tapTarget()
                }
                RoundedRectangle(cornerRadius: 8).fill(gray).frame(height: 44)
            case .name:
                Text(verbatim: "Display Name").font(.caption.weight(.semibold)).foregroundStyle(.white)
                RoundedRectangle(cornerRadius: 8).stroke(gray).frame(height: 32)
                    .overlay(alignment: .leading) { Text(verbatim: "UTUVO").font(.callout).foregroundStyle(.white).padding(.leading, 8) }
                HStack {
                    Spacer()
                    Text(verbatim: "Submit")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(Capsule().fill(Aurora.orange))
                        .tapTarget()
                }
            case .copy:
                Text(verbatim: "Copy your API key").font(.caption.weight(.semibold)).foregroundStyle(.white)
                HStack {
                    Text("gsk_••••••••••••").font(.system(.caption, design: .monospaced)).foregroundStyle(.white)
                    Spacer()
                    Text(verbatim: "Copy")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(.white))
                        .tapTarget()
                }
                .padding(8)
                .background(gray, in: RoundedRectangle(cornerRadius: 8))
            }
            Spacer(minLength: 0)
        }
    }

    private func groqButton(_ title: String, highlighted: Bool = false) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(highlighted ? 0.9 : 0.25)))
            .if(highlighted) { $0.tapTarget() }
    }

    private func keyboard(_ focus: TutorialIllustration.KeyboardFocus) -> some View {
        VStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 8).fill(.quaternary).frame(height: 30)
                .overlay(alignment: .leading) { Text("|").foregroundStyle(Aurora.orange).padding(.leading, 8) }
            Spacer(minLength: 0)
            VStack(spacing: 10) {
                HStack {
                    Text(verbatim: "UTUVO Type").font(.caption.weight(.bold))
                    Spacer()
                    Label(String(localized: "聽寫"), systemImage: "mic")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(.thinMaterial))
                        .if(focus == .mode) { $0.tapTarget() }
                }
                Circle()
                    .fill(RadialGradient(colors: [Color(red: 1, green: 0.62, blue: 0.3), Aurora.orange], center: .topLeading, startRadius: 4, endRadius: 60))
                    .frame(width: 70, height: 70)
                    .if(focus == .orb) { $0.tapTarget() }
                HStack {
                    Image(systemName: "globe").font(.title3)
                        .if(focus == .globe) { $0.tapTarget() }
                    Spacer()
                    Image(systemName: "mic").font(.title3).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

/// 示意畫面外框：像一支縮小的手機螢幕。
private struct MockFrame<Content: View>: View {
    var dark = false
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(14)
            .frame(width: 280, height: 240)
            .background(dark ? Color(red: 0.09, green: 0.09, blue: 0.1) : Color(.systemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Color.primary.opacity(0.15), lineWidth: 2))
            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }
}

/// 要點的地方：橘色脈動外框＋一隻會點下去的手指。
private struct TapTarget: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Aurora.orange, lineWidth: 2.5)
                    .padding(-4)
                    .phaseAnimator([false, true]) { ring, pulse in
                        ring.opacity(reduceMotion ? 1 : (pulse ? 0.35 : 1))
                    } animation: { _ in .easeInOut(duration: 0.8) }
            }
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "hand.point.up.left.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Aurora.orange)
                    .shadow(color: .white, radius: 0, x: 1, y: 1)
                    .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
                    .offset(x: 22, y: 26)
                    .phaseAnimator([false, true]) { finger, pressed in
                        finger.scaleEffect(reduceMotion ? 1 : (pressed ? 0.85 : 1)).offset(x: pressed ? -3 : 0, y: pressed ? -3 : 0)
                    } animation: { _ in .easeInOut(duration: 0.6) }
                    .allowsHitTesting(false)
            }
    }
}

private extension View {
    func tapTarget() -> some View { modifier(TapTarget()) }

    @ViewBuilder
    func `if`<V: View>(_ condition: Bool, transform: (Self) -> V) -> some View {
        if condition { transform(self) } else { self }
    }
}

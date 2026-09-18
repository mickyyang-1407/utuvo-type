import UIKit
import UTUVOTypeCore

/// UTUVO Type 鍵盤——「光球鍵盤」（2026-09-17 產品決定：功能對齊，外表是我們自己的）。
/// 視覺語彙沿用主 app：光球（OrbView，Metal）當主角、玻璃圓鈕；錄音時光球跟著主 app 傳來的音量動。
///   - 頂緣「即時字幕帶」：閒置時是品牌（BrandMark＋字標），錄音時逐字稿在這裡跑；右上是語言徽章。
///   - 中央光球：點一下聽寫；有選取＝說出要怎麼改；長按出現弧形語言點，滑到放開就翻譯。
///   - 光球兩側對稱的玻璃圓鈕直排（2026-09-18 重設計）：左＝切打字 EN／繁／简，右＝⌫／@／送出。
///   - 打字模式：左上小光球回語音、右上一顆循環切 EN→繁→简。
/// 三種模式由 KeyboardMode.decide 決定；改寫／翻譯引擎見 OnDeviceAssistant。
final class KeyboardViewController: UIInputViewController {
    // MARK: - Speech state
    // iOS 不讓鍵盤開麥克風：錄音與辨識在主 app（VoiceBridge／KeyboardVoiceHost），鍵盤只下指令、收逐字稿。
    private var isRecording = false
    /// 這個鍵盤發出、還在等結果的指令 id。
    private var activeCommandID: UUID?
    private var bridgeObserver: DarwinObserver?
    private static let pendingIDKey = "utuvo.type.voice.pendingID"
    private static let pendingTranslateKey = "utuvo.type.voice.pendingTranslate"
    private var mode: KeyboardMode = .dictate
    private var pendingTranslateTarget: TranslationTarget?
    /// 目前由本鍵盤插進文件、還沒定稿的那段文字。
    private var insertedText = ""
    private var lastRawTranscript = ""

    private static let languageKey = "utuvo.type.keyboard.language"
    private var language: DictationLanguage {
        get {
            let stored = KeyboardPresence.defaults.string(forKey: Self.languageKey)
            return stored.flatMap(DictationLanguage.init(rawValue:)) ?? .traditionalChinese
        }
        set { KeyboardPresence.defaults.set(newValue.rawValue, forKey: Self.languageKey) }
    }

    // MARK: - UI
    /// 頂緣字幕帶（閒置＝品牌列；錄音＝逐字稿）。名稱沿用 transcriptPill 讓語音區程式碼不必改。
    private let transcriptPill = UIView()
    private let transcriptLabel = UILabel()
    private let liveDot = UIView()
    private let brandIcon = UIImageView(image: UIImage(named: "BrandMark"))
    private let brandLabel = UILabel()
    private let hintLabel = UILabel()
    private let micButton = OrbButton()
    /// 主 app 錄音時寫的即時音量（App Group 小檔案），光球每幀讀。
    private lazy var levelChannel = VoiceLevelChannel(writable: false)
    private let languageButton = UIButton(type: .system)
    private let deleteButton = UIButton(type: .custom)
    private let atButton = UIButton(type: .custom)
    private let returnButton = UIButton(type: .custom)
    private let globeButton = UIButton(type: .custom)
    // 打字模式（語音不準時就地修正；對齊同類產品的「語音／EN／繁」切換）
    private let voiceContainer = UIView()
    /// 語音區左側：切到三種打字版面。
    private let englishButton = UIButton(type: .custom)
    private let hantButton = UIButton(type: .custom)
    private let hansButton = UIButton(type: .custom)
    /// 打字區頂列：左＝回語音（小光球）、右＝循環切版面。
    private let voiceKey = UIButton(type: .custom)
    private let layoutKey = UIButton(type: .custom)
    private let typingView = TypingKeyboardView()
    private let candidateBar = CandidateBarView()
    private var heightConstraint: NSLayoutConstraint?
    private lazy var zhuyin = ImeSession(kind: .zhuyin)
    private lazy var pinyin = ImeSession(kind: .pinyin)
    private lazy var pinyinHant = ImeSession(kind: .pinyinHant)
    /// 目前這個模式的中文引擎（EN／語音時為 nil）。
    private var ime: ImeSession? {
        switch surface {
        case .zhuyin: KeyboardPresence.hantUsesPinyin ? pinyinHant : zhuyin
        case .pinyin: pinyin
        default: nil
        }
    }
    private var pickerDots: [UIView] = []
    private var pickerLabels: [UILabel] = []
    private var highlightedPick: Int?
    private var deleteRepeat: Timer?

    static let brandOrange = UIColor(red: 0.976, green: 0.451, blue: 0.086, alpha: 1)
    static let brandAmber = UIColor(red: 1.0, green: 0.72, blue: 0.29, alpha: 1)
    // 2026-09-18 產品決定：鍵盤太高 → 300→236 pt，光球與右側按鈕一起收緊。
    private static let orbSize: CGFloat = 88
    private static let orbCenterY: CGFloat = 132
    /// 光球兩側圓鈕：同尺寸、同邊距、同上下間距（左右完全對稱）。頂列品牌與語言徽章也對齊同一條邊線。
    private static let sideKey: CGFloat = 44
    private static let sideInset: CGFloat = 16
    private static let sideStep: CGFloat = 50
    private static let arcRadius: CGFloat = 98
    private static let voiceHeight: CGFloat = 236
    private static let englishHeight: CGFloat = 262
    private static let zhuyinHeight: CGFloat = 296
    private static let pinyinHeight: CGFloat = 262

    override func viewDidLoad() {
        super.viewDidLoad()
        KeyboardPresence.seen = true
        setupUI()
        bridgeObserver = DarwinObserver(.update) { [weak self] in self?.bridgeUpdated() }
        Haptics.prepare()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 換 app 會讓鍵盤重新出現：先讓舊宿主的證據退役，再讀這次的。
        rebuildArc()
        // 每次叫出鍵盤都從語音開始（打字是修正用的）。錄音中不切。
        if !isRecording { setSurface(.voice, animated: false) }
        HostAppResolver.noteKeyboardAppeared()
        HostAppResolver.harvest()
        // 新的 extension process 第一次出現時 arbiter 約 200 ms 後才有資料，補讀一次。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { HostAppResolver.harvest() }
        refreshContext()
        adoptPendingCommand()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutArc()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        HostAppResolver.harvest()
        refreshContext()
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        HostAppResolver.harvest()
        refreshContext()
    }

    /// 宿主 app 的 return 鍵與選取狀態一變，送出鍵文案與提示跟著變。
    private func refreshContext() {
        returnButton.configuration?.title = ReturnKeyLabel.text(for: textDocumentProxy.returnKeyType)
        typingView.returnTitle = ReturnKeyLabel.text(for: textDocumentProxy.returnKeyType)
        typingView.updateAutoCapitalization(contextBefore: textDocumentProxy.documentContextBeforeInput)
        guard !isRecording else { return }
        let preview = KeyboardMode.decide(selectedText: textDocumentProxy.selectedText, translateTarget: nil)
        setHint(preview.idleHint, error: false)
        if case .edit = preview {
            micButton.setTint(edit: true)
        } else {
            micButton.setTint(edit: false)
        }
        if micButton.orb.phase != .processing { micButton.orb.phase = .idle }
    }

    // MARK: - Layout

    private func setupUI() {
        let height = view.heightAnchor.constraint(equalToConstant: Self.voiceHeight)
        height.priority = UILayoutPriority(999)
        height.isActive = true
        heightConstraint = height

        // 頂緣字幕帶
        brandIcon.contentMode = .scaleAspectFit
        brandIcon.layer.cornerRadius = 7
        brandIcon.layer.cornerCurve = .continuous
        brandIcon.clipsToBounds = true
        brandLabel.text = "UTUVO Type"
        brandLabel.font = .systemFont(ofSize: 17, weight: .bold)
        brandLabel.textColor = .label
        liveDot.backgroundColor = Self.brandOrange
        liveDot.layer.cornerRadius = 4
        liveDot.isHidden = true
        transcriptLabel.font = .systemFont(ofSize: 15, weight: .medium)
        transcriptLabel.textColor = .label
        transcriptLabel.numberOfLines = 1
        transcriptLabel.lineBreakMode = .byTruncatingHead
        transcriptLabel.isHidden = true
        let band = UIStackView(arrangedSubviews: [brandIcon, brandLabel, liveDot, transcriptLabel])
        band.axis = .horizontal
        band.spacing = 8
        band.alignment = .center
        band.translatesAutoresizingMaskIntoConstraints = false
        transcriptPill.addSubview(band)
        NSLayoutConstraint.activate([
            brandIcon.widthAnchor.constraint(equalToConstant: 28),
            brandIcon.heightAnchor.constraint(equalToConstant: 28),
            liveDot.widthAnchor.constraint(equalToConstant: 8),
            liveDot.heightAnchor.constraint(equalToConstant: 8),
            band.leadingAnchor.constraint(equalTo: transcriptPill.leadingAnchor),
            band.trailingAnchor.constraint(lessThanOrEqualTo: transcriptPill.trailingAnchor, constant: -8),
            band.centerYAnchor.constraint(equalTo: transcriptPill.centerYAnchor)
        ])
        transcriptPill.layer.cornerRadius = 15
        transcriptPill.backgroundColor = .clear

        // 提示（光球下方）
        hintLabel.font = .systemFont(ofSize: 13)
        hintLabel.textColor = .secondaryLabel
        hintLabel.textAlignment = .center
        hintLabel.numberOfLines = 2

        // 光球
        micButton.addTarget(self, action: #selector(micTapped), for: .touchUpInside)
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(micLongPress(_:)))
        longPress.minimumPressDuration = 0.35
        longPress.cancelsTouchesInView = true
        micButton.addGestureRecognizer(longPress)
        micButton.orb.levelProvider = { [weak self] in self?.levelChannel?.read() }

        // 語言徽章（右上）
        var langConfig = UIButton.Configuration.plain()
        langConfig.cornerStyle = .capsule
        langConfig.baseForegroundColor = .label
        langConfig.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
        languageButton.configuration = langConfig
        languageButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        languageButton.showsMenuAsPrimaryAction = true
        applyGlass(to: languageButton, radius: 17)
        updateLanguageButton()

        // 左側直排：切打字版面（跟右側對稱）
        for (button, title, label, mode) in [(englishButton, "EN", String(localized: "英文鍵盤"), ModeSwitchView.Mode.english),
                                             (hantButton, "繁", String(localized: "注音鍵盤"), .zhuyin),
                                             (hansButton, "简", String(localized: "拼音鍵盤"), .pinyin)] {
            configureRound(button, symbol: nil, title: title)
            button.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
                var a = attrs
                a.font = .systemFont(ofSize: 16, weight: .semibold)
                return a
            }
            button.accessibilityLabel = label
            button.addAction(UIAction { [weak self] _ in
                Haptics.selection()
                self?.setSurface(mode, animated: true)
            }, for: .touchUpInside)
        }

        // 右側直排：⌫／@／送出
        configureRound(deleteButton, symbol: "delete.left")
        configureRound(atButton, symbol: nil, title: "@")
        deleteButton.addTarget(self, action: #selector(backspace), for: .touchUpInside)
        let deleteHold = UILongPressGestureRecognizer(target: self, action: #selector(deleteLongPress(_:)))
        deleteHold.minimumPressDuration = 0.4
        deleteButton.addGestureRecognizer(deleteHold)
        atButton.addTarget(self, action: #selector(insertAt), for: .touchUpInside)

        var returnConfig = UIButton.Configuration.plain()
        returnConfig.cornerStyle = .capsule
        returnConfig.baseForegroundColor = Self.brandOrange
        returnConfig.title = String(localized: "換行")
        returnConfig.contentInsets = .zero
        returnConfig.titleLineBreakMode = .byClipping
        returnConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var a = attrs
            a.font = .systemFont(ofSize: 13, weight: .semibold)
            return a
        }
        returnButton.configuration = returnConfig
        applyGlass(to: returnButton, radius: Self.sideKey / 2)
        returnButton.addTarget(self, action: #selector(insertNewline), for: .touchUpInside)

        var globeConfig = UIButton.Configuration.plain()
        globeConfig.image = UIImage(systemName: "globe")
        globeConfig.baseForegroundColor = .label
        globeConfig.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        globeButton.configuration = globeConfig
        globeButton.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        // iOS 26 起系統會在自訂鍵盤下方自己放一條地球＋聽寫列，再畫一顆就重複了。
        if #available(iOS 26.0, *) {
            globeButton.isHidden = true
        } else {
            globeButton.isHidden = !needsInputModeSwitchKey
        }

        rebuildArc()

        voiceContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(voiceContainer)
        for v in [transcriptPill, micButton, hintLabel, languageButton, englishButton, hantButton, hansButton,
                  deleteButton, atButton, returnButton, globeButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
            voiceContainer.addSubview(v)
        }
        setupTypingSurface()

        NSLayoutConstraint.activate([
            transcriptPill.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Self.sideInset),
            transcriptPill.trailingAnchor.constraint(lessThanOrEqualTo: languageButton.leadingAnchor, constant: -8),
            voiceContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            voiceContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            voiceContainer.topAnchor.constraint(equalTo: view.topAnchor),
            voiceContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            transcriptPill.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            transcriptPill.heightAnchor.constraint(equalToConstant: 36),

            micButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            micButton.centerYAnchor.constraint(equalTo: view.topAnchor, constant: Self.orbCenterY),
            micButton.widthAnchor.constraint(equalToConstant: Self.orbSize),
            micButton.heightAnchor.constraint(equalToConstant: Self.orbSize),

            hintLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hintLabel.topAnchor.constraint(equalTo: micButton.bottomAnchor, constant: 8),
            hintLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 84),
            hintLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -84),

            languageButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Self.sideInset),
            languageButton.centerYAnchor.constraint(equalTo: transcriptPill.centerYAnchor),

            hantButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Self.sideInset),
            hantButton.centerYAnchor.constraint(equalTo: micButton.centerYAnchor),
            englishButton.centerYAnchor.constraint(equalTo: micButton.centerYAnchor, constant: -Self.sideStep),
            hansButton.centerYAnchor.constraint(equalTo: micButton.centerYAnchor, constant: Self.sideStep),

            deleteButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Self.sideInset),
            deleteButton.centerYAnchor.constraint(equalTo: micButton.centerYAnchor, constant: -Self.sideStep),
            deleteButton.widthAnchor.constraint(equalToConstant: Self.sideKey),
            deleteButton.heightAnchor.constraint(equalToConstant: Self.sideKey),
            atButton.centerXAnchor.constraint(equalTo: deleteButton.centerXAnchor),
            atButton.centerYAnchor.constraint(equalTo: micButton.centerYAnchor),
            atButton.widthAnchor.constraint(equalToConstant: Self.sideKey),
            atButton.heightAnchor.constraint(equalToConstant: Self.sideKey),
            returnButton.centerXAnchor.constraint(equalTo: deleteButton.centerXAnchor),
            returnButton.centerYAnchor.constraint(equalTo: micButton.centerYAnchor, constant: Self.sideStep),
            returnButton.widthAnchor.constraint(equalToConstant: Self.sideKey),
            returnButton.heightAnchor.constraint(equalToConstant: Self.sideKey),

            globeButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            globeButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
            globeButton.widthAnchor.constraint(equalToConstant: 40),
            globeButton.heightAnchor.constraint(equalToConstant: 40)
        ])
        setHint(KeyboardMode.dictate.idleHint, error: false)
        #if DEBUG
        // 截圖用（模擬器沒麥克風、按住時截不到）：App Group 旗標 utuvo.type.keyboard.debugPose
        //   = "recording" 擺出錄音中＋字幕帶；= "arc" 擺出長按弧形語言點。不會真的錄音。
        if let pose = KeyboardPresence.defaults.string(forKey: "utuvo.type.keyboard.debugPose") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                switch pose {
                case "recording":
                    self.micButton.orb.debugSyntheticVoice = true
                    self.setRecordingAppearance(true)
                    self.showTranscript(Locale.preferredLanguages.first?.hasPrefix("zh-Hans") == true
                                        ? "明天下午三点在录音室对 Atmos 母带，记得带" : "明天下午三點在錄音室對 Atmos 母帶，記得帶")
                    self.setHint(KeyboardMode.dictate.recordingHint, error: false)
                case "flow":
                    // 走真正的 handle()：兩段即時字幕（不該進輸入框）→ 3 秒後定稿（只進一次）。
                    self.activeCommandID = UUID()
                    self.handle(.partial("記得帶"), recording: true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.handle(.partial("記得帶耳機和硬碟"), recording: true) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { self.handle(.final("記得帶耳機和硬碟", translated: nil), recording: false) }
                case "arc":
                    self.setArcVisible(true)
                    self.highlightPick(2)
                    self.setHint(String(localized: "滑到語言，放開就翻譯；放開在別處取消"), error: false)
                default: break
                }
            }
        }
        #endif
    }

    /// 長按翻譯弧上的語言點：照使用者在主 app 選的語言（1–5 個）重建。frame 在 layoutArc() 算。
    private var arcCodes: [String] = []

    private func rebuildArc() {
        let targets = TranslationTarget.quickPick
        let codes = targets.map(\.code)
        guard codes != arcCodes else { return }
        arcCodes = codes
        pickerDots.forEach { $0.removeFromSuperview() }
        pickerDots.removeAll()
        pickerLabels.removeAll()
        for (index, target) in targets.enumerated() {
            let dot = UIView()
            dot.layer.cornerRadius = 22
            applyGlass(to: dot, radius: 22, fallback: .secondarySystemFill)
            dot.isHidden = true
            dot.tag = index
            let label = UILabel()
            label.text = target.displayName
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .label
            label.textAlignment = .center
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.6
            dot.addSubview(label)
            label.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: dot.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: dot.centerYAnchor),
                label.widthAnchor.constraint(lessThanOrEqualTo: dot.widthAnchor, constant: -6)
            ])
            pickerDots.append(dot)
            pickerLabels.append(label)
            voiceContainer.addSubview(dot)
        }
        view.setNeedsLayout()
    }

    /// 語言點沿光球上方弧線排列：從 158° 到 22°（左上到右上），半徑 arcRadius。
    private func layoutArc() {
        let center = CGPoint(x: view.bounds.midX, y: Self.orbCenterY)
        let count = pickerDots.count
        guard count > 0 else { return }
        if count == 1 {
            pickerDots[0].bounds = CGRect(x: 0, y: 0, width: 44, height: 44)
            pickerDots[0].center = CGPoint(x: center.x, y: center.y - Self.arcRadius)
            return
        }
        // 語言少時弧收窄，點不要散到兩端。
        let spread = min(136.0, 34.0 * Double(count - 1))
        let start = 90 + spread / 2, end = 90 - spread / 2
        for (i, dot) in pickerDots.enumerated() {
            let deg = start + (end - start) * Double(i) / Double(count - 1)
            let rad = deg * .pi / 180
            let p = CGPoint(x: center.x + CGFloat(cos(rad)) * Self.arcRadius, y: center.y - CGFloat(sin(rad)) * Self.arcRadius)
            dot.bounds = CGRect(x: 0, y: 0, width: 44, height: 44)
            dot.center = p
        }
    }

    private func configureRound(_ button: UIButton, symbol: String?, title: String? = nil) {
        var config = UIButton.Configuration.plain()
        config.cornerStyle = .capsule
        config.baseForegroundColor = .label
        // 圓鈕很小：內距歸零、標題不換行（「EN」曾被擠成兩行）。
        config.contentInsets = .zero
        config.titleLineBreakMode = .byClipping
        if let symbol {
            config.image = UIImage(systemName: symbol)
            config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        } else {
            config.title = title
        }
        button.configuration = config
        button.titleLabel?.font = .systemFont(ofSize: 20, weight: .medium)
        applyGlass(to: button, radius: Self.sideKey / 2)
    }

    /// iOS 26 Liquid Glass；以下退回系統填色。玻璃層墊在按鈕最底下，不吃觸控。
    private func applyGlass(to target: UIView, radius: CGFloat, fallback: UIColor = .tertiarySystemFill) {
        if #available(iOS 26.0, *) {
            let glass = UIGlassEffect()
            glass.isInteractive = target is UIControl
            let effectView = UIVisualEffectView(effect: glass)
            effectView.isUserInteractionEnabled = false
            effectView.layer.cornerRadius = radius
            effectView.clipsToBounds = true
            effectView.translatesAutoresizingMaskIntoConstraints = false
            target.insertSubview(effectView, at: 0)
            NSLayoutConstraint.activate([
                effectView.leadingAnchor.constraint(equalTo: target.leadingAnchor),
                effectView.trailingAnchor.constraint(equalTo: target.trailingAnchor),
                effectView.topAnchor.constraint(equalTo: target.topAnchor),
                effectView.bottomAnchor.constraint(equalTo: target.bottomAnchor)
            ])
        } else {
            target.backgroundColor = fallback
            target.layer.cornerRadius = radius
            target.clipsToBounds = true
        }
    }

    private func updateLanguageButton() {
        let current = language
        languageButton.configuration?.title = current.shortLabel
        languageButton.menu = UIMenu(children: DictationLanguage.allCases.map { lang in
            UIAction(title: lang.localizedName(zh: true), state: lang == current ? .on : .off) { [weak self] _ in
                guard let self else { return }
                self.language = lang
                self.updateLanguageButton()
            }
        })
    }

    // MARK: - 打字模式

    private func setupTypingSurface() {
        for b in [englishButton, hantButton, hansButton] where b !== hantButton {
            NSLayoutConstraint.activate([
                b.centerXAnchor.constraint(equalTo: hantButton.centerXAnchor),
                b.widthAnchor.constraint(equalToConstant: Self.sideKey),
                b.heightAnchor.constraint(equalToConstant: Self.sideKey),
            ])
        }
        NSLayoutConstraint.activate([
            hantButton.widthAnchor.constraint(equalToConstant: Self.sideKey),
            hantButton.heightAnchor.constraint(equalToConstant: Self.sideKey),
        ])

        // 打字區頂列：小光球（回語音）＋候選列＋版面循環鍵
        // 回語音：橘色麥克風＋「語音」字樣的玻璃膠囊（原本只有小光球圖示，真機回報看不出是回語音的鈕）。
        var voiceConfig = UIButton.Configuration.plain()
        voiceConfig.image = UIImage(systemName: "mic.fill")
        voiceConfig.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        voiceConfig.imagePadding = 4
        voiceConfig.title = String(localized: "語音")
        voiceConfig.baseForegroundColor = Self.brandOrange
        voiceConfig.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 12)
        voiceConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var a = attrs
            a.font = .systemFont(ofSize: 14, weight: .semibold)
            return a
        }
        voiceKey.configuration = voiceConfig
        applyGlass(to: voiceKey, radius: 17)
        voiceKey.accessibilityLabel = String(localized: "語音")
        voiceKey.addAction(UIAction { [weak self] _ in
            Haptics.selection()
            self?.setSurface(.voice, animated: true)
        }, for: .touchUpInside)
        configureRound(layoutKey, symbol: nil, title: "EN")
        layoutKey.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var a = attrs
            a.font = .systemFont(ofSize: 15, weight: .semibold)
            return a
        }
        layoutKey.accessibilityLabel = String(localized: "切換鍵盤版面")
        layoutKey.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            Haptics.selection()
            let order: [ModeSwitchView.Mode] = [.english, .zhuyin, .pinyin]
            let next = order[((order.firstIndex(of: self.surface) ?? -1) + 1) % order.count]
            self.setSurface(next, animated: true)
        }, for: .touchUpInside)

        voiceKey.translatesAutoresizingMaskIntoConstraints = false
        layoutKey.translatesAutoresizingMaskIntoConstraints = false
        candidateBar.translatesAutoresizingMaskIntoConstraints = false
        typingView.translatesAutoresizingMaskIntoConstraints = false
        typingView.delegate = self
        typingView.isHidden = true
        candidateBar.isHidden = true
        view.addSubview(typingView)
        view.addSubview(candidateBar)
        view.addSubview(voiceKey)
        view.addSubview(layoutKey)
        voiceKey.isHidden = true
        layoutKey.isHidden = true
        NSLayoutConstraint.activate([
            voiceKey.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            voiceKey.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            voiceKey.heightAnchor.constraint(equalToConstant: 34),
            layoutKey.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            layoutKey.centerYAnchor.constraint(equalTo: voiceKey.centerYAnchor),
            layoutKey.widthAnchor.constraint(equalToConstant: 44),
            layoutKey.heightAnchor.constraint(equalToConstant: 34),
            candidateBar.leadingAnchor.constraint(equalTo: voiceKey.trailingAnchor, constant: 6),
            candidateBar.trailingAnchor.constraint(equalTo: layoutKey.leadingAnchor, constant: -6),
            candidateBar.centerYAnchor.constraint(equalTo: voiceKey.centerYAnchor),
            candidateBar.heightAnchor.constraint(equalToConstant: 40),
            typingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            typingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            typingView.topAnchor.constraint(equalTo: voiceKey.bottomAnchor, constant: 6),
            typingView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -2),
        ])
        candidateBar.onPick = { [weak self] index in self?.pickCandidate(index) }
        // 左右滑切換（語音 → EN → 繁 → 語音）；光球上不接，免得跟長按翻譯的拖曳打架。
        // 用 pan 自己判斷：UISwipe 從按鍵上起手時不穩（按鍵自己也在追蹤觸控）。
        // 掛在語音區、打字區自己身上（掛在鍵盤根 view 上實測收不到）。
        for surfaceView in [voiceContainer, typingView] as [UIView] {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
            pan.cancelsTouchesInView = false
            pan.delegate = self
            surfaceView.addGestureRecognizer(pan)
        }
    }

    private var surface: ModeSwitchView.Mode = .voice

    private func setSurface(_ mode: ModeSwitchView.Mode, animated: Bool) {
        // 換模式前把還在選字的中文送出（不丟使用者打的字）。
        if let ime, !ime.isEmpty { commitComposition() }
        surface = mode
        let hantPinyin = KeyboardPresence.hantUsesPinyin
        let voice = mode == .voice
        voiceContainer.isHidden = !voice
        typingView.isHidden = voice
        voiceKey.isHidden = voice
        layoutKey.isHidden = voice
        layoutKey.configuration?.title = mode == .zhuyin ? "繁" : (mode == .pinyin ? "简" : "EN")
        candidateBar.isHidden = ime == nil
        if !voice {
            typingView.layout = mode == .zhuyin ? (hantPinyin ? .pinyinHant : .zhuyin) : (mode == .pinyin ? .pinyin : .english)
            typingView.updateAutoCapitalization(contextBefore: textDocumentProxy.documentContextBeforeInput)
        }
        heightConstraint?.constant = voice ? Self.voiceHeight : (mode == .zhuyin && !hantPinyin ? Self.zhuyinHeight : (mode == .english ? Self.englishHeight : Self.pinyinHeight))
        refreshCandidates()
    }

    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .ended, !isRecording else { return }
        let t = gesture.translation(in: view)
        // 水平、夠長：才算切換（打字時手指小幅移動不算）。
        guard abs(t.x) > 70, abs(t.x) > abs(t.y) * 2 else { return }
        let all = ModeSwitchView.Mode.allCases
        let step = t.x < 0 ? 1 : all.count - 1
        let next = all[(surface.rawValue + step) % all.count]
        Haptics.selection()
        setSurface(next, animated: true)
    }

    private func refreshCandidates() {
        guard let ime else { candidateBar.show(preedit: "", candidates: []); return }
        candidateBar.show(preedit: ime.preedit, candidates: ime.candidates)
    }

    private func pickCandidate(_ index: Int) {
        guard let ime else { return }
        releaseOwnership()
        let text = index < 0 ? ime.commitAll() : ime.select(at: index)
        if !text.isEmpty { textDocumentProxy.insertText(text) }
        refreshCandidates()
    }

    private func commitComposition() {
        guard let ime else { return }
        let text = ime.commitAll()
        if !text.isEmpty { releaseOwnership(); textDocumentProxy.insertText(text) }
        refreshCandidates()
    }

    // MARK: - Simple keys

    /// 使用者自己動了文字，本鍵盤就不再擁有那段逐字稿——放棄增量替換，避免刪到使用者的字。
    private func releaseOwnership() { insertedText = "" }

    @objc private func insertNewline() {
        releaseOwnership()
        textDocumentProxy.insertText("\n")
    }

    @objc private func insertAt() {
        releaseOwnership()
        textDocumentProxy.insertText("@")
    }

    @objc private func backspace() {
        releaseOwnership()
        textDocumentProxy.deleteBackward()
    }

    @objc private func deleteLongPress(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            deleteRepeat = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.backspace() }
            }
        case .ended, .cancelled, .failed:
            deleteRepeat?.invalidate()
            deleteRepeat = nil
        default: break
        }
    }

    // MARK: - Mic

    @objc private func micTapped() {
        if isRecording {
            Haptics.stop()
            stopRecognition()
        } else {
            Haptics.start()
            pendingTranslateTarget = nil
            Task { await startRecognition() }
        }
    }

    /// 長按＝翻譯：按住出現弧形語言點，滑到語言放開就開始錄；放開在弧以外取消。
    @objc private func micLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard !isRecording else { return }
        let point = gesture.location(in: view)
        switch gesture.state {
        case .began:
            let sourceRaw = language.rawValue
            Task { @MainActor in
                for target in TranslationTarget.quickPick { await FastTranslator.shared.prewarm(sourceRaw: sourceRaw, targetCode: target.code) }
            }
            setArcVisible(true)
            highlightPick(nearest(to: point) ?? pickerDots.count / 2)
            setHint(String(localized: "滑到語言，放開就翻譯；放開在別處取消"), error: false)
        case .changed:
            highlightPick(nearest(to: point))
        case .ended:
            setArcVisible(false)
            if let index = highlightedPick {
                Haptics.start()
                pendingTranslateTarget = arcCodes.indices.contains(index) ? TranslationTarget.all.first { $0.code == arcCodes[index] } : nil
                Task { await startRecognition() }
            } else {
                setHint(KeyboardMode.dictate.idleHint, error: false)
            }
            highlightPick(nil)
        case .cancelled, .failed:
            setArcVisible(false)
            highlightPick(nil)
            setHint(KeyboardMode.dictate.idleHint, error: false)
        default: break
        }
    }

    private func setArcVisible(_ visible: Bool) {
        // 弧最上面那顆會壓到頂緣字幕帶，弧出現時字幕帶先退場。
        transcriptPill.alpha = visible ? 0 : 1
        for dot in pickerDots {
            dot.isHidden = !visible
            dot.alpha = visible ? 0 : 1
        }
        guard visible else { return }
        UIView.animate(withDuration: 0.18) { self.pickerDots.forEach { $0.alpha = 1 } }
    }

    /// 手指離弧上哪個點最近（弧以下太遠＝沒選）。
    private func nearest(to point: CGPoint) -> Int? {
        let orbCenter = CGPoint(x: view.bounds.midX, y: Self.orbCenterY)
        guard point.y < orbCenter.y + Self.orbSize / 2 else { return nil }
        var best: (Int, CGFloat)?
        for dot in pickerDots {
            let d = hypot(dot.center.x - point.x, dot.center.y - point.y)
            if best == nil || d < best!.1 { best = (dot.tag, d) }
        }
        return best?.0
    }

    private func highlightPick(_ index: Int?) {
        if let index, index != highlightedPick { Haptics.selection() }
        highlightedPick = index
        for (i, dot) in pickerDots.enumerated() {
            let on = dot.tag == index
            setDot(dot, highlighted: on)
            pickerLabels[i].textColor = on ? .white : .label
            dot.transform = on ? CGAffineTransform(scaleX: 1.18, y: 1.18) : .identity
        }
    }

    /// 弧上語言點：玻璃圓點，選到的染品牌橘。
    private func setDot(_ dot: UIView, highlighted on: Bool) {
        if #available(iOS 26.0, *), let glassView = dot.subviews.first(where: { $0 is UIVisualEffectView }) as? UIVisualEffectView {
            let glass = UIGlassEffect()
            glass.tintColor = on ? Self.brandOrange : nil
            glassView.effect = glass
        } else {
            dot.backgroundColor = on ? Self.brandOrange : .secondarySystemFill
        }
    }

    private func setRecordingAppearance(_ recording: Bool) {
        micButton.setRecording(recording)
        // 字幕帶：錄音中品牌退場、橘點＋逐字稿進場
        brandLabel.isHidden = recording
        liveDot.isHidden = !recording
        transcriptLabel.isHidden = !recording
        if recording {
            transcriptLabel.text = ""
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1; pulse.toValue = 0.25
            pulse.duration = 0.7; pulse.autoreverses = true; pulse.repeatCount = .infinity
            liveDot.layer.add(pulse, forKey: "pulse")
        } else {
            liveDot.layer.removeAnimation(forKey: "pulse")
        }
        UIView.animate(withDuration: 0.25) {
            self.transcriptPill.backgroundColor = recording ? Self.brandOrange.withAlphaComponent(0.10) : .clear
            self.view.layoutIfNeeded()
        }
    }

    // MARK: - Speech（經主 app）

    private var hasAccess: Bool {
        #if DEBUG && targetEnvironment(simulator)
        // 模擬器「設定」裡的完整存取開關點不動；模擬器沒有 App Group 沙盒限制，Debug 直接放行好驗橋接。
        return true
        #else
        return hasFullAccess // RequestsOpenAccess；沒開＝讀寫不到 App Group，橋接不通
        #endif
    }

    private func startRecognition() async {
        guard !isRecording else { return }
        guard hasAccess else {
            setHint(String(localized: "請到 設定 → 一般 → 鍵盤 → UTUVO Type 開啟「允許完整存取」"), error: true)
            return
        }
        mode = KeyboardMode.decide(selectedText: textDocumentProxy.selectedText, translateTarget: pendingTranslateTarget)
        let id = UUID()
        var command = VoiceBridge.Command(action: .start, id: id, language: language.rawValue, sentAt: Date())
        if case .translate(let target) = mode { command.translateTo = target.code }
        VoiceBridge.writeCommand(command)
        activeCommandID = id
        insertedText = ""
        lastRawTranscript = ""
        // 記住這個指令：跳去主 app 再回來時，鍵盤可能是新的 process，要靠這兩個值接回來。
        KeyboardPresence.defaults.set(id.uuidString, forKey: Self.pendingIDKey)
        if case .translate(let target) = mode {
            KeyboardPresence.defaults.set(target.code, forKey: Self.pendingTranslateKey)
        } else {
            KeyboardPresence.defaults.removeObject(forKey: Self.pendingTranslateKey)
        }

        switch VoiceBridge.startPlan(state: VoiceBridge.readState()) {
        case .sendCommand:
            VoiceBridge.post(.command)
            isRecording = true
            setRecordingAppearance(true)
            setHint(mode.recordingHint, error: false)
        case .openApp:
            let host = HostAppResolver.currentHost(for: self)
            #if DEBUG
            VoiceBridge.write(HostAppResolver.diagnostics(host), name: "debug-host-probe.json")
            #endif
            let url = VoiceBridge.sessionURL(language: language.rawValue, commandID: id, returnTo: host.hostId)
            // 開始震動要先播完再切 app，否則切換會把它吃掉（真機回報第一下沒震）。
            try? await Task.sleep(for: .milliseconds(90))
            if openContainingApp(url) {
                setHint(String(localized: "正在開啟 UTUVO Type 啟動麥克風…回來就在錄了"), error: false)
            } else {
                activeCommandID = nil
                setHint(String(localized: "請先打開 UTUVO Type app 一次，再回來點光球"), error: true)
            }
        }
    }

    private func stopRecognition() {
        guard let id = activeCommandID else { return }
        VoiceBridge.writeCommand(VoiceBridge.Command(action: .stop, id: id, language: language.rawValue, sentAt: Date()))
        VoiceBridge.post(.command)
        isRecording = false
        setRecordingAppearance(false)
        micButton.orb.phase = .processing
        setHint(String(localized: "整理中…"), error: false)
    }

    /// 從主 app 回來：若主 app 正在替我上次發出的指令錄音，就接回錄音狀態。
    private func adoptPendingCommand() {
        guard activeCommandID == nil,
              let raw = KeyboardPresence.defaults.string(forKey: Self.pendingIDKey),
              let id = UUID(uuidString: raw),
              let state = VoiceBridge.readState(), VoiceBridge.isAlive(state), state.commandID == id else { return }
        let target = KeyboardPresence.defaults.string(forKey: Self.pendingTranslateKey)
            .flatMap { code in TranslationTarget.all.first { $0.code == code } }
        pendingTranslateTarget = target
        mode = KeyboardMode.decide(selectedText: textDocumentProxy.selectedText, translateTarget: target)
        activeCommandID = id
        bridgeUpdated()
    }

    /// 主 app 更新了 state：依是否屬於我的指令，顯示逐字稿、定稿或錯誤。
    private func bridgeUpdated() {
        guard let state = VoiceBridge.readState() else { return }
        handle(VoiceBridge.delivery(for: state, expecting: activeCommandID), recording: state.phase == .recording)
    }

    private func handle(_ delivery: VoiceBridge.Delivery, recording: Bool) {
        switch delivery {
        case .ignore:
            break
        case .partial(let text):
            if !isRecording && recording {
                isRecording = true
                setRecordingAppearance(true)
                setHint(mode.recordingHint, error: false)
            }
            lastRawTranscript = text
            showTranscript(text)
            if mode.insertsPartials { applyEdit(to: text) }
        case .final(let text, let translated):
            clearPending()
            if isRecording { isRecording = false; setRecordingAppearance(false) }
            micButton.orb.phase = .idle
            finish(raw: text, appTranslation: translated)
        case .failed(let message):
            clearPending()
            if isRecording { isRecording = false; setRecordingAppearance(false) }
            micButton.orb.phase = .error
            mode = .dictate
            pendingTranslateTarget = nil
            setHint(message, error: true)
        }
    }

    private func clearPending() {
        activeCommandID = nil
        KeyboardPresence.defaults.removeObject(forKey: Self.pendingIDKey)
        KeyboardPresence.defaults.removeObject(forKey: Self.pendingTranslateKey)
    }

    /// 鍵盤 extension 不能用 UIApplication.shared.open；沿 responder chain 找到 UIApplication 再呼叫
    /// `open(_:options:completionHandler:)`（iOS 18 起舊的 openURL: 已失效）。找不到就回 false。
    private func openContainingApp(_ url: URL) -> Bool {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if NSStringFromClass(type(of: current)).contains("UIApplication"), current.responds(to: selector) {
                typealias OpenURL = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
                let imp = current.method(for: selector)
                unsafeBitCast(imp, to: OpenURL.self)(current, selector, url as NSURL, NSDictionary(), nil)
                return true
            }
            responder = current.next
        }
        return false
    }

    /// 定稿：依模式決定文件怎麼變。
    private func finish(raw rawText: String, appTranslation: String? = nil) {
        let raw = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let finishedMode = mode
        pendingTranslateTarget = nil
        mode = .dictate
        switch finishedMode {
        case .dictate:
            let tone = ToneHint.infer(returnKeyType: textDocumentProxy.returnKeyType)
            let cleaned = ToneHint.apply(TextPipeline().clean(raw).output, tone: tone)
            applyEdit(to: cleaned)
            if !raw.isEmpty {
                HistoryStore.shared.append(DictationRecord(raw: raw, cleaned: cleaned, source: .keyboard))
            }
            insertedText = ""
            resetBand()
            refreshContext()

        case .edit(let selection):
            guard !raw.isEmpty else { refreshContext(); return }
            setHint(String(localized: "改寫中…（\(OnDeviceAssistant.currentEngine().badge)）"), error: false)
            Task { @MainActor in
                do {
                    let result = try await OnDeviceAssistant.editSelection(selection, instruction: raw)
                    guard let still = textDocumentProxy.selectedText, !still.isEmpty else {
                        setHint(String(localized: "選取已取消，沒有改動文字"), error: true)
                        return
                    }
                    textDocumentProxy.deleteBackward() // 有選取時刪掉的是整段選取
                    textDocumentProxy.insertText(result)
                    HistoryStore.shared.append(DictationRecord.edit(instruction: raw, result: result, source: .keyboard))
                    resetBand()
                    refreshContext()
                } catch {
                    setHint(error.localizedDescription, error: true)
                }
            }

        case .translate(let target):
            guard !raw.isEmpty else { refreshContext(); return }
            let (cleaned, _) = TextPipeline().clean(raw)
            if let appTranslation, !appTranslation.isEmpty {
                releaseOwnership()
                textDocumentProxy.insertText(appTranslation)
                HistoryStore.shared.append(DictationRecord(raw: raw, cleaned: appTranslation, source: .keyboard))
                resetBand()
                refreshContext()
                return
            }
            setHint(String(localized: "翻成\(target.displayName)中…"), error: false)
            let sourceRaw = language.rawValue
            Task { @MainActor in
                do {
                    let result = try await OnDeviceAssistant.translate(cleaned, to: target, sourceRaw: sourceRaw)
                    releaseOwnership()
                    textDocumentProxy.insertText(result)
                    HistoryStore.shared.append(DictationRecord(raw: raw, cleaned: result, source: .keyboard))
                    resetBand()
                    refreshContext()
                } catch {
                    setHint(error.localizedDescription, error: true)
                }
            }
        }
    }

    /// 用最小編輯把文件裡那段文字換成 `target`（IncrementalInsert 是純函式，有測試）。
    private func applyEdit(to target: String) {
        let plan = IncrementalInsert.plan(previous: insertedText, current: target)
        guard !plan.isNoop else { return }
        for _ in 0..<plan.deleteCount { textDocumentProxy.deleteBackward() }
        if !plan.insert.isEmpty { textDocumentProxy.insertText(plan.insert) }
        insertedText = target
    }

    // MARK: - Hints

    /// 字幕帶同時是品牌列：只換裡面的字，不要藏整條（藏掉＝左上 Logo 跟著不見，真機回報）。
    private func showTranscript(_ text: String) {
        transcriptLabel.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 定稿後字幕帶回到品牌列。
    private func resetBand() {
        transcriptLabel.text = ""
        if !isRecording { setRecordingAppearance(false) }
    }

    private func setHint(_ text: String, error: Bool) {
        hintLabel.text = text
        hintLabel.textColor = error ? .systemRed : .secondaryLabel
    }
}

// MARK: - 光球與波形環（純 UIKit／CoreAnimation，鍵盤 extension 記憶體友善）

/// 光球按鈕：裡面是 OrbView（Metal），取代麥克風圖示。按鈕本身只負責觸控；
/// 光暈畫在按鈕外圍（OrbView 比按鈕大一圈、不吃觸控）。
final class OrbButton: UIControl {
    let orb = OrbView()
    /// 光暈往外留多少點。
    private static let halo: CGFloat = 34

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        addSubview(orb)
        isAccessibilityElement = true
        accessibilityLabel = String(localized: "聽寫")
        accessibilityIdentifier = "utuvoKeyboardOrb"
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let frame = bounds.insetBy(dx: -Self.halo, dy: -Self.halo)
        orb.frame = frame
        orb.sphereFraction = bounds.width / max(frame.width, 1)
    }

    /// 只有圓內算按到。
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let r = bounds.width / 2 + 6
        return hypot(point.x - bounds.midX, point.y - bounds.midY) <= r
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            if isHighlighted { orb.wake() }
            UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.6, initialSpringVelocity: 0,
                           options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.orb.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.93, y: 0.93) : .identity
            }
        }
    }

    /// 說出要怎麼改：光球轉薰衣草，一眼看出現在講的是指示。
    func setTint(edit: Bool) { orb.editPalette = edit }

    func setRecording(_ on: Bool) {
        accessibilityLabel = on ? String(localized: "停止") : String(localized: "聽寫")
        if on { orb.phase = .listening } else if orb.phase == .listening { orb.phase = .idle }
    }
}

extension KeyboardViewController: TypingKeyboardDelegate, UIGestureRecognizerDelegate {
    func typing(insert text: String) {
        if let ime, !ime.isEmpty { commitComposition() }
        releaseOwnership()
        textDocumentProxy.insertText(text)
        typingView.updateAutoCapitalization(contextBefore: textDocumentProxy.documentContextBeforeInput)
    }

    func typing(compose key: Character) {
        ime?.type(key)
        refreshCandidates()
    }

    func typingDelete() {
        if ime?.backspace() == true { refreshCandidates(); return }
        releaseOwnership()
        textDocumentProxy.deleteBackward()
        typingView.updateAutoCapitalization(contextBefore: textDocumentProxy.documentContextBeforeInput)
    }

    func typingSpace() {
        if let ime, !ime.isEmpty {
            // 注音：空白＝一聲（還有打到一半的音時）；否則把整串最佳轉換送出。拼音：直接送出。
            if ime.kind == .zhuyin, ime.hasComposing { ime.space() } else { commitComposition() }
            refreshCandidates()
            return
        }
        typing(insert: " ")
    }

    func typingToggleHantInput() {
        if let ime, !ime.isEmpty { commitComposition() }
        KeyboardPresence.hantUsesPinyin.toggle()
        setSurface(.zhuyin, animated: false)
    }

    func typingReturn() {
        if let ime, !ime.isEmpty { commitComposition(); return }
        releaseOwnership()
        textDocumentProxy.insertText("\n")
    }

    nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        MainActor.assumeIsolated {
            guard let v = touch.view else { return true }
            return !(v is OrbButton || v.isDescendant(of: micButton) || v.isDescendant(of: candidateBar))
        }
    }
}

/// 鍵盤觸覺回饋：開始錄音偏重、停止偏脆，一聽就分得出來；滑過翻譯語言給輕點。
/// 鍵盤 extension 要開「允許完整存取」才會震（沒開時系統靜默忽略，不會出錯）。
@MainActor
enum Haptics {
    private static let startGenerator = UIImpactFeedbackGenerator(style: .medium)
    private static let stopGenerator = UIImpactFeedbackGenerator(style: .rigid)
    private static let selectionGenerator = UISelectionFeedbackGenerator()

    static func prepare() {
        startGenerator.prepare()
        stopGenerator.prepare()
    }
    static func start() { startGenerator.impactOccurred(intensity: 1.0); startGenerator.prepare() }
    static func stop() { stopGenerator.impactOccurred(intensity: 0.9); stopGenerator.prepare() }
    static func selection() { selectionGenerator.selectionChanged() }
}

import UIKit
import UTUVOTypeCore

/// UTUVO Type 鍵盤——「光球鍵盤」（2026-09-17 產品決定：功能對齊，外表是我們自己的）。
/// 視覺語彙沿用主 app：橘色光球 MicOrb 當主角、Aurora 漸層、玻璃圓鈕；錄音時光暈呼吸＋放射狀波形環。
///   - 頂緣「即時字幕帶」：錄音時逐字稿在這裡跑（不是浮動膠囊）；閒置時顯示品牌與模式提示。
///   - 中央光球：點一下聽寫；有選取＝說出要怎麼改；長按出現弧形語言點，滑到放開就翻譯。
///   - 左側：語言小徽章（長按／點選單）、iOS<26 的地球；右側：⌫／@／送出 玻璃圓鈕直排。
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
    private let brandIcon = UIImageView(image: UIImage(systemName: "text.bubble.fill"))
    private let brandLabel = UILabel()
    private let hintLabel = UILabel()
    private let micButton = OrbButton()
    private let waveRing = WaveRingView()
    private let backdrop = CAGradientLayer()
    private let languageButton = UIButton(type: .system)
    private let deleteButton = UIButton(type: .custom)
    private let atButton = UIButton(type: .custom)
    private let returnButton = UIButton(type: .custom)
    private let globeButton = UIButton(type: .custom)
    private var pickerDots: [UIView] = []
    private var pickerLabels: [UILabel] = []
    private var highlightedPick: Int?
    private var deleteRepeat: Timer?

    static let brandOrange = UIColor(red: 0.976, green: 0.451, blue: 0.086, alpha: 1)
    static let brandAmber = UIColor(red: 1.0, green: 0.72, blue: 0.29, alpha: 1)
    private static let orbSize: CGFloat = 96
    private static let orbCenterY: CGFloat = 150
    private static let arcRadius: CGFloat = 108

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
        HostAppResolver.noteKeyboardAppeared()
        HostAppResolver.harvest()
        // 新的 extension process 第一次出現時 arbiter 約 200 ms 後才有資料，補讀一次。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { HostAppResolver.harvest() }
        refreshContext()
        adoptPendingCommand()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        backdrop.frame = view.bounds
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
        guard !isRecording else { return }
        let preview = KeyboardMode.decide(selectedText: textDocumentProxy.selectedText, translateTarget: nil)
        setHint(preview.idleHint, error: false)
        if case .edit = preview {
            micButton.glyph = "text.badge.checkmark"
            micButton.setTint(edit: true)
        } else {
            micButton.glyph = "mic.fill"
            micButton.setTint(edit: false)
        }
    }

    // MARK: - Layout

    private func setupUI() {
        let height = view.heightAnchor.constraint(equalToConstant: 300)
        height.priority = UILayoutPriority(999)
        height.isActive = true

        // Aurora 底色：光球後方一團很淡的橘暈，讓玻璃有東西折射。
        backdrop.type = .radial
        backdrop.colors = [Self.brandOrange.withAlphaComponent(0.16).cgColor, Self.brandAmber.withAlphaComponent(0.05).cgColor, UIColor.clear.cgColor]
        backdrop.locations = [0, 0.45, 1]
        backdrop.startPoint = CGPoint(x: 0.5, y: 0.5)
        backdrop.endPoint = CGPoint(x: 1.0, y: 1.0)
        view.layer.insertSublayer(backdrop, at: 0)

        // 頂緣字幕帶
        brandIcon.tintColor = Self.brandOrange
        brandIcon.contentMode = .scaleAspectFit
        brandLabel.text = "UTUVO Type"
        brandLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        brandLabel.textColor = .secondaryLabel
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
            brandIcon.widthAnchor.constraint(equalToConstant: 16),
            brandIcon.heightAnchor.constraint(equalToConstant: 16),
            liveDot.widthAnchor.constraint(equalToConstant: 8),
            liveDot.heightAnchor.constraint(equalToConstant: 8),
            band.leadingAnchor.constraint(equalTo: transcriptPill.leadingAnchor, constant: 14),
            band.trailingAnchor.constraint(lessThanOrEqualTo: transcriptPill.trailingAnchor, constant: -14),
            band.topAnchor.constraint(equalTo: transcriptPill.topAnchor, constant: 7),
            band.bottomAnchor.constraint(equalTo: transcriptPill.bottomAnchor, constant: -7)
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
        waveRing.isUserInteractionEnabled = false

        // 語言徽章（左）
        var langConfig = UIButton.Configuration.plain()
        langConfig.cornerStyle = .capsule
        langConfig.baseForegroundColor = .label
        langConfig.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
        languageButton.configuration = langConfig
        languageButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        languageButton.showsMenuAsPrimaryAction = true
        applyGlass(to: languageButton, radius: 17)
        updateLanguageButton()

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
        returnConfig.title = "換行"
        returnConfig.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)
        returnButton.configuration = returnConfig
        returnButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        applyGlass(to: returnButton, radius: 20)
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

        for v in [transcriptPill, waveRing, micButton, hintLabel, languageButton, deleteButton, atButton, returnButton, globeButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }

        NSLayoutConstraint.activate([
            transcriptPill.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            transcriptPill.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -12),
            transcriptPill.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            transcriptPill.heightAnchor.constraint(equalToConstant: 30),

            micButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            micButton.centerYAnchor.constraint(equalTo: view.topAnchor, constant: Self.orbCenterY),
            micButton.widthAnchor.constraint(equalToConstant: Self.orbSize),
            micButton.heightAnchor.constraint(equalToConstant: Self.orbSize),
            waveRing.centerXAnchor.constraint(equalTo: micButton.centerXAnchor),
            waveRing.centerYAnchor.constraint(equalTo: micButton.centerYAnchor),
            waveRing.widthAnchor.constraint(equalToConstant: Self.orbSize + 64),
            waveRing.heightAnchor.constraint(equalToConstant: Self.orbSize + 64),

            hintLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hintLabel.topAnchor.constraint(equalTo: micButton.bottomAnchor, constant: 14),
            hintLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 84),
            hintLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -84),

            languageButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            languageButton.centerYAnchor.constraint(equalTo: micButton.centerYAnchor),

            deleteButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            deleteButton.centerYAnchor.constraint(equalTo: micButton.centerYAnchor, constant: -60),
            deleteButton.widthAnchor.constraint(equalToConstant: 48),
            deleteButton.heightAnchor.constraint(equalToConstant: 48),
            atButton.centerXAnchor.constraint(equalTo: deleteButton.centerXAnchor),
            atButton.centerYAnchor.constraint(equalTo: micButton.centerYAnchor),
            atButton.widthAnchor.constraint(equalToConstant: 48),
            atButton.heightAnchor.constraint(equalToConstant: 48),
            returnButton.centerXAnchor.constraint(equalTo: deleteButton.centerXAnchor),
            returnButton.centerYAnchor.constraint(equalTo: micButton.centerYAnchor, constant: 60),
            returnButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 48),

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
                    self.setRecordingAppearance(true)
                    self.showTranscript("明天下午三點在錄音室對 Atmos 母帶，記得帶")
                    self.setHint(KeyboardMode.dictate.recordingHint, error: false)
                case "arc":
                    self.setArcVisible(true)
                    self.highlightPick(2)
                    self.setHint("滑到語言，放開就翻譯；放開在別處取消", error: false)
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
            dot.backgroundColor = .secondarySystemFill
            dot.layer.cornerRadius = 22
            dot.isHidden = true
            dot.tag = index
            let label = UILabel()
            label.text = target.zh
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
            view.addSubview(dot)
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
        if let symbol {
            config.image = UIImage(systemName: symbol)
            config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        } else {
            config.title = title
        }
        button.configuration = config
        button.titleLabel?.font = .systemFont(ofSize: 20, weight: .medium)
        applyGlass(to: button, radius: 24)
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
            setHint("滑到語言，放開就翻譯；放開在別處取消", error: false)
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
            dot.backgroundColor = on ? Self.brandOrange : .secondarySystemFill
            pickerLabels[i].textColor = on ? .white : .label
            dot.transform = on ? CGAffineTransform(scaleX: 1.18, y: 1.18) : .identity
        }
    }

    private func setRecordingAppearance(_ recording: Bool) {
        micButton.setRecording(recording)
        waveRing.setActive(recording)
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
            setHint("請到 設定 → 一般 → 鍵盤 → UTUVO Type 開啟「允許完整存取」", error: true)
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
                setHint("正在開啟 UTUVO Type 啟動麥克風…回來就在錄了", error: false)
            } else {
                activeCommandID = nil
                setHint("請先打開 UTUVO Type app 一次，再回來點光球", error: true)
            }
        }
    }

    private func stopRecognition() {
        guard let id = activeCommandID else { return }
        VoiceBridge.writeCommand(VoiceBridge.Command(action: .stop, id: id, language: language.rawValue, sentAt: Date()))
        VoiceBridge.post(.command)
        isRecording = false
        setRecordingAppearance(false)
        setHint("整理中…", error: false)
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
        switch VoiceBridge.delivery(for: state, expecting: activeCommandID) {
        case .ignore:
            break
        case .partial(let text):
            if !isRecording && state.phase == .recording {
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
            finish(raw: text, appTranslation: translated)
        case .failed(let message):
            clearPending()
            if isRecording { isRecording = false; setRecordingAppearance(false) }
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
            transcriptPill.isHidden = true
            refreshContext()

        case .edit(let selection):
            guard !raw.isEmpty else { refreshContext(); return }
            setHint("改寫中…（\(OnDeviceAssistant.currentEngine().badge)）", error: false)
            Task { @MainActor in
                do {
                    let result = try await OnDeviceAssistant.editSelection(selection, instruction: raw)
                    guard let still = textDocumentProxy.selectedText, !still.isEmpty else {
                        setHint("選取已取消，沒有改動文字", error: true)
                        return
                    }
                    textDocumentProxy.deleteBackward() // 有選取時刪掉的是整段選取
                    textDocumentProxy.insertText(result)
                    HistoryStore.shared.append(DictationRecord.edit(instruction: raw, result: result, source: .keyboard))
                    transcriptPill.isHidden = true
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
                transcriptPill.isHidden = true
                refreshContext()
                return
            }
            setHint("翻成\(target.zh)中…", error: false)
            let sourceRaw = language.rawValue
            Task { @MainActor in
                do {
                    let result = try await OnDeviceAssistant.translate(cleaned, to: target, sourceRaw: sourceRaw)
                    releaseOwnership()
                    textDocumentProxy.insertText(result)
                    HistoryStore.shared.append(DictationRecord(raw: raw, cleaned: result, source: .keyboard))
                    transcriptPill.isHidden = true
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

    private func showTranscript(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        transcriptLabel.text = trimmed
        transcriptPill.isHidden = trimmed.isEmpty
    }

    private func setHint(_ text: String, error: Bool) {
        hintLabel.text = text
        hintLabel.textColor = error ? .systemRed : .secondaryLabel
    }
}

private extension DictationLanguage {
    var shortLabel: String {
        switch self {
        case .traditionalChinese: return "繁中"
        case .simplifiedChinese: return "简中"
        case .englishUS: return "EN"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        }
    }
}

// MARK: - 光球與波形環（純 UIKit／CoreAnimation，鍵盤 extension 記憶體友善）

/// 光球：iOS 26+ 用系統 Liquid Glass（橘色染色、互動形變），跟 iOS 27 圖示同一種材質；
/// 不再疊白色亮面反光（看起來廉價）。iOS 26 以下退回霧面漸層＋細邊光。
final class OrbButton: UIControl {
    private let glyphView = UIImageView()
    private let ring = CAShapeLayer()
    private var glassView: UIVisualEffectView?
    private let fallback = CAGradientLayer()
    private let rim = CAShapeLayer()
    /// iOS 27 圖示材質：上亮下深（很淡）＋邊緣錐形鏡面光（左上最亮）。
    private let depth = CAGradientLayer()
    private let specular = CAGradientLayer()
    private let specularMask = CAShapeLayer()
    private var edit = false

    private static let orange = KeyboardViewController.brandOrange
    private static let violet = UIColor(red: 0.62, green: 0.52, blue: 0.95, alpha: 1)

    var glyph: String = "mic.fill" {
        didSet { glyphView.image = UIImage(systemName: glyph, withConfiguration: UIImage.SymbolConfiguration(pointSize: 32, weight: .semibold)) }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        if #available(iOS 26.0, *) {
            let glass = UIGlassEffect(style: .regular)
            glass.tintColor = Self.orange.withAlphaComponent(0.88)
            glass.isInteractive = true
            let view = UIVisualEffectView(effect: glass)
            view.isUserInteractionEnabled = false
            view.clipsToBounds = true
            addSubview(view)
            glassView = view
        } else {
            // 霧面：上亮下深的同色漸層，沒有白色反光帶。
            fallback.colors = [Self.orange.withAlphaComponent(0.92).cgColor, Self.orange.cgColor]
            fallback.startPoint = CGPoint(x: 0.5, y: 0)
            fallback.endPoint = CGPoint(x: 0.5, y: 1)
            layer.addSublayer(fallback)
        }
        depth.colors = [UIColor.white.withAlphaComponent(0.10).cgColor, UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.08).cgColor]
        depth.locations = [0, 0.45, 1]
        depth.startPoint = CGPoint(x: 0.5, y: 0)
        depth.endPoint = CGPoint(x: 0.5, y: 1)
        layer.addSublayer(depth)
        specular.type = .conic
        specular.startPoint = CGPoint(x: 0.5, y: 0.5)
        specular.endPoint = CGPoint(x: 0, y: 0)   // 起點方向＝左上
        specular.colors = [0.55, 0.05, 0.18, 0.05, 0.55].map { UIColor.white.withAlphaComponent($0).cgColor }
        specular.locations = [0, 0.25, 0.5, 0.75, 1]
        specularMask.fillColor = UIColor.clear.cgColor
        specularMask.strokeColor = UIColor.black.cgColor
        specularMask.lineWidth = 1.2
        specular.mask = specularMask
        layer.addSublayer(specular)
        ring.fillColor = UIColor.clear.cgColor
        ring.strokeColor = Self.orange.withAlphaComponent(0.55).cgColor
        ring.lineWidth = 1.5
        ring.opacity = 0
        layer.addSublayer(ring)
        glyphView.tintColor = .white
        glyphView.contentMode = .center
        glyphView.layer.shadowColor = UIColor.black.cgColor
        glyphView.layer.shadowOpacity = 0.12
        glyphView.layer.shadowRadius = 3
        glyphView.layer.shadowOffset = CGSize(width: 0, height: 1)
        addSubview(glyphView)
        glyph = "mic.fill"
        layer.shadowColor = Self.orange.cgColor
        layer.shadowOpacity = 0.22
        layer.shadowRadius = 18
        layer.shadowOffset = CGSize(width: 0, height: 8)
        isAccessibilityElement = true
        accessibilityLabel = "聽寫"
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let radius = bounds.width / 2
        glassView?.frame = bounds
        glassView?.layer.cornerRadius = radius
        fallback.frame = bounds
        fallback.cornerRadius = radius
        rim.frame = bounds
        rim.path = UIBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5)).cgPath
        depth.frame = bounds
        depth.cornerRadius = radius
        specular.frame = bounds
        specularMask.frame = bounds
        specularMask.path = UIBezierPath(ovalIn: bounds.insetBy(dx: 0.6, dy: 0.6)).cgPath
        glyphView.frame = bounds
        bringSubviewToFront(glyphView)
        ring.frame = bounds
        ring.path = UIBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).cgPath
    }

    override var isHighlighted: Bool {
        didSet {
            // 玻璃自己有互動形變；非玻璃才手動縮。
            guard glassView == nil else { return }
            transform = isHighlighted ? CGAffineTransform(scaleX: 0.95, y: 0.95) : .identity
        }
    }

    /// 說出要怎麼改：玻璃轉薰衣草，一眼看出現在講的是指示。
    func setTint(edit: Bool) {
        self.edit = edit
        let color = edit ? Self.violet : Self.orange
        if #available(iOS 26.0, *), let glassView {
            let glass = UIGlassEffect(style: .regular)
            glass.tintColor = color.withAlphaComponent(0.88)
            glass.isInteractive = true
            glassView.effect = glass
        } else {
            fallback.colors = [color.withAlphaComponent(0.92).cgColor, color.cgColor]
        }
        layer.shadowColor = color.cgColor
    }

    func setRecording(_ on: Bool) {
        glyph = on ? "stop.fill" : (edit ? "text.badge.checkmark" : "mic.fill")
        accessibilityLabel = on ? "停止" : "聽寫"
        layer.shadowOpacity = on ? 0.4 : 0.22
        layer.shadowRadius = on ? 26 : 18
        ring.removeAllAnimations()
        if on {
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 1.0; scale.toValue = 1.4
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.7; fade.toValue = 0
            let group = CAAnimationGroup()
            group.animations = [scale, fade]
            group.duration = 1.6
            group.repeatCount = .infinity
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ring.add(group, forKey: "breathe")
        } else {
            ring.opacity = 0
        }
    }
}

/// 放射狀波形環：光球外圈 28 根短條，錄音時各自以不同節奏伸縮（純時間動畫，不接音量）。
final class WaveRingView: UIView {
    private var bars: [CALayer] = []
    private let count = 28

    override init(frame: CGRect) {
        super.init(frame: frame)
        for _ in 0..<count {
            let bar = CALayer()
            bar.backgroundColor = KeyboardViewController.brandOrange.withAlphaComponent(0.35).cgColor
            bar.cornerRadius = 1.5
            bar.opacity = 0
            layer.addSublayer(bar)
            bars.append(bar)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = bounds.width / 2 - 14
        for (i, bar) in bars.enumerated() {
            let angle = CGFloat(i) / CGFloat(count) * 2 * .pi
            bar.bounds = CGRect(x: 0, y: 0, width: 3, height: 10)
            bar.position = CGPoint(x: c.x + cos(angle) * radius, y: c.y + sin(angle) * radius)
            bar.setAffineTransform(CGAffineTransform(rotationAngle: angle + .pi / 2))
        }
    }

    func setActive(_ on: Bool) {
        for (i, bar) in bars.enumerated() {
            bar.removeAllAnimations()
            if on {
                bar.opacity = 1
                let grow = CABasicAnimation(keyPath: "bounds.size.height")
                grow.fromValue = 6
                grow.toValue = 12 + CGFloat((i * 7) % 11)
                grow.duration = 0.32 + Double((i * 13) % 7) * 0.05
                grow.autoreverses = true
                grow.repeatCount = .infinity
                grow.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                grow.beginTime = CACurrentMediaTime() + Double(i) * 0.02
                bar.add(grow, forKey: "grow")
            } else {
                bar.opacity = 0
            }
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

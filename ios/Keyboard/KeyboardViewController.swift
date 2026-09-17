import UIKit
@preconcurrency import AVFAudio
@preconcurrency import Speech
import UTUVOTypeCore

/// UTUVO Type 鍵盤——對齊 Typeless iOS 的鍵盤面：
/// 品牌列＋語言膠囊／「點一下開始說」大麥克風／⌫／@／送出／地球鍵／錄音中浮動逐字稿膠囊。
/// 三種模式由情境決定（KeyboardMode.decide）：
///   - 聽寫：邊講邊把逐字稿插進游標處，定稿換成 core 清理後的版本、寫回歷史。
///   - 說出要怎麼改：宿主 app 有選取文字時，講的話是指示，改寫結果取代選取。
///   - 放開就翻譯：長按麥克風滑到語言、放開開始錄，定稿翻成該語言貼上。
/// 改寫與翻譯的引擎：iOS 26 Apple Intelligence 裝置端模型優先，其次使用者自填的雲端 key，都沒有就明講。
final class KeyboardViewController: UIInputViewController {
    // MARK: - Speech state
    private var audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var isRecording = false
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
    private let brandLabel = UILabel()
    private let brandIcon = UIImageView(image: UIImage(systemName: "text.bubble.fill"))
    private let languageButton = UIButton(type: .system)
    private let transcriptPill = UIView()
    private let transcriptLabel = UILabel()
    private let hintLabel = UILabel()
    private let micButton = UIButton(type: .custom)
    private let deleteButton = UIButton(type: .custom)
    private let atButton = UIButton(type: .custom)
    private let returnButton = UIButton(type: .custom)
    private let globeButton = UIButton(type: .custom)
    private let translatePicker = UIStackView()
    private var pickerPills: [UILabel] = []
    private var highlightedPick: Int?
    private var micWidth: NSLayoutConstraint!
    private var micHeight: NSLayoutConstraint!
    private var deleteRepeat: Timer?

    private static let brandOrange = UIColor(red: 0.976, green: 0.451, blue: 0.086, alpha: 1)

    override func viewDidLoad() {
        super.viewDidLoad()
        KeyboardPresence.seen = true
        setupUI()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshContext()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        refreshContext()
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        refreshContext()
    }

    /// 宿主 app 的 return 鍵與選取狀態一變，送出鍵文案與提示跟著變。
    private func refreshContext() {
        returnButton.configuration?.title = ReturnKeyLabel.text(for: textDocumentProxy.returnKeyType)
        guard !isRecording else { return }
        let preview = KeyboardMode.decide(selectedText: textDocumentProxy.selectedText, translateTarget: nil)
        setHint(preview.idleHint, error: false)
        if case .edit = preview {
            micButton.configuration?.image = UIImage(systemName: "text.badge.checkmark")
        } else {
            micButton.configuration?.image = UIImage(systemName: "mic.fill")
        }
    }

    // MARK: - Layout

    private func setupUI() {
        let height = view.heightAnchor.constraint(equalToConstant: 296)
        height.priority = UILayoutPriority(999)
        height.isActive = true

        // 品牌列
        brandIcon.tintColor = Self.brandOrange
        brandIcon.contentMode = .scaleAspectFit
        brandLabel.text = "UTUVO Type"
        brandLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        brandLabel.textColor = .label
        let brandRow = UIStackView(arrangedSubviews: [brandIcon, brandLabel])
        brandRow.axis = .horizontal
        brandRow.spacing = 6
        brandRow.alignment = .center

        var langConfig = UIButton.Configuration.plain()
        langConfig.cornerStyle = .capsule
        langConfig.baseForegroundColor = .label
        langConfig.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
        languageButton.configuration = langConfig
        languageButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        languageButton.showsMenuAsPrimaryAction = true
        applyGlass(to: languageButton, radius: 16)
        updateLanguageButton()

        // 逐字稿膠囊
        let waveIcon = UIImageView(image: UIImage(systemName: "waveform"))
        waveIcon.tintColor = .label
        waveIcon.contentMode = .scaleAspectFit
        transcriptLabel.font = .systemFont(ofSize: 15)
        transcriptLabel.textColor = .label
        transcriptLabel.numberOfLines = 1
        transcriptLabel.lineBreakMode = .byTruncatingHead
        let pillRow = UIStackView(arrangedSubviews: [waveIcon, transcriptLabel])
        pillRow.axis = .horizontal
        pillRow.spacing = 8
        pillRow.alignment = .center
        pillRow.translatesAutoresizingMaskIntoConstraints = false
        transcriptPill.addSubview(pillRow)
        NSLayoutConstraint.activate([
            waveIcon.widthAnchor.constraint(equalToConstant: 18),
            pillRow.leadingAnchor.constraint(equalTo: transcriptPill.leadingAnchor, constant: 14),
            pillRow.trailingAnchor.constraint(equalTo: transcriptPill.trailingAnchor, constant: -14),
            pillRow.topAnchor.constraint(equalTo: transcriptPill.topAnchor, constant: 8),
            pillRow.bottomAnchor.constraint(equalTo: transcriptPill.bottomAnchor, constant: -8)
        ])
        applyGlass(to: transcriptPill, radius: 18, fallback: .systemBackground)
        transcriptPill.layer.shadowColor = UIColor.black.cgColor
        transcriptPill.layer.shadowOpacity = 0.10
        transcriptPill.layer.shadowRadius = 10
        transcriptPill.layer.shadowOffset = CGSize(width: 0, height: 4)
        transcriptPill.isHidden = true

        // 提示
        hintLabel.font = .systemFont(ofSize: 13)
        hintLabel.textColor = .secondaryLabel
        hintLabel.textAlignment = .center
        hintLabel.numberOfLines = 2

        // 麥克風
        var micConfig = UIButton.Configuration.filled()
        micConfig.cornerStyle = .capsule
        micConfig.baseBackgroundColor = .label
        micConfig.baseForegroundColor = .systemBackground
        micConfig.image = UIImage(systemName: "mic.fill")
        micConfig.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 26, weight: .semibold)
        micButton.configuration = micConfig
        micButton.addTarget(self, action: #selector(micTapped), for: .touchUpInside)
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(micLongPress(_:)))
        longPress.minimumPressDuration = 0.35
        longPress.cancelsTouchesInView = true
        micButton.addGestureRecognizer(longPress)

        // 圓鍵：⌫ 與 @；膠囊：送出；地球
        configureRound(deleteButton, symbol: "delete.left")
        configureRound(atButton, symbol: nil, title: "@")
        deleteButton.addTarget(self, action: #selector(backspace), for: .touchUpInside)
        let deleteHold = UILongPressGestureRecognizer(target: self, action: #selector(deleteLongPress(_:)))
        deleteHold.minimumPressDuration = 0.4
        deleteButton.addGestureRecognizer(deleteHold)
        atButton.addTarget(self, action: #selector(insertAt), for: .touchUpInside)

        var returnConfig = UIButton.Configuration.plain()
        returnConfig.cornerStyle = .capsule
        returnConfig.baseForegroundColor = .label
        returnConfig.title = "換行"
        returnConfig.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 28, bottom: 12, trailing: 28)
        returnButton.configuration = returnConfig
        returnButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .medium)
        applyGlass(to: returnButton, radius: 24, fallback: .systemBackground)
        returnButton.addTarget(self, action: #selector(insertNewline), for: .touchUpInside)

        var globeConfig = UIButton.Configuration.plain()
        globeConfig.image = UIImage(systemName: "globe")
        globeConfig.baseForegroundColor = .label
        globeConfig.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        globeButton.configuration = globeConfig
        globeButton.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        // iOS 26 起系統會在自訂鍵盤下方自己放一條地球＋聽寫列，再畫一顆就重複了（模擬器實看）。
        if #available(iOS 26.0, *) {
            globeButton.isHidden = true
        } else {
            globeButton.isHidden = !needsInputModeSwitchKey
        }

        // 長按翻譯弧：五個語言膠囊，中間預設英文
        translatePicker.axis = .horizontal
        translatePicker.spacing = 8
        translatePicker.alignment = .center
        translatePicker.distribution = .fillProportionally
        for (index, target) in TranslationTarget.quickPick.enumerated() {
            let pill = UILabel()
            pill.text = target.zh
            pill.font = .systemFont(ofSize: 14, weight: .semibold)
            pill.textAlignment = .center
            pill.textColor = .label
            pill.layer.cornerRadius = 17
            pill.layer.masksToBounds = true
            pill.backgroundColor = .secondarySystemFill
            pill.translatesAutoresizingMaskIntoConstraints = false
            pill.heightAnchor.constraint(equalToConstant: 34).isActive = true
            pill.widthAnchor.constraint(greaterThanOrEqualToConstant: 60).isActive = true
            pill.tag = index
            pickerPills.append(pill)
            translatePicker.addArrangedSubview(pill)
        }
        translatePicker.isHidden = true

        for v in [brandRow, languageButton, transcriptPill, hintLabel, micButton, deleteButton, atButton, returnButton, globeButton, translatePicker] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        micWidth = micButton.widthAnchor.constraint(equalToConstant: 220)
        micHeight = micButton.heightAnchor.constraint(equalToConstant: 72)

        NSLayoutConstraint.activate([
            brandRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            brandRow.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            brandIcon.widthAnchor.constraint(equalToConstant: 18),
            brandIcon.heightAnchor.constraint(equalToConstant: 18),
            languageButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            languageButton.centerYAnchor.constraint(equalTo: brandRow.centerYAnchor),

            transcriptPill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            transcriptPill.topAnchor.constraint(equalTo: brandRow.bottomAnchor, constant: 10),
            transcriptPill.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            transcriptPill.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),

            translatePicker.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            translatePicker.topAnchor.constraint(equalTo: brandRow.bottomAnchor, constant: 12),

            micButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            micButton.centerYAnchor.constraint(equalTo: view.topAnchor, constant: 146),
            micWidth, micHeight,

            hintLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hintLabel.bottomAnchor.constraint(equalTo: micButton.topAnchor, constant: -10),
            hintLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 90),
            hintLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -90),

            deleteButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -22),
            deleteButton.centerYAnchor.constraint(equalTo: micButton.centerYAnchor, constant: 34),
            deleteButton.widthAnchor.constraint(equalToConstant: 56),
            deleteButton.heightAnchor.constraint(equalToConstant: 56),
            atButton.trailingAnchor.constraint(equalTo: deleteButton.trailingAnchor),
            atButton.topAnchor.constraint(equalTo: deleteButton.bottomAnchor, constant: 14),
            atButton.widthAnchor.constraint(equalToConstant: 56),
            atButton.heightAnchor.constraint(equalToConstant: 56),

            returnButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            returnButton.topAnchor.constraint(equalTo: micButton.bottomAnchor, constant: 22),
            returnButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),

            globeButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            globeButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
            globeButton.widthAnchor.constraint(equalToConstant: 44),
            globeButton.heightAnchor.constraint(equalToConstant: 44)
        ])
        setHint(KeyboardMode.dictate.idleHint, error: false)
    }

    private func configureRound(_ button: UIButton, symbol: String?, title: String? = nil) {
        var config = UIButton.Configuration.plain()
        config.cornerStyle = .capsule
        config.baseForegroundColor = .label
        if let symbol {
            config.image = UIImage(systemName: symbol)
            config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        } else {
            config.title = title
        }
        button.configuration = config
        button.titleLabel?.font = .systemFont(ofSize: 22, weight: .medium)
        applyGlass(to: button, radius: 28)
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
            stopRecognition()
        } else {
            pendingTranslateTarget = nil
            Task { await startRecognition() }
        }
    }

    /// 長按＝翻譯：按住出現語言弧，滑到語言放開就開始錄；放開在弧以外取消。
    @objc private func micLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard !isRecording else { return }
        let point = gesture.location(in: view)
        switch gesture.state {
        case .began:
            translatePicker.isHidden = false
            transcriptPill.isHidden = true
            highlightPick(nearest(to: point) ?? 2)
            setHint("滑到語言，放開就翻譯；放開在別處取消", error: false)
        case .changed:
            highlightPick(nearest(to: point))
        case .ended:
            translatePicker.isHidden = true
            if let index = highlightedPick {
                pendingTranslateTarget = TranslationTarget.quickPick[index]
                Task { await startRecognition() }
            } else {
                setHint(KeyboardMode.dictate.idleHint, error: false)
            }
            highlightPick(nil)
        case .cancelled, .failed:
            translatePicker.isHidden = true
            highlightPick(nil)
            setHint(KeyboardMode.dictate.idleHint, error: false)
        default: break
        }
    }

    private func nearest(to point: CGPoint) -> Int? {
        let pickerFrame = translatePicker.frame
        guard point.y < pickerFrame.maxY + 90 else { return nil }
        var best: (Int, CGFloat)?
        for pill in pickerPills {
            let frame = pill.convert(pill.bounds, to: view)
            let distance = abs(frame.midX - point.x)
            if best == nil || distance < best!.1 { best = (pill.tag, distance) }
        }
        return best?.0
    }

    private func highlightPick(_ index: Int?) {
        highlightedPick = index
        for pill in pickerPills {
            let on = pill.tag == index
            pill.backgroundColor = on ? .label : .secondarySystemFill
            pill.textColor = on ? .systemBackground : .label
            pill.transform = on ? CGAffineTransform(scaleX: 1.12, y: 1.12) : .identity
        }
    }

    private func setRecordingAppearance(_ recording: Bool) {
        micWidth.constant = recording ? 88 : 220
        micHeight.constant = recording ? 88 : 72
        micButton.configuration?.baseBackgroundColor = recording ? Self.brandOrange : .label
        micButton.configuration?.image = UIImage(systemName: recording ? "waveform" : "mic.fill")
        UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0.4) {
            self.view.layoutIfNeeded()
        }
    }

    // MARK: - Speech

    private var hasAccess: Bool { hasFullAccess } // RequestsOpenAccess；沒開＝無法用 server 辨識，也讀不到字典／歷史

    private func startRecognition() async {
        guard !isRecording else { return }
        guard hasAccess else {
            setHint("請到 設定 → 一般 → 鍵盤 → UTUVO Type 開啟「允許完整存取」", error: true)
            return
        }
        mode = KeyboardMode.decide(selectedText: textDocumentProxy.selectedText, translateTarget: pendingTranslateTarget)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            // TCC 從背景執行緒回呼，continuation 不能綁在 MainActor（UIInputViewController 是 @MainActor），
            // 否則 Swift 6 執行期直接 SIGTRAP。
            let auth = await Self.requestSpeechAuthorization()
            guard auth == .authorized else {
                setHint("需要語音辨識權限", error: true)
                return
            }
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language.rawValue)),
                  recognizer.isAvailable else {
                setHint("這個語言的辨識器目前不可用", error: true)
                return
            }
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            self.request = request

            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            // sampleRate 為 0（無可用輸入）時 installTap 會在引擎內部 assert，會連宿主 app 一起帶走。先擋。
            guard format.sampleRate > 0, format.channelCount > 0 else {
                setHint("找不到麥克風輸入，無法錄音", error: true)
                self.request = nil
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                return
            }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }
            try audioEngine.start()

            insertedText = ""
            lastRawTranscript = ""
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                guard let self else { return }
                DispatchQueue.main.async {
                    if let result { self.handle(result: result) }
                    if let error, (error as NSError).code != 216 {
                        self.setHint("辨識中斷：\(error.localizedDescription)", error: true)
                        if self.isRecording { self.stopRecognition() }
                    }
                }
            }
            isRecording = true
            setRecordingAppearance(true)
            setHint(mode.recordingHint, error: false)
        } catch {
            setHint("無法啟動：\(error.localizedDescription)", error: true)
        }
    }

    private func handle(result: SFSpeechRecognitionResult) {
        let raw = result.bestTranscription.formattedString
        lastRawTranscript = raw
        showTranscript(raw)

        if result.isFinal {
            finish(raw: raw)
        } else if mode.insertsPartials {
            applyEdit(to: raw)
        }
    }

    /// 定稿：依模式決定文件怎麼變。
    private func finish(raw rawText: String) {
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
                    HistoryStore.shared.append(DictationRecord(raw: "改：\(raw)", cleaned: result, source: .keyboard))
                    transcriptPill.isHidden = true
                    refreshContext()
                } catch {
                    setHint(error.localizedDescription, error: true)
                }
            }

        case .translate(let target):
            guard !raw.isEmpty else { refreshContext(); return }
            let (cleaned, _) = TextPipeline().clean(raw)
            setHint("翻成\(target.zh)中…（\(OnDeviceAssistant.currentEngine().badge)）", error: false)
            Task { @MainActor in
                do {
                    let result = try await OnDeviceAssistant.translate(cleaned, to: target)
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

    nonisolated private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in cont.resume(returning: status) }
        }
    }

    private func stopRecognition() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()
        isRecording = false
        setRecordingAppearance(false)
        setHint("整理中…", error: false)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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

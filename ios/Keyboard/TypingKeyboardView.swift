import UIKit

/// 打字鍵盤（語音辨識不準時就地修正用）：英文 QWERTY 與注音（大千）兩種版面，外加數字／符號層。
/// 純 UIKit、不掛 SwiftUI，顧鍵盤 extension 記憶體。文字怎麼進文件由 delegate（KeyboardViewController）決定。
@MainActor
protocol TypingKeyboardDelegate: AnyObject {
    /// 英文、數字、符號鍵：直接插入。`learn` 為 false＝先不進自動學字典（等手指放開確定沒收回才學）。
    func typing(insert text: String, learn: Bool)
    /// 按下就插了字，但手指滑開變成切換鍵盤的手勢＝收回剛剛那個字。
    func typingUndoInsert(_ text: String)
    /// 確定沒收回：把這個字交給自動學字典。
    func typingLearn(_ text: String)
    /// 注音／拼音：按下就收回引擎（收回用 typingUndoCompose）。
    func typingUndoCompose()
    /// 空白／刪除按下就做了，滑開時收回。
    func typingUndoSpace()
    func typingUndoDelete()
    /// 注音符號／聲調，或拼音字母：交給中文輸入引擎。
    func typing(compose key: Character)
    func typingDelete()
    func typingSpace()
    /// 「繁」鍵盤在注音與拼音之間切換。
    func typingToggleHantInput()
    func typingReturn()
    func typingDidSwitchToLetters()
}

@MainActor
final class TypingKeyboardView: UIView, UIInputViewAudioFeedback {
    enum Layout: Equatable { case english, zhuyin, pinyin, pinyinHant }
    private enum Layer { case letters, numbers, symbols }
    private enum Shift { case off, once, locked }

    weak var delegate: TypingKeyboardDelegate?
    var layout: Layout = .english { didSet { if layout != oldValue { keyLayer = .letters; rebuild() } } }
    /// 宿主 app 的 return 鍵文案（傳送／前往／換行…）。
    var returnTitle = String(localized: "換行") { didSet { returnKey?.setTitle(returnTitle, for: .normal) } }

    private var keyLayer: Layer = .letters
    private var shift: Shift = .off
    private var lastShiftTap: CFTimeInterval = 0
    private let rowsStack = UIStackView()
    private weak var returnKey: KeyButton?
    private var letterKeys: [KeyButton] = []
    private var deleteRepeat: Timer?

    var enableInputClicksWhenVisible: Bool { true }

    override init(frame: CGRect) {
        super.init(frame: frame)
        rowsStack.axis = .vertical
        rowsStack.spacing = 10
        rowsStack.distribution = .fillEqually
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rowsStack)
        NSLayoutConstraint.activate([
            rowsStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            rowsStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            rowsStack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            rowsStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 句首自動大寫：宿主游標前是空的或剛打完句號。
    /// 剛插進去的字就足以決定下一個字要不要大寫（句號、問號、驚嘆號、換行之後大寫），
    /// 不必再去問宿主 app 游標前的文字（跨行程、會頓）。
    func updateAutoCapitalization(afterInserting text: String) {
        guard layout == .english, keyLayer == .letters, shift != .locked else { return }
        guard let last = text.last else { return }
        if last == "\n" { setShift(.once); return }
        // 「. 」這種：句末標點後面接空白才換成大寫；其他字一律小寫狀態。
        if last == " " {
            let beforeSpace = text.dropLast().last
            setShift(beforeSpace.map { ".!?".contains($0) } == true ? .once : shiftAfterSpace())
            return
        }
        setShift(.off)
    }

    /// 只有一個空白鍵的情況（text == " "）：維持現在的狀態，不要把使用者按的 shift 清掉。
    private func shiftAfterSpace() -> Shift { shift == .once ? .once : .off }

    func updateAutoCapitalization(contextBefore: String?) {
        guard layout == .english, keyLayer == .letters, shift != .locked else { return }
        let before = contextBefore ?? ""
        let trimmed = before.trimmingCharacters(in: .whitespaces)
        let start = before.isEmpty || trimmed.last.map { ".!?\n".contains($0) } == true && before.last == " " || before.hasSuffix("\n")
        setShift(start ? .once : .off)
    }

    // MARK: - 版面

    private static let englishRows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
    /// iOS 系統注音（大千）版面，聲調在第一排。
    private static let zhuyinRows = ["ㄅㄉˇˋㄓˊ˙ㄚㄞㄢㄦ", "ㄆㄊㄍㄐㄔㄗㄧㄛㄟㄣ", "ㄇㄋㄎㄑㄕㄘㄨㄜㄠㄤ", "ㄈㄌㄏㄒㄖㄙㄩㄝㄡㄥ"]
    private static let numberRows = ["1234567890", "-/:;()$&@\"", ".,?!'"]
    private static let symbolRows = ["[]{}#%^*+=", "_\\|~<>€£¥•", ".,?!'"]
    /// 注音的數字／符號層用全形中文標點。
    private static let zhuyinNumberRows = ["1234567890", "，。？！、：；「」…", "（）《》～"]

    private func rebuild() {
        rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        letterKeys.removeAll()
        switch (layout, keyLayer) {
        case (.english, .letters):
            for (i, row) in Self.englishRows.enumerated() {
                var keys = row.map { charKey(String($0)) }
                letterKeys += keys
                if i == 2 {
                    keys.insert(specialKey(symbol: "shift", width: 1.5) { [weak self] in self?.shiftTapped() }, at: 0)
                    keys.append(deleteKey(width: 1.5))
                }
                // 三排都以 10 格為底，字母鍵才會等寬（第二排左右各留半格、第三排特殊鍵吃掉差額）。
                addRow(keys, inset: i == 1 ? 0.5 : 0, totalUnits: 10)
            }
            applyShiftLabels()
        case (.zhuyin, .letters):
            for (i, row) in Self.zhuyinRows.enumerated() {
                var keys = row.map { ch in
                    let key = KeyButton(title: String(ch), style: .character, fontSize: 19)
                    key.onDown = { [weak self] in self?.delegate?.typing(compose: ch) }
                    key.onUndo = { [weak self] in self?.delegate?.typingUndoCompose() }
                    return key
                }
                if i == 3 { keys.append(deleteKey(width: 1.0)) }
                addRow(keys, inset: 0, totalUnits: 11)
            }
        case (.pinyin, .letters), (.pinyinHant, .letters):
            // 拼音（簡體、繁體同版面）：QWERTY 字母交給拼音引擎；第三排左邊是音節分隔鍵（xi'an）。
            for (i, row) in Self.englishRows.enumerated() {
                var keys = row.map { ch -> KeyButton in
                    let key = KeyButton(title: String(ch), style: .character, fontSize: 22)
                    key.onDown = { [weak self] in self?.delegate?.typing(compose: ch) }
                    key.onUndo = { [weak self] in self?.delegate?.typingUndoCompose() }
                    return key
                }
                if i == 2 {
                    let sep = KeyButton(title: "'", style: .special, fontSize: 20)
                    sep.widthUnits = 1.5
                    sep.accessibilityLabel = String(localized: "分隔音節")
                    sep.onDown = { [weak self] in self?.delegate?.typing(compose: "'") }
                    sep.onUndo = { [weak self] in self?.delegate?.typingUndoCompose() }
                    keys.insert(sep, at: 0)
                    keys.append(deleteKey(width: 1.5))
                }
                addRow(keys, inset: i == 1 ? 0.5 : 0, totalUnits: 10)
            }
        case (_, .numbers), (_, .symbols):
            let rows = layout != .english ? Self.zhuyinNumberRows : (keyLayer == .numbers ? Self.numberRows : Self.symbolRows)
            for (i, row) in rows.enumerated() {
                var keys = row.map { charKey(String($0), raw: true) }
                if i == 2 {
                    if layout == .english {
                        let toggle = keyLayer == .numbers ? "#+=" : "123"
                        keys.insert(specialKey(title: toggle, width: 1.4) { [weak self] in
                            guard let self else { return }
                            self.keyLayer = self.keyLayer == .numbers ? .symbols : .numbers
                            self.rebuild()
                        }, at: 0)
                    }
                    keys.append(deleteKey(width: 1.4))
                }
                addRow(keys, inset: 0)
            }
        }
        addBottomRow()
    }

    private func addBottomRow() {
        let layerKey = specialKey(title: keyLayer == .letters ? "123" : (layout == .zhuyin ? String(localized: "注音") : (layout == .english ? "ABC" : String(localized: "拼音"))), width: 1.3) { [weak self] in
            guard let self else { return }
            self.keyLayer = self.keyLayer == .letters ? .numbers : .letters
            self.rebuild()
            if self.keyLayer == .letters { self.delegate?.typingDidSwitchToLetters() }
        }
        let space = KeyButton(title: layout == .english ? "space" : (layout == .pinyin ? String(localized: "空格") : String(localized: "空白")), style: .character, fontSize: 15)
        // 空白也按下就出（最常按的鍵之一）；滑開就收回。
        space.onDown = { [weak self] in self?.delegate?.typingSpace() }
        space.onUndo = { [weak self] in self?.delegate?.typingUndoSpace() }
        let ret = KeyButton(title: returnTitle, style: .special, fontSize: 15)
        ret.onTap = { [weak self] in self?.delegate?.typingReturn() }
        returnKey = ret
        var keys = [layerKey, space, ret]
        // 繁：底排多一顆「拼／注」切換輸入法（選擇存 App Group，主 app 設定頁也能改）。
        let hantToggle: KeyButton? = (layout == .zhuyin || layout == .pinyinHant) && keyLayer == .letters
            ? specialKey(title: layout == .zhuyin ? "拼" : "注", width: 1) { [weak self] in self?.delegate?.typingToggleHantInput() }
            : nil
        if let hantToggle {
            hantToggle.accessibilityLabel = layout == .zhuyin ? String(localized: "改用拼音") : String(localized: "改用注音")
            keys.insert(hantToggle, at: 1)
        }
        let row = UIStackView(arrangedSubviews: keys)
        row.spacing = 6
        row.distribution = .fill
        layerKey.widthAnchor.constraint(equalTo: row.widthAnchor, multiplier: 0.2).isActive = true
        hantToggle?.widthAnchor.constraint(equalTo: row.widthAnchor, multiplier: 0.11).isActive = true
        ret.widthAnchor.constraint(equalTo: row.widthAnchor, multiplier: 0.24).isActive = true
        rowsStack.addArrangedSubview(row)
    }

    private func addRow(_ keys: [KeyButton], inset: CGFloat, totalUnits: CGFloat? = nil) {
        let row = UIStackView()
        row.spacing = 6
        row.distribution = .fill
        row.alignment = .fill
        // 一般鍵等寬、特殊鍵依倍數，第二排英文左右縮半格（對齊系統鍵盤）。
        let units = totalUnits ?? (keys.reduce(0) { $0 + $1.widthUnits } + inset * 2)
        let container = UIView()
        container.addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        let unitGuide = UILayoutGuide()
        container.addLayoutGuide(unitGuide)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: container.topAnchor),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            row.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            unitGuide.widthAnchor.constraint(equalTo: container.widthAnchor, multiplier: 1 / units, constant: -6 * (units - 1) / units),
        ])
        for key in keys {
            row.addArrangedSubview(key)
            key.widthAnchor.constraint(equalTo: unitGuide.widthAnchor, multiplier: key.widthUnits).isActive = true
        }
        rowsStack.addArrangedSubview(container)
    }

    private func charKey(_ title: String, raw: Bool = false) -> KeyButton {
        let key = KeyButton(title: title, style: .character, fontSize: raw ? 20 : 22)
        var inserted = ""
        key.onDown = { [weak self] in
            guard let self else { return }
            inserted = self.layout == .english && self.keyLayer == .letters && self.shift != .off ? title.uppercased() : title
            self.delegate?.typing(insert: inserted, learn: false)
            if self.shift == .once { self.setShift(.off) }
        }
        key.onUndo = { [weak self] in self?.delegate?.typingUndoInsert(inserted) }
        key.onCommit = { [weak self] in self?.delegate?.typingLearn(inserted) }
        return key
    }

    private func specialKey(title: String? = nil, symbol: String? = nil, width: CGFloat, action: @escaping () -> Void) -> KeyButton {
        let key = KeyButton(title: title, symbol: symbol, style: .special, fontSize: 15)
        key.widthUnits = width
        key.onTap = { [weak self] in action() }
        return key
    }

    private func deleteKey(width: CGFloat) -> KeyButton {
        let key = KeyButton(title: nil, symbol: "delete.left", style: .special, fontSize: 17)
        key.widthUnits = width
        // 刪除也是按下就刪（系統鍵盤一樣）；滑開變成切換手勢就把刪掉的字補回來。
        key.onDown = { [weak self] in self?.delegate?.typingDelete() }
        key.onUndo = { [weak self] in self?.delegate?.typingUndoDelete() }
        // 按住連刪。
        key.onHold = { [weak self] began in
            guard let self else { return }
            self.deleteRepeat?.invalidate()
            guard began else { return }
            self.deleteRepeat = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.repeatTick()
                    self?.delegate?.typingDelete()
                }
            }
        }
        return key
    }

    private func shiftTapped() {
        let now = CACurrentMediaTime()
        if now - lastShiftTap < 0.3 { setShift(.locked) } else { setShift(shift == .off ? .once : .off) }
        lastShiftTap = now
    }

    private func setShift(_ s: Shift) {
        // 同樣的 Shift 值別跑：每次都跑 26 個字母鍵 setTitle + row tree traversal + shift symbol relabel，
        // updateAutoCapitalization 進到這個函式的頻率很高（每按一鍵算大小寫），沒變化時跑就白做工。
        // 保留 caps/locked/off/once 的行為；rebuild() 內部仍會主動呼叫 applyShiftLabels。
        guard shift != s else { return }
        shift = s
        applyShiftLabels()
    }

    private func applyShiftLabels() {
        for key in letterKeys { key.setTitle(shift == .off ? key.baseTitle : key.baseTitle.uppercased(), for: .normal) }
        let shiftKey = rowsStack.arrangedSubviews.compactMap { ($0.subviews.first as? UIStackView)?.arrangedSubviews.first as? KeyButton }
            .first { $0.symbolName?.hasPrefix("shift") == true }
        shiftKey?.setSymbol(shift == .locked ? "capslock.fill" : (shift == .once ? "shift.fill" : "shift"))
    }

    /// 舊的「放開才震」已經移到 KeyButton.touchesBegan；這裡只留給沒有 KeyButton 的路徑（連續刪除）。
    private func repeatTick() {
        KeyFeedback.down(.repeatTick, hasFullAccess: KeyButton.hasFullAccess)
    }
}

/// 一顆鍵：系統鍵盤的樣子（圓角、底部細陰影），手指滑開超過 20 pt 就不算按（避免左右滑切換時誤打字）。
final class KeyButton: UIButton {
    enum Style { case character, special }
    var onTap: (() -> Void)?
    /// 按下去就先做（打字要快：系統鍵盤也是按下就出字）；手指滑開或被取消時呼叫 onUndo 收回。
    var onDown: (() -> Void)?
    var onUndo: (() -> Void)?
    /// 放開時才做的收尾（自動學字典：插字當下先不學，確定沒收回才學）。
    var onCommit: (() -> Void)?
    var onHold: ((Bool) -> Void)?
    var widthUnits: CGFloat = 1
    let baseTitle: String
    private(set) var symbolName: String?
    private let style: Style
    private var downPoint: CGPoint = .zero
    private var holdTimer: Timer?
    /// 這一次觸控已經在按下時做過動作了（放開時就不要再做一次）。
    private var firedOnDown = false
    /// 觸控已被收回（滑開 > 20pt 或系統取消）；之後 touchesEnded 不再做任何動作。
    /// 不記這個的話，使用者滑出去再滑回來按 release 會被當作正常 tap（onTap／onCommit）。
    private var cancelled = false
    /// 鍵盤 extension 沒開「允許完整存取」就震不了；由 KeyboardViewController 在載入時填。
    nonisolated(unsafe) static var hasFullAccess = true

    init(title: String?, symbol: String? = nil, style: Style, fontSize: CGFloat) {
        self.baseTitle = title ?? ""
        self.style = style
        super.init(frame: .zero)
        setTitle(title, for: .normal)
        titleLabel?.font = .systemFont(ofSize: fontSize, weight: style == .character ? .regular : .medium)
        setTitleColor(.label, for: .normal)
        if let symbol { setSymbol(symbol) }
        tintColor = .label
        layer.cornerRadius = 8.5
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.28
        layer.shadowRadius = 0
        layer.shadowOffset = CGSize(width: 0, height: 1)
        applyColors(pressed: false)
        isAccessibilityElement = true
        accessibilityLabel = title ?? symbol
    }

    required init?(coder: NSCoder) { fatalError() }

    func setSymbol(_ name: String) {
        symbolName = name
        setImage(UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)), for: .normal)
    }

    private func applyColors(pressed: Bool) {
        let light = style == .character ? UIColor.white : UIColor(red: 0.68, green: 0.70, blue: 0.74, alpha: 1)
        let dark = style == .character ? UIColor(white: 0.42, alpha: 1) : UIColor(white: 0.27, alpha: 1)
        let pressedLight = style == .character ? UIColor(red: 0.68, green: 0.70, blue: 0.74, alpha: 1) : .white
        let pressedDark = style == .character ? UIColor(white: 0.27, alpha: 1) : UIColor(white: 0.42, alpha: 1)
        backgroundColor = UIColor { $0.userInterfaceStyle == .dark ? (pressed ? pressedDark : dark) : (pressed ? pressedLight : light) }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        downPoint = touches.first?.location(in: self) ?? .zero
        cancelled = false
        // 手感：按下去的當下就震＋出聲（在插入文字、重算候選字之前），跟系統鍵盤一樣。
        #if DEBUG
        KeyPerf.measure("feedback") { KeyFeedback.down(style == .special ? .special : .character, hasFullAccess: KeyButton.hasFullAccess) }
        KeyPerf.measure("press-visual") { applyColors(pressed: true) }
        firedOnDown = onDown != nil
        if let onDown { KeyPerf.measure("key-down-action") { onDown() } }
        #else
        KeyFeedback.down(style == .special ? .special : .character, hasFullAccess: KeyButton.hasFullAccess)
        applyColors(pressed: true)
        firedOnDown = onDown != nil
        onDown?()
        #endif
        if onHold != nil {
            holdTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.onHold?(true) }
            }
        }
    }

    /// 手指滑開 > 20pt ＝收回：立刻停長按 timer／repeat、別讓手指離開後 repeat 還在送 delete。
    /// 設 cancelled 是給 touchesEnded／Cancelled 看——它們不再做任何輸入／tap 動作。
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        guard let p = touches.first?.location(in: self) else { return }
        if hypot(p.x - downPoint.x, p.y - downPoint.y) >= 20 {
            cancelled = true
            holdTimer?.invalidate(); holdTimer = nil
            onHold?(false)
            guard firedOnDown else { return }
            firedOnDown = false
            applyColors(pressed: false)
            onUndo?()
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        applyColors(pressed: false)
        holdTimer?.invalidate(); holdTimer = nil
        onHold?(false)
        // 已經被 touchesMoved／Cancelled 收回：不再做任何事，避免「滑出去又滑回來 release」誤觸 onTap／onCommit。
        if cancelled { return }
        let endPoint = touches.first?.location(in: self)
        let offset = endPoint.map { hypot($0.x - downPoint.x, $0.y - downPoint.y) } ?? 0
        if firedOnDown {
            firedOnDown = false
            if offset < 20 {
                // 在原位放開：長按 delete 結束或普通點擊都算「確定輸入」，送 onCommit 給自動學字典等用。
                onCommit?()
            } else {
                // touchesMoved 沒拿到（系統事件掉了、或者 ended 自帶大位移）：補上 onUndo，
                // 否則 onDown 插進去的字會留在文件裡。
                onUndo?()
            }
            return
        }
        // 沒有 onDown 的鍵（Return 等）：只在原位 release 才算 tap。
        guard offset < 20 else { return }
        #if DEBUG
        KeyPerf.measure("key-action") { onTap?() }
        #else
        onTap?()
        #endif
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        applyColors(pressed: false)
        holdTimer?.invalidate(); holdTimer = nil
        onHold?(false)
        cancelled = true
        if firedOnDown { firedOnDown = false; onUndo?() }
    }
}

/// 右上角模式切換：光球（語音）／EN／繁（注音）／简（拼音）。玻璃膠囊，選到的那格實心。
@MainActor
final class ModeSwitchView: UIControl {
    enum Mode: Int, CaseIterable { case voice, english, zhuyin, pinyin }
    private(set) var mode: Mode = .voice
    var onChange: ((Mode) -> Void)?
    private var segments: [UIButton] = []
    private let highlight = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 16
        layer.cornerCurve = .continuous
        backgroundColor = UIColor.tertiarySystemFill
        highlight.backgroundColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.36, alpha: 1) : .white }
        highlight.layer.cornerRadius = 13
        highlight.layer.cornerCurve = .continuous
        highlight.layer.shadowColor = UIColor.black.cgColor
        highlight.layer.shadowOpacity = 0.12
        highlight.layer.shadowRadius = 2
        highlight.layer.shadowOffset = CGSize(width: 0, height: 1)
        highlight.isUserInteractionEnabled = false
        addSubview(highlight)
        for m in Mode.allCases {
            let b = UIButton(type: .custom)
            b.tag = m.rawValue
            switch m {
            case .voice:
                // 小光球：語音的識別符號（不用麥克風）。
                let dot = CAGradientLayer()
                dot.type = .radial
                dot.colors = [UIColor(red: 1.0, green: 0.84, blue: 0.55, alpha: 1).cgColor, UIColor(red: 0.98, green: 0.45, blue: 0.09, alpha: 1).cgColor]
                dot.startPoint = CGPoint(x: 0.35, y: 0.3)
                dot.endPoint = CGPoint(x: 1, y: 1)
                dot.frame = CGRect(x: 0, y: 0, width: 14, height: 14)
                dot.cornerRadius = 7
                b.layer.addSublayer(dot)
                b.accessibilityLabel = String(localized: "語音")
            case .english:
                b.setTitle("EN", for: .normal)
                b.accessibilityLabel = String(localized: "英文鍵盤")
            case .zhuyin:
                // 「繁」「简」標的是文字系統，兩種介面語言都一樣，刻意不在地化。
                b.setTitle("繁", for: .normal)
                b.accessibilityLabel = String(localized: "注音鍵盤")
            case .pinyin:
                b.setTitle("简", for: .normal)
                b.accessibilityLabel = String(localized: "拼音鍵盤")
            }
            b.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
            b.setTitleColor(.secondaryLabel, for: .normal)
            b.addAction(UIAction { _ in KeyFeedback.down(.special, hasFullAccess: KeyButton.hasFullAccess) }, for: .touchDown)
            b.addTarget(self, action: #selector(tapped(_:)), for: .touchUpInside)
            addSubview(b)
            segments.append(b)
        }
        accessibilityIdentifier = "utuvoModeSwitch"
        // 三格各自是按鈕（容器本身不是元素），VoiceOver 與 UI 測試都找得到。
        isAccessibilityElement = false
        segments.forEach { $0.isAccessibilityElement = true }
        accessibilityElements = segments
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize { CGSize(width: 168, height: 32) }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width / CGFloat(segments.count)
        for (i, b) in segments.enumerated() {
            b.frame = CGRect(x: CGFloat(i) * w, y: 0, width: w, height: bounds.height)
            if let dot = b.layer.sublayers?.first(where: { $0 is CAGradientLayer }) {
                dot.position = CGPoint(x: w / 2, y: bounds.height / 2)
            }
        }
        highlight.frame = CGRect(x: CGFloat(mode.rawValue) * w + 3, y: 3, width: w - 6, height: bounds.height - 6)
    }

    func select(_ m: Mode, animated: Bool) {
        mode = m
        for b in segments {
            b.setTitleColor(b.tag == m.rawValue ? .label : .secondaryLabel, for: .normal)
            b.accessibilityTraits = b.tag == m.rawValue ? [.button, .selected] : .button
        }
        UIView.animate(withDuration: animated ? 0.22 : 0, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0) {
            self.setNeedsLayout(); self.layoutIfNeeded()
        }
    }

    @objc private func tapped(_ sender: UIButton) {
        guard let m = Mode(rawValue: sender.tag), m != mode else { return }
        select(m, animated: true)
        onChange?(m)
    }
}

/// 選字列：組字時第一格是整串的最佳轉換（點了全部送出），後面是從句首開始的候選。
/// 沒在組字時也拿來放建議（`show(suggestions:)`）：中文選字後的聯想詞、英文的補完／拼字建議。
@MainActor
final class CandidateBarView: UIView {
    var onPick: ((Int) -> Void)?       // -1＝整串
    /// 右端「⌄」：展開整頁候選字（09-29 Micky：拼音只看得到一排、沒辦法往下選）。
    var onExpand: (() -> Void)?
    /// 跟 ImeSession.keyboardCandidateLimit 對齊：列可以左右捲，看不到的格子不佔版面。
    private static let visibleCandidateLimit = 20
    private struct Item: Equatable {
        let text: String
        let index: Int
        let lead: Bool
    }
    private let scroll = CandidateScrollView()
    private let stack = UIStackView()
    private let leadFont = UIFont.systemFont(ofSize: 19, weight: .semibold)
    private let candidateFont = UIFont.systemFont(ofSize: 20, weight: .regular)
    private var lastItems: [Item] = []
    private let expandButton = UIButton(type: .system)
    private var scrollToEdge: NSLayoutConstraint!
    private var scrollToExpand: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        // iOS 26 起捲動視圖邊緣預設會模糊；候選列只有 40 pt 高，整條字都被糊掉（模擬器截圖實證）。
        if #available(iOS 26.0, *) {
            for edge in [scroll.topEdgeEffect, scroll.bottomEdgeEffect, scroll.leftEdgeEffect, scroll.rightEdgeEffect] {
                edge.isHidden = true
            }
        }
        addSubview(scroll)
        stack.axis = .horizontal
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        expandButton.translatesAutoresizingMaskIntoConstraints = false
        expandButton.tintColor = .secondaryLabel
        expandButton.isHidden = true
        expandButton.addAction(UIAction { [weak self] _ in self?.onExpand?() }, for: .touchUpInside)
        addSubview(expandButton)
        setExpanded(false)
        scrollToEdge = scroll.trailingAnchor.constraint(equalTo: trailingAnchor)
        scrollToExpand = scroll.trailingAnchor.constraint(equalTo: expandButton.leadingAnchor)
        NSLayoutConstraint.activate([
            scrollToEdge,
            expandButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            expandButton.topAnchor.constraint(equalTo: topAnchor),
            expandButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            expandButton.widthAnchor.constraint(equalToConstant: 34),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// preedit：整串轉換（含還沒打完的注音）；candidates：句首候選。
    /// 每按一鍵都會叫：重用既有的格子只換字，不要每次都拆掉重建（2026-09-20：打字頓頓的）。
    func show(preedit: String, candidates: [String]) {
        setExpandable(!preedit.isEmpty && !candidates.isEmpty)
        guard !preedit.isEmpty else {
            guard !lastItems.isEmpty else { return }
            lastItems.removeAll(keepingCapacity: true)
            if scroll.contentOffset != .zero { scroll.contentOffset = .zero }
            for view in stack.arrangedSubviews { view.isHidden = true }
            return
        }
        var wanted: [Item] = [Item(text: preedit, index: -1, lead: true)]
        wanted.reserveCapacity(Self.visibleCandidateLimit + 1)
        for (i, c) in candidates.prefix(Self.visibleCandidateLimit).enumerated() where c != preedit {
            wanted.append(Item(text: c, index: i, lead: false))
        }
        apply(wanted)
    }

    /// 沒有組字時的建議（聯想詞、英文補完）：沒有「整串」那一格，點第 i 格回 `onPick(i)`。空陣列＝收起來。
    func show(suggestions: [String]) {
        setExpandable(false)
        apply(suggestions.prefix(Self.visibleCandidateLimit).enumerated().map { Item(text: $1, index: $0, lead: false) })
    }

    private func setExpandable(_ on: Bool) {
        guard expandButton.isHidden == on else { return }
        expandButton.isHidden = !on
        scrollToEdge.isActive = !on
        scrollToExpand.isActive = on
    }

    /// 展開中顯示「⌃」（點了收起），收起時顯示「⌄」。
    func setExpanded(_ on: Bool) {
        let config = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        expandButton.setImage(UIImage(systemName: on ? "chevron.up" : "chevron.down", withConfiguration: config), for: .normal)
        expandButton.accessibilityLabel = on ? String(localized: "收起候選字") : String(localized: "更多候選字")
    }

    private func apply(_ wanted: [Item]) {
        guard wanted != lastItems else { return }
        lastItems = wanted
        if scroll.contentOffset != .zero { scroll.contentOffset = .zero }
        while stack.arrangedSubviews.count < wanted.count {
            stack.addArrangedSubview(cell("", index: 0, lead: false))
        }
        for (position, view) in stack.arrangedSubviews.enumerated() {
            guard let button = view as? UIButton else { continue }
            if position < wanted.count {
                let item = wanted[position]
                button.isHidden = false
                button.tag = item.index
                if button.title(for: .normal) != item.text { button.setTitle(item.text, for: .normal) }
                button.titleLabel?.font = item.lead ? leadFont : candidateFont
                button.setTitleColor(item.lead ? KeyboardViewController.brandOrange : .label, for: .normal)
            } else {
                button.isHidden = true
            }
        }
    }

    /// 重用的格子：`tag` 會被 show(...) 改掉，所以動作要讀當下的 tag，不能抓建立時的 index。
    private func cell(_ text: String, index: Int, lead: Bool) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(text, for: .normal)
        b.titleLabel?.font = lead ? leadFont : candidateFont
        b.setTitleColor(lead ? KeyboardViewController.brandOrange : .label, for: .normal)
        b.contentEdgeInsets = UIEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        b.tag = index
        // 選字也要有手感（按下就震，跟按鍵一致）。
        b.addAction(UIAction { _ in KeyFeedback.down(.pick, hasFullAccess: KeyButton.hasFullAccess) }, for: .touchDown)
        b.addAction(UIAction { [weak self, weak b] _ in
            guard let b else { return }
            self?.onPick?(b.tag)
        }, for: .touchUpInside)
        return b
    }
}

/// 展開的整頁候選字（蓋在按鍵上，跟系統鍵盤的「⌄」一樣）：依字寬換行排列、可以上下捲。
@MainActor
final class CandidatePanelView: UIView {
    var onPick: ((Int) -> Void)?
    private let scroll = CandidateScrollView()
    private var buttons: [UIButton] = []
    private let font = UIFont.systemFont(ofSize: 22, weight: .regular)
    private static let rowHeight: CGFloat = 46
    private static let gap: CGFloat = 6

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground
        scroll.alwaysBounceVertical = true
        scroll.accessibilityIdentifier = "candidatePanel"
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ items: [String]) {
        while buttons.count < items.count {
            let b = UIButton(type: .system)
            b.titleLabel?.font = font
            b.setTitleColor(.label, for: .normal)
            b.backgroundColor = .systemBackground
            b.layer.cornerRadius = 8
            b.addAction(UIAction { _ in KeyFeedback.down(.pick, hasFullAccess: KeyButton.hasFullAccess) }, for: .touchDown)
            b.addAction(UIAction { [weak self, weak b] _ in
                guard let b else { return }
                self?.onPick?(b.tag)
            }, for: .touchUpInside)
            scroll.addSubview(b)
            buttons.append(b)
        }
        for (i, b) in buttons.enumerated() {
            b.isHidden = i >= items.count
            guard i < items.count else { continue }
            b.tag = i
            b.setTitle(items[i], for: .normal)
        }
        scroll.contentOffset = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scroll.frame = bounds
        let inset: CGFloat = 8
        var x = inset, y = inset
        let maxX = bounds.width - inset
        for b in buttons where !b.isHidden {
            let text = (b.title(for: .normal) ?? "") as NSString
            let w = min(maxX - inset, max(52, ceil(text.size(withAttributes: [.font: font]).width) + 24))
            if x > inset && x + w > maxX {
                x = inset
                y += Self.rowHeight + Self.gap
            }
            b.frame = CGRect(x: x, y: y, width: w, height: Self.rowHeight)
            x += w + Self.gap
        }
        scroll.contentSize = CGSize(width: bounds.width, height: y + Self.rowHeight + inset)
    }
}

/// 候選列／整頁候選的捲動視圖：裡面整片都是按鈕，手指一定是從某個候選字上開始滑。
/// UIScrollView 預設不會從 UIControl 手上搶回觸控（touchesShouldCancel 對按鈕回 false），
/// 手指先停一下再滑就變成「按住那個字」、整條列捲不動（09-29 Micky：拼音沒辦法往下選字，UI 測試量到位置完全沒動）。
final class CandidateScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool { true }
}

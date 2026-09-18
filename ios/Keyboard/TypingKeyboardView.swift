import UIKit

/// 打字鍵盤（語音辨識不準時就地修正用）：英文 QWERTY 與注音（大千）兩種版面，外加數字／符號層。
/// 純 UIKit、不掛 SwiftUI，顧鍵盤 extension 記憶體。文字怎麼進文件由 delegate（KeyboardViewController）決定。
@MainActor
protocol TypingKeyboardDelegate: AnyObject {
    /// 英文、數字、符號鍵：直接插入。
    func typing(insert text: String)
    /// 注音符號或聲調：交給注音引擎。
    func typing(zhuyin symbol: Character)
    func typingDelete()
    func typingSpace()
    func typingReturn()
}

@MainActor
final class TypingKeyboardView: UIView, UIInputViewAudioFeedback {
    enum Layout: Equatable { case english, zhuyin }
    private enum Layer { case letters, numbers, symbols }
    private enum Shift { case off, once, locked }

    weak var delegate: TypingKeyboardDelegate?
    var layout: Layout = .english { didSet { if layout != oldValue { keyLayer = .letters; rebuild() } } }
    /// 宿主 app 的 return 鍵文案（傳送／前往／換行…）。
    var returnTitle = "換行" { didSet { returnKey?.setTitle(returnTitle, for: .normal) } }

    private var keyLayer: Layer = .letters
    private var shift: Shift = .off
    private var lastShiftTap: CFTimeInterval = 0
    private let rowsStack = UIStackView()
    private weak var returnKey: KeyButton?
    private var letterKeys: [KeyButton] = []
    private var deleteRepeat: Timer?
    private let tap = UIImpactFeedbackGenerator(style: .light)

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
                    key.onTap = { [weak self] in self?.delegate?.typing(zhuyin: ch); self?.feedback() }
                    return key
                }
                if i == 3 { keys.append(deleteKey(width: 1.0)) }
                addRow(keys, inset: 0, totalUnits: 11)
            }
        case (_, .numbers), (_, .symbols):
            let rows = layout == .zhuyin ? Self.zhuyinNumberRows : (keyLayer == .numbers ? Self.numberRows : Self.symbolRows)
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
        let layerKey = specialKey(title: keyLayer == .letters ? "123" : (layout == .zhuyin ? "注音" : "ABC"), width: 1.3) { [weak self] in
            guard let self else { return }
            self.keyLayer = self.keyLayer == .letters ? .numbers : .letters
            self.rebuild()
        }
        let space = KeyButton(title: layout == .zhuyin ? "空白" : "space", style: .character, fontSize: 15)
        space.onTap = { [weak self] in self?.delegate?.typingSpace(); self?.feedback() }
        let ret = KeyButton(title: returnTitle, style: .special, fontSize: 15)
        ret.onTap = { [weak self] in self?.delegate?.typingReturn(); self?.feedback() }
        returnKey = ret
        let row = UIStackView(arrangedSubviews: [layerKey, space, ret])
        row.spacing = 6
        row.distribution = .fill
        layerKey.widthAnchor.constraint(equalTo: row.widthAnchor, multiplier: 0.2).isActive = true
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
        key.onTap = { [weak self] in
            guard let self else { return }
            let text = self.layout == .english && self.keyLayer == .letters && self.shift != .off ? title.uppercased() : title
            self.delegate?.typing(insert: text)
            if self.shift == .once { self.setShift(.off) }
            self.feedback()
        }
        return key
    }

    private func specialKey(title: String? = nil, symbol: String? = nil, width: CGFloat, action: @escaping () -> Void) -> KeyButton {
        let key = KeyButton(title: title, symbol: symbol, style: .special, fontSize: 15)
        key.widthUnits = width
        key.onTap = { [weak self] in action(); self?.feedback() }
        return key
    }

    private func deleteKey(width: CGFloat) -> KeyButton {
        let key = KeyButton(title: nil, symbol: "delete.left", style: .special, fontSize: 17)
        key.widthUnits = width
        key.onTap = { [weak self] in self?.delegate?.typingDelete(); self?.feedback() }
        // 按住連刪。
        key.onHold = { [weak self] began in
            guard let self else { return }
            self.deleteRepeat?.invalidate()
            guard began else { return }
            self.deleteRepeat = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.delegate?.typingDelete() }
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
        shift = s
        applyShiftLabels()
    }

    private func applyShiftLabels() {
        for key in letterKeys { key.setTitle(shift == .off ? key.baseTitle : key.baseTitle.uppercased(), for: .normal) }
        let shiftKey = rowsStack.arrangedSubviews.compactMap { ($0.subviews.first as? UIStackView)?.arrangedSubviews.first as? KeyButton }
            .first { $0.symbolName?.hasPrefix("shift") == true }
        shiftKey?.setSymbol(shift == .locked ? "capslock.fill" : (shift == .once ? "shift.fill" : "shift"))
    }

    private func feedback() {
        UIDevice.current.playInputClick()
        tap.impactOccurred(intensity: 0.5)
    }
}

/// 一顆鍵：系統鍵盤的樣子（圓角、底部細陰影），手指滑開超過 20 pt 就不算按（避免左右滑切換時誤打字）。
final class KeyButton: UIButton {
    enum Style { case character, special }
    var onTap: (() -> Void)?
    var onHold: ((Bool) -> Void)?
    var widthUnits: CGFloat = 1
    let baseTitle: String
    private(set) var symbolName: String?
    private let style: Style
    private var downPoint: CGPoint = .zero
    private var holdTimer: Timer?

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
        applyColors(pressed: true)
        if onHold != nil {
            holdTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.onHold?(true) }
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        applyColors(pressed: false)
        let held = holdTimer.map { !$0.isValid } ?? false
        holdTimer?.invalidate(); holdTimer = nil
        onHold?(false)
        guard !held, let p = touches.first?.location(in: self), hypot(p.x - downPoint.x, p.y - downPoint.y) < 20 else { return }
        onTap?()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        applyColors(pressed: false)
        holdTimer?.invalidate(); holdTimer = nil
        onHold?(false)
    }
}

/// 右上角模式切換：光球（語音）／EN／繁。玻璃膠囊，選到的那格實心。
@MainActor
final class ModeSwitchView: UIControl {
    enum Mode: Int, CaseIterable { case voice, english, zhuyin }
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
                b.accessibilityLabel = "語音"
            case .english:
                b.setTitle("EN", for: .normal)
                b.accessibilityLabel = "英文鍵盤"
            case .zhuyin:
                b.setTitle("繁", for: .normal)
                b.accessibilityLabel = "注音鍵盤"
            }
            b.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
            b.setTitleColor(.secondaryLabel, for: .normal)
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

    override var intrinsicContentSize: CGSize { CGSize(width: 132, height: 32) }

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

/// 注音選字列：第一格是整串的最佳轉換（點了全部送出），後面是從句首開始的候選。
@MainActor
final class CandidateBarView: UIView {
    var onPick: ((Int) -> Void)?       // -1＝整串
    private let scroll = UIScrollView()
    private let stack = UIStackView()

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
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
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
    func show(preedit: String, candidates: [String]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        scroll.contentOffset = .zero
        guard !preedit.isEmpty else { return }
        stack.addArrangedSubview(cell(preedit, index: -1, lead: true))
        for (i, c) in candidates.enumerated() where c != preedit {
            stack.addArrangedSubview(cell(c, index: i, lead: false))
        }
    }

    private func cell(_ text: String, index: Int, lead: Bool) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(text, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: lead ? 19 : 20, weight: lead ? .semibold : .regular)
        b.setTitleColor(lead ? KeyboardViewController.brandOrange : .label, for: .normal)
        b.contentEdgeInsets = UIEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        b.tag = index
        b.addAction(UIAction { [weak self] _ in self?.onPick?(index) }, for: .touchUpInside)
        return b
    }
}

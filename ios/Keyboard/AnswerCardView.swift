import UIKit

/// Ask anything 的回答卡（鍵盤上方、可捲動）＋兩個按鈕：插入（插在游標處）、複製；關閉＝收起。
///
/// 只用純 UIKit（鍵盤 extension 記憶體上限約 60 MB，不准在這裡塞任何模型／字典）。
/// 沒有 Auto Layout 的 stack view 嵌套，內容高度自己算，捲動範圍隨答案長度變。
final class AnswerCardView: UIView {
    /// 答案內容改變時（Ask anything 的 replace 降級成回答時會換一次文字）。
    var onInsert: (() -> Void)?
    var onCopy: (() -> Void)?
    var onClose: (() -> Void)?

    private let scrollView = UIScrollView()
    private let answerLabel = UILabel()
    private let insertButton = UIButton(type: .system)
    private let copyButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    private var bottomRow: UIStackView!
    private static let bottomRowHeight: CGFloat = 34
    private static let sideInset: CGFloat = 12

    var answer: String {
        get { answerLabel.text ?? "" }
        set {
            answerLabel.text = newValue
            scrollView.contentSize = fittedContentSize()
            scrollView.setContentOffset(.zero, animated: false)
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 16
        layer.cornerCurve = .continuous
        clipsToBounds = true
        isAccessibilityElement = false
        accessibilityIdentifier = "utuvoAnswerCard"

        answerLabel.font = .systemFont(ofSize: 15)
        answerLabel.textColor = .label
        answerLabel.numberOfLines = 0
        // 必須關掉 autoresizing：捲動區內容全部用 contentLayoutGuide 的約束定位，
        // 留著 translates 會多出一套 frame 約束跟它們打架（啟動就噴 constraint conflict）。
        answerLabel.translatesAutoresizingMaskIntoConstraints = false
        answerLabel.isAccessibilityElement = true
        answerLabel.accessibilityIdentifier = "utuvoAnswerCardText"

        scrollView.showsVerticalScrollIndicator = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        scrollView.addSubview(answerLabel)

        for (button, title, identifier) in [(insertButton, String(localized: "插入"), "utuvoAnswerInsert"),
                                           (copyButton, String(localized: "複製"), "utuvoAnswerCopy")] {
            var config = UIButton.Configuration.plain()
            config.title = title
            config.cornerStyle = .capsule
            config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12)
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
                var a = attrs
                a.font = .systemFont(ofSize: 14, weight: .semibold)
                return a
            }
            button.configuration = config
            button.accessibilityIdentifier = identifier
        }
        var closeConfig = UIButton.Configuration.plain()
        closeConfig.image = UIImage(systemName: "xmark.circle.fill")
        closeConfig.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        closeConfig.baseForegroundColor = .secondaryLabel
        closeButton.configuration = closeConfig
        closeButton.accessibilityIdentifier = "utuvoAnswerClose"
        closeButton.accessibilityLabel = String(localized: "關閉回答卡")

        bottomRow = UIStackView(arrangedSubviews: [insertButton, copyButton, closeButton])
        bottomRow.axis = .horizontal
        bottomRow.spacing = 8
        bottomRow.alignment = .center
        bottomRow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bottomRow)

        insertButton.addAction(UIAction { [weak self] _ in self?.onInsert?() }, for: .touchUpInside)
        copyButton.addAction(UIAction { [weak self] _ in self?.onCopy?() }, for: .touchUpInside)
        closeButton.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.sideInset),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.sideInset),
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            scrollView.bottomAnchor.constraint(equalTo: bottomRow.topAnchor, constant: -6),

            bottomRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.sideInset),
            bottomRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.sideInset),
            bottomRow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            bottomRow.heightAnchor.constraint(equalToConstant: Self.bottomRowHeight),

            // 捲動區的內容：文字的寬度＝捲動區寬度，高度由內容決定（否則長答案不會長高、也捲不動）。
            answerLabel.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            answerLabel.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            answerLabel.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            answerLabel.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            answerLabel.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor)
        ])
        answer = ""
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 內容（捲動區＋按鈕列）真正需要多高：短答案卡片跟著縮，不留一片空白。
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let width = max(size.width, 120) - Self.sideInset * 2
        let content = fittedContentSize(forWidth: width)
        return CGSize(width: size.width, height: content.height + 10 + 6 + Self.bottomRowHeight + 8)
    }

    private func fittedContentSize(forWidth width: CGFloat? = nil) -> CGSize {
        let w = width ?? (bounds.width > 0 ? bounds.width - Self.sideInset * 2 : 240)
        let size = answerLabel.sizeThatFits(CGSize(width: w, height: .greatestFiniteMagnitude))
        return CGSize(width: w, height: max(size.height, 20))
    }
}
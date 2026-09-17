import Foundation

/// UTUVO Type — mode / model routing policy.
///
/// 這個檔案是產品對雲端／本機模型的唯一決策點。任何模式選擇、
/// fallback 鏈、plus-only 條件、短句禁大模型規則都集中在這裡。
/// 不准在 normalizer 或 formatter adapter 裡偷偷決定走哪個模型。

public enum FormatterMode: String, Sendable, Codable, CaseIterable, Equatable {
    /// 短句／選取編輯／低延遲需求；優先走本機 ASR + deterministic，
    /// 不進 27B／plus／max。
    case fast
    /// 一般口述、預設模式；走百鍊 qwen3.7-flash。
    case smart
    /// 對已選取文字做改寫；長／高品質時 opt-in plus。
    case editSelection
    /// 長文／會議紀錄／結構化輸出；opt-in plus；27B 為 adapter（不自動下載）。
    case deep
}

/// 雲端模型的標準鏈。`primary` 與 `fallback` 共同組成 fallback 鏈。
public enum BailianModel: String, Sendable, Codable, CaseIterable, Equatable {
    case flash37 = "qwen3.7-flash-2026-07-15"
    case flash37Stable = "qwen3.7-flash"
    case flash36 = "qwen3.6-flash"
    case flash35 = "qwen3.5-flash"
    case plus37 = "qwen3.7-plus"
    case max37 = "qwen3.7-max"

    /// 雲端 fallback 鏈（不含 plus／max）。
    public static let standardFallbackChain: [BailianModel] = [.flash37, .flash37Stable, .flash36, .flash35]
}

public struct RoutingInput: Sendable, Equatable {
    public var text: String
    public var mode: FormatterMode
    public var hasListCues: Bool
    public var hasSelfCorrection: Bool
    public var hasMarkdown: Bool
    public var hasSelectedBlock: Bool
    public var highQuality: Bool
    public var deepOptIn: Bool
    public var localDeepAvailable: Bool
    public var longTextOptIn: Bool

    public init(
        text: String,
        mode: FormatterMode,
        hasListCues: Bool = false,
        hasSelfCorrection: Bool = false,
        hasMarkdown: Bool = false,
        hasSelectedBlock: Bool = false,
        highQuality: Bool = false,
        deepOptIn: Bool = false,
        localDeepAvailable: Bool = false,
        longTextOptIn: Bool = false
    ) {
        self.text = text
        self.mode = mode
        self.hasListCues = hasListCues
        self.hasSelfCorrection = hasSelfCorrection
        self.hasMarkdown = hasMarkdown
        self.hasSelectedBlock = hasSelectedBlock
        self.highQuality = highQuality
        self.deepOptIn = deepOptIn
        self.localDeepAvailable = localDeepAvailable
        self.longTextOptIn = longTextOptIn
    }
}

public struct RoutingDecision: Sendable, Equatable, Codable {
    public var primaryModel: BailianModel?
    public var fallbackChain: [BailianModel]
    public var allowedLargeModel: Bool
    public var useLocalDeep: Bool
    public var skipLLM: Bool
    public var reason: String

    public init(
        primaryModel: BailianModel?,
        fallbackChain: [BailianModel],
        allowedLargeModel: Bool,
        useLocalDeep: Bool,
        skipLLM: Bool,
        reason: String
    ) {
        self.primaryModel = primaryModel
        self.fallbackChain = fallbackChain
        self.allowedLargeModel = allowedLargeModel
        self.useLocalDeep = useLocalDeep
        self.skipLLM = skipLLM
        self.reason = reason
    }
}

public enum Router: Sendable {
    /// 短句偵測：以「trim 後的可見字元數」為基準（中文一字 = 1）。
    /// 條件：≤ 12 字、無清單線索、無自修正、無 Markdown 結構。
    public static func isShortSentence(_ input: RoutingInput) -> Bool {
        let trimmed = input.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        if trimmed.count > 12 { return false }
        if input.hasListCues { return false }
        if input.hasSelfCorrection { return false }
        if input.hasMarkdown { return false }
        return true
    }

    /// 核心決策函式。任何 routing 邏輯改動都必須從這裡出發，
    /// 不准在 adapter 內重新決定模型。
    public static func decide(_ input: RoutingInput) -> RoutingDecision {
        let short = isShortSentence(input)

        switch input.mode {
        case .fast:
            // Fast 模式無論長短都只走本機 ASR + deterministic；
            // Smart 才是可選的 flash formatter 路徑。
            return RoutingDecision(
                primaryModel: nil,
                fallbackChain: [],
                allowedLargeModel: false,
                useLocalDeep: false,
                skipLLM: true,
                reason: short ? "fast-mode short-sentence: deterministic only" : "fast-mode: deterministic only"
            )

        case .smart:
            if short {
                // 短句即使在 smart 模式也不上 plus/max。
                return RoutingDecision(
                    primaryModel: .flash37,
                    fallbackChain: BailianModel.standardFallbackChain,
                    allowedLargeModel: false,
                    useLocalDeep: false,
                    skipLLM: false,
                    reason: "smart-mode short-sentence: flash only"
                )
            }
            if input.longTextOptIn {
                return RoutingDecision(
                    primaryModel: .plus37,
                    fallbackChain: BailianModel.standardFallbackChain,
                    allowedLargeModel: true,
                    useLocalDeep: false,
                    skipLLM: false,
                    reason: "smart-mode over configured long-text threshold: plus"
                )
            }
            // 長句仍以 flash 為主；plus 需 opt-in 才允許（M3 才實作）。
            return RoutingDecision(
                primaryModel: .flash37,
                fallbackChain: BailianModel.standardFallbackChain,
                allowedLargeModel: false,
                useLocalDeep: false,
                skipLLM: false,
                reason: "smart-mode long-text: flash"
            )

        case .editSelection:
            // 選取編輯：必走雲端 formatter。
            if short {
                return RoutingDecision(
                    primaryModel: .flash37,
                    fallbackChain: BailianModel.standardFallbackChain,
                    allowedLargeModel: false,
                    useLocalDeep: false,
                    skipLLM: false,
                    reason: "edit-selection short: flash only"
                )
            }
            // 長或高品質才升 plus；其他一律 flash。
            if input.highQuality || input.longTextOptIn {
                return RoutingDecision(
                    primaryModel: .plus37,
                    fallbackChain: BailianModel.standardFallbackChain,
                    allowedLargeModel: true,
                    useLocalDeep: false,
                    skipLLM: false,
                    reason: input.highQuality
                        ? "edit-selection high-quality: plus with flash fallback"
                        : "edit-selection over configured long-text threshold: plus with flash fallback"
                )
            }
            return RoutingDecision(
                primaryModel: .flash37,
                fallbackChain: BailianModel.standardFallbackChain,
                allowedLargeModel: false,
                useLocalDeep: false,
                skipLLM: false,
                reason: "edit-selection default: flash"
            )

        case .deep:
            // Deep 模式必須 opt-in 才允許；不 opt-in 退回 smart 預設。
            if !input.deepOptIn {
                return RoutingDecision(
                    primaryModel: .flash37,
                    fallbackChain: BailianModel.standardFallbackChain,
                    allowedLargeModel: false,
                    useLocalDeep: false,
                    skipLLM: false,
                    reason: "deep requested without opt-in: downgrade to smart"
                )
            }
            // 有 opt-in：選 plus；若本機 27B 可用，走本機 Deep。
            if input.localDeepAvailable {
                return RoutingDecision(
                    primaryModel: nil,
                    fallbackChain: BailianModel.standardFallbackChain,
                    allowedLargeModel: false,
                    useLocalDeep: true,
                    skipLLM: false,
                    reason: "deep opt-in with local 27B available: local Deep"
                )
            }
            return RoutingDecision(
                primaryModel: .plus37,
                fallbackChain: BailianModel.standardFallbackChain,
                allowedLargeModel: true,
                useLocalDeep: false,
                skipLLM: false,
                reason: "deep opt-in: plus with flash fallback"
            )
        }
    }
}

/// 偵測用的純函式集合：給 routing / fixtures / 測試共用。
/// 任何「這個輸入算不算 list cue」之類的判斷都集中在這裡。
public enum InputFeatures: Sendable {
    /// 「第一 / 第二 / 首先 / 接下來 / 最後」這類線索。
    public static func hasListCues(_ text: String) -> Bool {
        let patterns = [
            "第一", "第二", "第三", "第四", "第五",
            "首先", "其次", "再次",
            "接下來", "然後", "最後",
            "幫我記", "幫我列"
        ]
        for p in patterns where text.contains(p) {
            return true
        }
        return false
    }

    /// 「不是 A，是 B」「A 不對 B」這類。
    public static func hasSelfCorrection(_ text: String) -> Bool {
        if text.contains("不是") && text.contains("是") { return true }
        if text.contains("不對") { return true }
        if text.contains("改成") { return true }
        if text.contains("應該是") { return true }
        return false
    }

    /// Markdown 結構粗略偵測：標題、清單、code fence、粗體。
    public static func hasMarkdown(_ text: String) -> Bool {
        let markers = ["# ", "## ", "- ", "* ", "```", "**", "__", "~~"]
        for m in markers where text.contains(m) {
            return true
        }
        return false
    }

    /// 選取模式注入的占位區塊。
    public static func hasSelectedBlock(_ text: String) -> Bool {
        text.contains("<selected>") && text.contains("</selected>")
    }
}

import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// 打字手感（2026-09-20 Micky：「鍵盤輸入的手感不是很好，可不可以有 haptic」）。
///
/// 原本有震，但三件事讓它「鬆」：
/// 1. 震在**放開手指**時（`touchUpInside`），系統鍵盤是按下去就震；
/// 2. `UIImpactFeedbackGenerator` 沒先 `prepare()`，閒置後第一下要等 Taptic 引擎醒來；
/// 3. 震排在「插入文字→重算候選字」後面，主執行緒忙完才輪到它。
///
/// 現在：按下去立刻震（在做任何事之前）、每次按下都重新 prepare 下一次、選字列與模式切換也有。
/// ⚠️ 鍵盤 extension 要開「允許完整存取」才會震，沒開時系統靜默忽略（不會出錯，也不會有感覺）。
public enum KeyFeedback {
    /// 強度（使用者可調；關＝完全不震，聲音另外一個開關）。
    public enum Strength: String, CaseIterable, Sendable {
        case off, light, medium, strong

        public var intensity: CGFloat {
            switch self {
            case .off: return 0
            case .light: return 0.45
            case .medium: return 0.75
            case .strong: return 1.0
            }
        }
    }

    public static let strengthKey = "utuvo.type.keyboard.hapticStrength"
    public static let soundKey = "utuvo.type.keyboard.keySound"

    public static var defaults: UserDefaults { UserDefaults(suiteName: "group.com.utuvo.type") ?? .standard }

    public static var strength: Strength {
        get { Strength(rawValue: defaults.string(forKey: strengthKey) ?? "") ?? .medium }
        set { defaults.set(newValue.rawValue, forKey: strengthKey) }
    }

    /// 按鍵聲音（系統的鍵盤喀噠聲；不受「允許完整存取」限制）。
    public static var soundEnabled: Bool {
        get { defaults.object(forKey: soundKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: soundKey) }
    }

    /// 哪一種鍵用哪一種震：一般鍵輕、功能鍵（刪除、Enter、切換）重一點、連續刪除最輕。
    public enum Kind: Sendable {
        case character, special, repeatTick, pick

        public var multiplier: CGFloat {
            switch self {
            case .character: return 1.0
            case .special: return 1.15
            case .repeatTick: return 0.55
            case .pick: return 0.9
            }
        }
    }

    /// 真正會不會震：強度不是 off，而且鍵盤有完整存取權。
    public static func wantsHaptic(strength: Strength, hasFullAccess: Bool) -> Bool {
        strength != .off && hasFullAccess
    }

#if canImport(UIKit)
    @MainActor private static let light = UIImpactFeedbackGenerator(style: .light)
    @MainActor private static let rigid = UIImpactFeedbackGenerator(style: .rigid)

    /// 鍵盤出現、手指按下時都叫一次：讓 Taptic 引擎先醒著，下一下才不會慢半拍。
    @MainActor public static func prepare() {
        guard strength != .off else { return }
        light.prepare()
        rigid.prepare()
    }

    /// 按下去的當下叫（在插入文字之前）。
    @MainActor public static func down(_ kind: Kind, hasFullAccess: Bool = true) {
        if soundEnabled { UIDevice.current.playInputClick() }
        let strength = self.strength
        guard wantsHaptic(strength: strength, hasFullAccess: hasFullAccess) else { return }
        let generator = kind == .special ? rigid : light
        generator.impactOccurred(intensity: min(1.0, strength.intensity * kind.multiplier))
        generator.prepare()   // 連打時下一下才即時
    }
#endif
}

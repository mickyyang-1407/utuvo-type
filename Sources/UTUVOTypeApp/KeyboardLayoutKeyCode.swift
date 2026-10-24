import Carbon.HIToolbox
import Foundation

/// delivery-learning-6（2026-10-22）：⌘V 要按「目前鍵盤配置上印著 V 的那顆鍵」。
///
/// 以前一律送 `kVK_ANSI_V`（keycode 9）：QWERTY 沒問題，但 Dvorak 的 keycode 9 是「.」、
/// 有些配置（Dvorak－QWERTY ⌘ 除外）按 ⌘ 時照配置解讀，⌘V 就變成 ⌘. ——貼不上還可能觸發「取消」。
/// 做法：用 UCKeyTranslate 問「按著 ⌘ 時哪顆鍵打出 v」；QWERTY 第一個就中（keycode 9），其他配置找一輪 0..<128，
/// 都找不到就退回 9（跟以前一樣）。
enum KeyboardLayoutKeyCode {
    static let ansiV = CGKeyCode(kVK_ANSI_V)

    /// 純函式：`translate(keyCode)` 回傳那顆鍵在按著 ⌘ 時打出的字（小寫比對）；找不到 `character` 就回 ANSI V。
    static func resolve(character: Character, translate: (CGKeyCode) -> String?) -> CGKeyCode {
        let wanted = String(character).lowercased()
        if translate(ansiV)?.lowercased() == wanted { return ansiV }
        for code in 0..<CGKeyCode(128) where code != ansiV {
            if translate(code)?.lowercased() == wanted { return code }
        }
        return ansiV
    }

    /// 目前輸入來源上「⌘V」該按的 keycode。
    static func commandV() -> CGKeyCode {
        guard let layout = currentLayoutData() else { return ansiV }
        return resolve(character: "v") { code in translate(code, layout: layout, modifiers: UInt32(cmdKey >> 8)) }
    }

    private static func currentLayoutData() -> Data? {
        for source in [TISCopyCurrentKeyboardLayoutInputSource(), TISCopyCurrentASCIICapableKeyboardLayoutInputSource()] {
            guard let input = source?.takeRetainedValue(),
                  let pointer = TISGetInputSourceProperty(input, kTISPropertyUnicodeKeyLayoutData) else { continue }
            let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
            if !data.isEmpty { return data }
        }
        return nil
    }

    private static func translate(_ code: CGKeyCode, layout: Data, modifiers: UInt32) -> String? {
        layout.withUnsafeBytes { raw -> String? in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeys: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(base, UInt16(code), UInt16(kUCKeyActionDown), modifiers,
                                        UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                        &deadKeys, chars.count, &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
    }
}

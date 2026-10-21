import Foundation

/// `TraditionalFixer.fix(tokens:)` 的參數型別；iOS 本體在 ios/Shared/Punctuation.swift（Mac 不編那支，只要這個型別）。
struct TimedToken: Equatable, Sendable {
    let text: String
    let start: TimeInterval
    let duration: TimeInterval
}

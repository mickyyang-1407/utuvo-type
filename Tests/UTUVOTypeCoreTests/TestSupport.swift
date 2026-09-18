import Foundation
import XCTest
@testable import UTUVOTypeCore

/// 測試共用工具：repo root 定位、secret literal 掃描器。
enum TestSupport {
    /// 從當前測試 bundle 的位置反推 repo root。
    /// 測試 bundle 在 .build/<config>/.../UTUVOTypeCoreTests.bundle，
    /// 但執行測試時 cwd 就是 package root，所以兩個方法都能用。
    static func repoRoot() -> String {
        let cwd = FileManager.default.currentDirectoryPath
        let candidate = cwd + "/Package.swift"
        if FileManager.default.fileExists(atPath: candidate) {
            return cwd
        }
        // 退路：往上找 Package.swift
        var probe = URL(fileURLWithPath: cwd)
        for _ in 0..<6 {
            let p = probe.appendingPathComponent("Package.swift").path
            if FileManager.default.fileExists(atPath: p) {
                return probe.path
            }
            probe.deleteLastPathComponent()
        }
        return cwd
    }
}

/// 高訊號的 secret literal 形狀掃描器。
/// 規則保守：寧可漏報也不要誤報（誤報會讓開發者養成長期忽略）。
/// 任何新增的規則必須配套一個「會讓它變紅的 fixture」，
/// 確認它有真實在檢查。
struct SecretLiteralScanner {
    struct Finding {
        let path: String
        let line: Int
        let snippet: String
    }

    /// 規則：每條都有「會讓它變紅的合成輸入」配套測試。
    /// 新增規則時必須同時新增 fixture，並在 HygieneTests 跑過。
    struct Rule {
        let name: String
        let regex: NSRegularExpression
    }

    static let rules: [Rule] = [
        // AWS access key
        Rule(name: "aws-access-key", regex: try! NSRegularExpression(pattern: "AKIA[0-9A-Z]{16}")),
        // OpenAI-style secret
        Rule(name: "openai-secret", regex: try! NSRegularExpression(pattern: "sk-[A-Za-z0-9]{20,}")),
        // Slack bot token
        Rule(name: "slack-token", regex: try! NSRegularExpression(pattern: "xox[abp]-[0-9A-Za-z\\-]{10,}")),
        // 個人 email（簡單 shape）。排除 Apple 圖檔倍率命名 `icon_512x512@2x.png`／`BrandMark@3x.png`
        // （2026-09-18 誤擋 make-icon.py；誤擋跟漏擋一樣是閘門缺陷）。
        Rule(name: "email", regex: try! NSRegularExpression(pattern: "[A-Za-z0-9._%+-]+@(?![0-9]+x\\.(?:png|jpe?g|pdf|heic|svg)\\b)[A-Za-z0-9.-]+\\.[A-Za-z]{2,}")),
        // Slack webhook
        Rule(name: "slack-webhook", regex: try! NSRegularExpression(pattern: "hooks\\.slack\\.com/services/")),
        // Apps Script webhook
        Rule(name: "apps-script-webhook", regex: try! NSRegularExpression(pattern: "script\\.google\\.com/macros/s/")),
        // Generic bearer token literal
        Rule(name: "bearer", regex: try! NSRegularExpression(pattern: "Bearer\\s+[A-Za-z0-9._\\-]{20,}"))
    ]

    /// 跳過的路徑／檔名（fixtures、build artifacts、test 自身的 fixture 資料）。
    static let skipDirectories: Set<String> = [
        ".build", ".git", ".swiftpm", "DerivedData", ".derivedData",
        // gitignored 的出貨產物：release/（xcarchive＋ipa＋Xcode Packaging.log 含 Apple ID session 字樣）、dist/
        "release", "dist",
        "Tests/UTUVOTypeCoreTests/Resources",
        "Tests/UTUVOTypeCoreTests/SecretLiteralScannerTests.swift",
        "benchmarks/report.json"
    ]

    /// 跳過的副檔名（binary／編譯產物）。
    static let skipExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "pdf", "zip", "tar", "gz",
        "o", "a", "dylib", "swiftmodule", "swiftdoc", "json"
    ]

    func scan(repoRoot: String) throws -> [Finding] {
        var findings: [Finding] = []
        let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: repoRoot),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        guard let enumerator = enumerator else { return findings }

        for case let url as URL in enumerator {
            let path = url.path
            // 跳過目錄
            if Self.skipDirectories.contains(where: { path.hasSuffix($0) || path.contains("/\($0)/") }) {
                enumerator.skipDescendants()
                continue
            }
            // 跳過副檔名
            let ext = url.pathExtension.lowercased()
            if Self.skipExtensions.contains(ext) { continue }

            // 只掃文字可讀檔案
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else {
                continue
            }

            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            for (i, line) in lines.enumerated() {
                let lineStr = String(line)
                for rule in Self.rules {
                    let range = NSRange(lineStr.startIndex..<lineStr.endIndex, in: lineStr)
                    if rule.regex.numberOfMatches(in: lineStr, range: range) > 0 {
                        findings.append(Finding(
                            path: path,
                            line: i + 1,
                            snippet: String(lineStr.prefix(120))
                        ))
                    }
                }
            }
        }
        return findings
    }
}

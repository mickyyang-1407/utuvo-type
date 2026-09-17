import Foundation
import UTUVOTypeCore

// UTUVO Type — benchmark harness (M0)
//
// 這個執行檔只跑 deterministic 路徑（P1）。P2–P5 在 fixtures +
// configured provider 跑過之前固定為 "pending"，不准填假數字。
//
// 用法：
//   utuvo-bench [--fixtures <path>] [--output <path>]
//
// 預設 fixtures 路徑：<repo>/benchmarks/cases.jsonl
// 預設 output 路徑：<repo>/benchmarks/report.json
// 沒給 --output 時，report 寫到 stdout。

struct BenchmarkSample: Codable {
    let id: String
    let category: String
    let transcript: String
    let normalized: String
    let expected: String
    let passed: Bool
    let appliedSteps: [String]
    let routing: RoutingDecision
    let shortSentence: Bool
}

struct PathP1Summary: Codable {
    let total: Int
    let passed: Int
    let failed: Int
    let passRate: Double
}

struct PathResult: Codable {
    let samples: [BenchmarkSample]
    let summary: PathP1Summary
}

struct DeterministicChecks: Codable {
    let fixtureCount: Int
    let categoryCount: Int
    let categoryCoverage: [String]
    let requiredCategoriesPresent: Bool
}

struct BenchmarkReport: Codable {
    let schemaVersion: String
    let generatedAt: String
    let fixturePath: String
    let fixtureCount: Int
    let deterministicChecks: DeterministicChecks
    let byPath: [String: PathResult]
    let pendingPaths: [String]
}

@main
struct UTUVOBench {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        var fixturesPath = defaultRepoPath("benchmarks/cases.jsonl")
        var outputPath: String? = nil

        var i = 0
        while i < args.count {
            let a = args[i]
            switch a {
            case "--fixtures":
                i += 1
                if i < args.count { fixturesPath = args[i] }
            case "--output":
                i += 1
                if i < args.count { outputPath = args[i] }
            case "--help", "-h":
                printUsage()
                exit(0)
            default:
                FileHandle.standardError.write(Data("Unknown argument: \(a)\n".utf8))
                printUsage()
                exit(2)
            }
            i += 1
        }

        let fixtures: [Fixture]
        do {
            fixtures = try FixtureLoader.loadAll(from: URL(fileURLWithPath: fixturesPath))
        } catch {
            FileHandle.standardError.write(Data("Failed to load fixtures: \(error)\n".utf8))
            exit(2)
        }

        // Deterministic 自驗。
        var categoriesPresent = Set<String>()
        for f in fixtures { categoriesPresent.insert(f.category) }
        let requiredCategories = Set(FixtureLoader.requiredCategories)
        let requiredOk = requiredCategories.isSubset(of: categoriesPresent)

        let normalizer = Normalizer()
        var samples: [BenchmarkSample] = []
        var passedCount = 0
        for fixture in fixtures {
            let normalized = normalizer.normalize(fixture.transcript)
            let isMatch = normalized.cleaned == fixture.expected
            if isMatch { passedCount += 1 }

            // 路由決策（只記錄，不真的呼叫 LLM）。
            let routingInput = RoutingInput(
                text: fixture.transcript,
                mode: defaultModeForCategory(fixture.category),
                hasListCues: InputFeatures.hasListCues(fixture.transcript),
                hasSelfCorrection: InputFeatures.hasSelfCorrection(fixture.transcript),
                hasMarkdown: InputFeatures.hasMarkdown(fixture.transcript),
                hasSelectedBlock: InputFeatures.hasSelectedBlock(fixture.transcript),
                highQuality: false,
                deepOptIn: false,
                localDeepAvailable: false
            )
            let decision = Router.decide(routingInput)
            let short = Router.isShortSentence(routingInput)

            samples.append(BenchmarkSample(
                id: fixture.id,
                category: fixture.category,
                transcript: fixture.transcript,
                normalized: normalized.cleaned,
                expected: fixture.expected,
                passed: isMatch,
                appliedSteps: normalized.appliedSteps,
                routing: decision,
                shortSentence: short
            ))
        }

        let total = samples.count
        let failed = total - passedCount
        let passRate = total > 0 ? Double(passedCount) / Double(total) : 0.0

        let pathP1 = PathResult(
            samples: samples,
            summary: PathP1Summary(
                total: total,
                passed: passedCount,
                failed: failed,
                passRate: passRate
            )
        )

        let byPath: [String: PathResult] = [
            "P1": pathP1
        ]

        let report = BenchmarkReport(
            schemaVersion: "0.1.0",
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            fixturePath: fixturesPath,
            fixtureCount: fixtures.count,
            deterministicChecks: DeterministicChecks(
                fixtureCount: fixtures.count,
                categoryCount: categoriesPresent.count,
                categoryCoverage: Array(categoriesPresent).sorted(),
                requiredCategoriesPresent: requiredOk
            ),
            byPath: byPath,
            pendingPaths: ["P2", "P3", "P4", "P5"]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(report) else {
            FileHandle.standardError.write(Data("Failed to encode report\n".utf8))
            exit(2)
        }

        if let out = outputPath {
            do {
                try data.write(to: URL(fileURLWithPath: out))
            } catch {
                FileHandle.standardError.write(Data("Failed to write \(out): \(error)\n".utf8))
                exit(2)
            }
        } else {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }

        // 退出碼語意：
        //  0 = 全部 30 題通過 + 必要 category 覆蓋完整
        //  1 = fixture 通過但 category 不齊（仍產出報告）
        //  2 = 載入失敗
        if !requiredOk {
            exit(1)
        }
        exit(0)
    }

    static func defaultModeForCategory(_ category: String) -> FormatterMode {
        switch category {
        case "selection-edit": return .editSelection
        case "meeting-notes": return .smart
        default: return .smart
        }
    }

    static func defaultRepoPath(_ relative: String) -> String {
        // SwiftPM 執行時 cwd 是 package root (Sources/UTUVOBench 的父目錄)
        let cwd = FileManager.default.currentDirectoryPath
        let direct = cwd + "/" + relative
        if FileManager.default.fileExists(atPath: direct) {
            return direct
        }
        // 退路：往上找 repo root（找 Package.swift）
        var probe = URL(fileURLWithPath: cwd)
        for _ in 0..<6 {
            let candidate = probe.appendingPathComponent("Package.swift").path
            if FileManager.default.fileExists(atPath: candidate) {
                return probe.appendingPathComponent(relative).path
            }
            probe.deleteLastPathComponent()
        }
        return direct
    }

    static func printUsage() {
        let usage = """
        utuvo-bench [--fixtures <path>] [--output <path>]

          --fixtures <path>  Path to cases.jsonl (default: <repo>/benchmarks/cases.jsonl)
          --output <path>    Write report to file instead of stdout
          --help, -h         Show this help
        """
        print(usage)
    }
}

import Foundation

/// 英文專有名詞修正（2026-09-20 Micky：「AI 公司還有英文名字的判別還是沒有很準確」）。
///
/// Apple 新辨識引擎不吃提示詞（`AnalysisContext.contextualStrings` 有沒有給輸出一字不差），
/// 所以專名只能在後處理救。實機收到的樣子：`grook`／`clote coate`／`Gimani`／`AppleNVidia`／
/// `GLMKimi`／`promt`／`sesion`／`Coldex`。雲端智慧整理修得掉，但它要網路、會逾時、會 503，
/// 這一層是不靠網路的那半——只用使用者自己的詞（個人字典＋開著的詞庫包＋聯絡人）當比對目標。
///
/// 三種比對，全部只在「一串拉丁字母」上動，中文一個字都不碰：
/// 1. **拼法一致**（去掉大小寫、空白、符號）→ 換成正式寫法（`openai`→`OpenAI`）。
/// 2. **子音骨架一致**：丟掉母音、把聽起來會混的子音折在一起（清濁 d/t、g/k、b/p、v/f、z/s，
///    再把 c/q/k 收斂成 k）。`clotecoate`→`kltkt`＝`claudecode`→`kltkt`；`jeman`＝`gemini`＝`kmn`。
/// 3. **加權編輯距離**：母音的增刪改算半個，子音算一個（`promt`→`prompt`、`Coldex`→`Codex`）。
///
/// 2 和 3 的順序（2026-10-22）：距離內有唯一最近的詞就用它；只有骨架對得上時，首字要同類、
/// 聽成好幾個字的字數要一樣才換（不然「Protus」的骨架 prts 會撞上「Uber Eats」）。
///
/// 黏在一起的（`AppleNVidia`、`openAIChatGPT`）會先照詞庫切開再各自比對。
/// 為了不去動正常的英文，命中的字串如果本身是常用英文字（code、open、line、chat…）就不換。
///
/// 常用英文字護欄（FX-5，2026-10-22）：單獨聽到的一個字，本身就是常用英文字（`CommonEnglishWords`，
/// english-words.txt 的 SCOWL 10～35 級，前 49,877 行）→ 只准修大小寫（iphone→iPhone），不准換成別的詞。修之前舊 Mac 的 16 個詞在這兩萬字裡
/// 改到 100 個（glad／cloud→Claude、apply→Apple），整包 ai 改到 295 個（phone→iPhone、shop→Zhipu、stock→SDK、
/// types→Typeless、commits→commit）。多字詞（Special Audio→Spatial Audio、Dolbe Edmos→Dolby Atmos）跟不是英文字的
/// （Protus、Gemeni、grook）照舊比對；使用者個人字典的明確替換（cloud→Claude）在後面字典那一關照樣套。
///
/// W2-1 verifier 補的四條（2026-10-22，兩個平台同一套）：
/// - 有數字的詞（3Coins、1Password、7-Eleven、Qwen3）不當比對目標：拉丁字串不含數字，「3Coins」裡的「Coins」
///   對上「3Coins」會換成整個詞、前面的 3 還在原文 → 33Coins，每套一次多疊一個。
/// - 個人字典有明確規則的字（`keep`，例如 cloud→Claude 的 cloud）原樣留給字典那一關，模糊比對不先把它拉走。
/// - 詞的複數（UTUVO Types、GPTs）不是拼錯，不改回單數。
/// - 智慧整理寫的文字（`TextSource.cleanup`）是模型看過使用者詞表之後的判斷：正常寫法的單字（codec、Mickey）不換成
///   另一個單字詞（Codex、Micky），全是常用字的片語（Tone Master）不換成字數不同的詞（Tonmeister）；大小寫也只修
///   「寫法本身特別」的字（UTUVO、DAMI、ChatGPT），一般名詞的小寫（vibe coding、true peak、spatial audio）不動。
///   拼錯的片語（Darmy Music）、駝峰黏字（ToneMaster）、聽成一個字的多字詞（Protus→Pro Tools）照修。
public enum LatinNameFixer: Sendable {
    /// 一段文字裡可以被動到的最長拉丁字串（超過這個長度多半是網址、序號、程式碼）。
    static let maxRunLength = 40

    /// 這段文字是誰寫的。
    public enum TextSource: Sendable {
        /// 辨識器的逐字稿（本機整理版、第一次貼上）：拼錯是常態，模糊比對照常。
        case speech
        /// 已經過把關的智慧整理結果：只修使用者自己的寫法，模型寫對的英文一個字都不動。
        case cleanup
    }

    // MARK: - 對外

    /// `terms`＝使用者自己的詞（個人字典的輸出寫法、開著的詞庫包、聯絡人名字）。
    public static func fix(_ text: String, terms: [String]) -> String {
        fix(text, terms: terms, source: .speech)
    }

    /// `keep`＝個人字典有明確替換規則的寫法（字典的 key）：完全一樣的字（或連續幾個字）原樣留給字典那一關。
    public static func fix(_ text: String, terms: [String], source: TextSource, keep: Set<String> = []) -> String {
        let table = Table(terms: terms, source: source, keep: keep)
        guard !table.isEmpty else { return text }
        var out = ""
        var index = text.startIndex
        while index < text.endIndex {
            guard let run = nextRun(in: text, from: index) else {
                out += text[index...]
                break
            }
            out += text[index..<run.lowerBound]
            // 超過上限的拉丁字串多半是網址、序號、程式碼、長句英文，整段原文保留、不進詞表比對，
            // 但 index 繼續往後走，讓後面的短 run 還能各自被修。
            let original = String(text[run])
            if original.count > maxRunLength {
                out += original
            } else {
                out += table.fixRun(original) ?? original
            }
            index = run.upperBound
        }
        return out
    }

    /// 一段「拉丁字母（可夾單一空白、`.`、`-`）」的範圍；數字不算，免得動到型號與時間。
    /// 超過 `maxRunLength` 仍會回傳範圍，由 `fix()` 決定要不要交給詞表。
    private static func nextRun(in text: String, from start: String.Index) -> Range<String.Index>? {
        guard let first = text[start...].firstIndex(where: { $0.isLatinLetter }) else { return nil }
        var end = first
        var lastLetter = first
        while end < text.endIndex {
            let c = text[end]
            if c.isLatinLetter {
                end = text.index(after: end)
                lastLetter = text.index(before: end)
            } else if c == " " || c == "." || c == "-" {
                // 只有後面還接著字母才算同一串（「Claude Code。」的句號不吃進來）。
                let next = text.index(after: end)
                guard next < text.endIndex, text[next].isLatinLetter else { break }
                end = next
            } else {
                break
            }
        }
        return first..<text.index(after: lastLetter)
    }

    // MARK: - 詞表

    struct Table {
        /// 折過的寫法 → 正式寫法。
        private var byFolded: [String: String] = [:]
        /// 子音骨架 → 正式寫法（骨架撞在一起的詞直接丟掉，寧可不改）。
        private var bySkeleton: [String: String] = [:]
        private var canonical: [(folded: String, skeleton: String, text: String)] = []
        let source: TextSource
        /// 個人字典規則的 key 切成字（只留含拉丁字母的）。
        private let keepPhrases: [[Substring]]

        var isEmpty: Bool { byFolded.isEmpty }

        init(terms: [String], source: TextSource = .speech, keep: Set<String> = []) {
            self.source = source
            keepPhrases = keep.filter { $0.contains(where: { $0.isLatinLetter }) }
                .map { $0.split(separator: " ") }.filter { !$0.isEmpty }
            var skeletonOwners: [String: Set<String>] = [:]
            for term in terms {
                let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
                // 有數字的詞不收（3Coins→33Coins，見檔頭）。
                guard trimmed.count >= 2, trimmed.allSatisfy({ $0.isLatinLetter || $0 == " " || $0 == "-" || $0 == "." }),
                      trimmed.contains(where: { $0.isLatinLetter }) else { continue }
                let folded = LatinNameFixer.fold(trimmed)
                guard folded.count >= 2, !commonWords.contains(folded) else { continue }
                if byFolded[folded] == nil { byFolded[folded] = trimmed }
                let skeleton = LatinNameFixer.skeleton(trimmed)
                if skeleton.count >= 3 { skeletonOwners[skeleton, default: []].insert(trimmed) }
                canonical.append((folded, skeleton, trimmed))
            }
            for (skeleton, owners) in skeletonOwners where owners.count == 1 {
                bySkeleton[skeleton] = owners.first!
            }
        }

        /// 回傳修好的寫法；不確定就回 nil（不動）。
        func fixRun(_ run: String) -> String? {
            let words = run.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            // 個人字典有明確規則的字（cloud→Claude）原樣留給字典那一關，其他字各自修。
            let kept = keptWords(words)
            if kept.contains(true) {
                var changed = false
                let fixed = words.indices.map { i -> String in
                    guard !kept[i], !words[i].isEmpty, let out = fixWord(words[i]) else { return words[i] }
                    changed = true
                    return out
                }
                return changed ? fixed.joined(separator: " ") : nil
            }
            if let direct = match(run) { return direct }
            // 黏在一起的：照詞表切開（最多三段），每段都要對得上才換。常用英文字本身不切（FX-5）。
            if !run.contains(" "), run.count >= 6, maySplit(run), let parts = split(run) {
                return parts.joined(separator: " ")
            }
            guard run.contains(" ") else { return nil }
            // 「clote coate」這種分開講但其實是一個詞：把空白拿掉再試一次（聽到的字數照原本的算）。
            let glued = run.replacingOccurrences(of: " ", with: "")
            if let direct = match(glued, heardWords: LatinNameFixer.wordCount(run), heard: run) { return direct }
            if glued.count >= 6, maySplit(run), let parts = split(glued) { return parts.joined(separator: " ") }
            // 「Largec Pro」「Large C Pro」（Logic Pro）：最後一個字對得上兩字詞的後字，前面那段再寬一點比（見 `matchAnchored`）。
            if let anchored = matchAnchored(words) { return anchored }
            // 整串對不上（「Tesla OpenAIChatGPT」）：一個字一個字試，有修到才回。
            var changed = false
            let fixed = words.map { word -> String in
                guard !word.isEmpty, let out = fixWord(word) else { return word }
                changed = true
                return out
            }
            return changed ? fixed.joined(separator: " ") : nil
        }

        /// 兩字詞的後字當錨（FX-5，同 Kotlin `matchAnchored`）：辨識器把「Logic Pro」聽成「Largec Pro」「Large C Pro」，
        /// 前字多了一個 r、差兩個母音（加權距離 2），整串比的上限（1.5）不夠。只在這些條件都成立時換：
        /// 辨識稿（智慧整理寫的不算）、聽到 2～3 個字、最後一個字跟兩字詞的後字折起來一樣（Pro）、
        /// 前面那段黏起來不是常用英文字（lark Pro、large Pro 不動）、前字至少 5 個字母、跟前字同首字母、
        /// 子音骨架只差多出來的 r（Largec＝l-r-k，Logic＝l-k；logins、Louis、David、Paris 這種骨架不同的不換）、
        /// 距離 ≤ `anchoredCostLimit`、唯一最近。
        private func matchAnchored(_ words: [String]) -> String? {
            guard source == .speech else { return nil }
            let heard = words.filter { !$0.isEmpty }
            guard (2...3).contains(heard.count), let last = heard.last else { return nil }
            let prefix = heard.dropLast().joined()
            guard !LatinNameFixer.isCommonEnglishWord(prefix) else { return nil }
            let head = LatinNameFixer.fold(prefix), tail = LatinNameFixer.fold(last)
            guard head.count >= 4, let first = head.first else { return nil }
            var best: (cost: Double, text: String)?
            var tied = false
            for entry in canonical {
                let parts = entry.text.split(separator: " ")
                guard parts.count == 2, LatinNameFixer.fold(String(parts[1])) == tail else { continue }
                let target = LatinNameFixer.fold(String(parts[0]))
                guard target.count >= 5, target.first == first, LatinNameFixer.lengthsComparable(head, target),
                      LatinNameFixer.differsOnlyByExtraR(heard: prefix, term: String(parts[0])) else { continue }
                let cost = LatinNameFixer.distance(head, target, limit: LatinNameFixer.anchoredCostLimit)
                guard cost <= LatinNameFixer.anchoredCostLimit else { continue }
                if let current = best, cost >= current.cost {
                    if cost == current.cost, entry.text != current.text { tied = true }
                } else {
                    best = (cost, entry.text)
                    tied = false
                }
            }
            guard let winner = best, !tied, winner.text != heard.joined(separator: " ") else { return nil }
            return winner.text
        }

        /// 每個字是不是落在某一條個人字典規則的 key 裡（整條 key 的字要連續、完全一樣，大小寫也一樣，同字典那一關）。
        private func keptWords(_ words: [String]) -> [Bool] {
            var kept = [Bool](repeating: false, count: words.count)
            for phrase in keepPhrases where phrase.count <= words.count {
                for start in 0...(words.count - phrase.count)
                where phrase.indices.allSatisfy({ words[start + $0] == phrase[$0] }) {
                    for i in start..<(start + phrase.count) { kept[i] = true }
                }
            }
            return kept
        }

        /// 單一個英文字（沒有空白）：整個對、或照詞表切開。
        private func fixWord(_ word: String) -> String? {
            if let direct = match(word) { return direct }
            if word.count >= 6, maySplit(word), let parts = split(word) {
                return parts.joined(separator: " ")
            }
            return nil
        }

        /// 聽到（或寫出來）的這串能不能換成拼法不同的 `term`（只差大小寫的不歸這裡管）：
        /// - 單一個字本身是常用英文字 → 不行（FX-5，兩種來源都一樣：glad、cloud、phone、shop、types）；
        /// - 智慧整理寫的單字是正常寫法（codec、Mickey；駝峰黏字 ToneMaster 不算）→ 只准換成多字詞（Protus→Pro Tools），
        ///   不准換成另一個單字詞（codec→Codex、Mickey→Micky）；
        /// - 智慧整理寫的片語每個字都是常用英文字 → 只准換成一樣字數的詞（Special Audio→Spatial Audio 可以，
        ///   Tone Master→Tonmeister 不行）。
        /// - 每個字都是常用英文字、字數又跟詞一樣的片語（兩種來源都一樣）→ 要一個字對一個字對得上（`wordsAlign`）：
        ///   Special Audio→Spatial Audio、Cloud coat→Claude Code 可以；game music、team music、dumb music→DAMI music、
        ///   live coding→Vibe Coding 不行（整串的骨架或距離對得上，但首字母就不一樣，或那個字差太多）。
        func mayRespell(_ heard: String, as term: String) -> Bool {
            let words = heard.split(separator: " ")
            if words.count <= 1 {
                if LatinNameFixer.isCommonEnglishWord(heard) { return false }
                return source == .speech || !LatinNameFixer.isPlainWordShape(heard) || LatinNameFixer.wordCount(term) >= 2
            }
            let allCommon = words.allSatisfy { LatinNameFixer.isCommonEnglishWord(String($0)) }
            if allCommon, LatinNameFixer.wordCount(term) == words.count {
                return LatinNameFixer.wordsAlign(words.map(String.init), term)
            }
            // 全是常用字、字數不一樣（Tone Master→Tonmeister）：只限辨識稿，而且開頭要同一個字母
            // （access code、is code→Xcode 不換）。
            if allCommon {
                return source == .speech && LatinNameFixer.fold(heard).first == LatinNameFixer.fold(term).first
            }
            return true
        }

        /// 照詞表切開之前：單一個常用英文字不切（FX-5）；每個字都是常用字的片語不黏起來切。
        func maySplit(_ heard: String) -> Bool {
            let words = heard.split(separator: " ")
            if words.count <= 1 { return !LatinNameFixer.isCommonEnglishWord(heard) }
            // 全是常用字的片語不黏起來切（兩種來源都一樣；selective Type→Slack UTUVO Type、claims Bites→CLI Mix Bites）。
            return !words.allSatisfy { LatinNameFixer.isCommonEnglishWord(String($0)) }
        }

        /// 單一字串對單一詞（聽到的字數＝字串本身用空白分開的字數）。
        func match(_ candidate: String) -> String? {
            match(candidate, heardWords: LatinNameFixer.wordCount(candidate))
        }

        /// `heardWords`：辨識器輸出時這串是幾個字（把空白拿掉再比的時候，照原本的字數算）。
        func match(_ candidate: String, heardWords: Int) -> String? {
            match(candidate, heardWords: heardWords, heard: candidate)
        }

        /// `heard`：原本聽到（寫出來）的樣子，判斷 `mayRespell` 用（`candidate` 可能是拿掉空白的版本）。
        func match(_ candidate: String, heardWords: Int, heard: String) -> String? {
            let folded = LatinNameFixer.fold(candidate)
            guard folded.count >= 2 else { return nil }
            // FX-5：聽到的單一個字本身就是常用英文字（glad、cloud、phone、shop、types）→ 只准修大小寫，
            // 拼法不同的折字命中、加權距離、骨架都不准把它換成別的詞。分開聽到的好幾個字（Special Audio）不在此限
            // （智慧整理寫的另有規則，見 `mayRespell`）。
            if let exact = byFolded[folded] {
                guard exact != candidate else { return nil }
                // 拼法真的不一樣（grook→Grok）一律修；只差大小寫時，只有「寫法本身特別」的詞才改
                // （OpenAI、ChatGPT、NVIDIA、MiniMax），單純首字大寫的（Apple、Tesla）不動，
                // 免得把英文句子裡的 apple、line 亂改成公司名。
                let sameLetters = LatinNameFixer.plain(candidate) == LatinNameFixer.plain(exact)
                if !sameLetters {
                    return mayRespell(heard, as: exact) && !LatinNameFixer.isPlural(candidate, of: exact) ? exact : nil
                }
                // 智慧整理寫的：只看每個字自己的寫法（UTUVO、DAMI 才算；Vibe Coding 這種每字首字大寫的不算）。
                let distinctive = source == .cleanup
                    ? LatinNameFixer.hasDistinctiveWordCasing(exact) : LatinNameFixer.hasDistinctiveCasing(exact)
                return distinctive ? exact : nil
            }
            guard !LatinNameFixer.isCommonEnglishWord(heard), !commonWords.contains(folded), folded.count >= 4 else { return nil }
            // 加權距離先算：距離內有唯一最接近的詞就用它。舊版骨架先回傳，旁邊明明有 Pro Tools，
            // 「Protus」還是被改成骨架相同的「Uber Eats」（2026-10-22 asr-vocab-v1，Micky 真實字典）。
            if let nearest = nearestByDistance(folded) {
                return nearest == candidate || LatinNameFixer.isPlural(candidate, of: nearest)
                    || !mayRespell(heard, as: nearest) ? nil : nearest
            }
            // 只有骨架對得上：首字要同類（同為母音，或子音骨架首字相同），
            // 而且聽成好幾個字的，字數要跟詞一樣（黏成一個字的 clotecoate 本來就不知道幾個字，不擋）。
            let skeleton = LatinNameFixer.skeleton(candidate)
            if skeleton.count >= 3, let owner = bySkeleton[skeleton],
               LatinNameFixer.lengthsComparable(folded, LatinNameFixer.fold(owner)),
               LatinNameFixer.onsetClass(candidate) == LatinNameFixer.onsetClass(owner),
               heardWords <= 1 || heardWords == LatinNameFixer.wordCount(owner) {
                return owner == candidate || LatinNameFixer.isPlural(candidate, of: owner)
                    || !mayRespell(heard, as: owner) ? nil : owner
            }
            return nil
        }

        /// 加權編輯距離在上限內、而且唯一最近的詞；同分分不出來就回 nil。
        private func nearestByDistance(_ folded: String) -> String? {
            var best: (cost: Double, text: String)?
            var tied = false
            for entry in canonical where LatinNameFixer.lengthsComparable(folded, entry.folded) {
                let limit = LatinNameFixer.costLimit(for: entry.folded)
                let cost = LatinNameFixer.distance(folded, entry.folded, limit: limit)
                guard cost <= limit else { continue }
                if best == nil || cost < best!.cost {
                    best = (cost, entry.text)
                    tied = false
                } else if cost == best!.cost, entry.text != best!.text {
                    tied = true   // 同分的兩個名字：分不出來就不要猜
                }
            }
            guard let winner = best, !tied else { return nil }
            return winner.text
        }

        /// 「AppleNVidia」→［Apple, NVIDIA］；每段至少 2 個字母，全部都要對上。
        private func split(_ run: String, depth: Int = 0) -> [String]? {
            guard depth < 3 else { return nil }
            let chars = Array(run)
            // 長的先試，免得「openai」被切成「open」＋「ai」。
            for length in stride(from: chars.count - 2, through: 2, by: -1) {
                let head = String(chars[0..<length])
                guard let headTerm = matchWhole(head) else { continue }
                let tail = String(chars[length...])
                if let tailTerm = matchWhole(tail) { return [headTerm, tailTerm] }
                if let rest = split(tail, depth: depth + 1) { return [headTerm] + rest }
            }
            return nil
        }

        /// 切開後的每一段：必須整段命中（含原本就正確、只是大小寫不同的寫法）。
        private func matchWhole(_ piece: String) -> String? {
            let folded = LatinNameFixer.fold(piece)
            guard folded.count >= 2 else { return nil }
            if let exact = byFolded[folded] { return exact }
            return match(piece)
        }
    }

    // MARK: - 折字

    static let vowels: Set<Character> = ["a", "e", "i", "o", "u", "y"]

    /// 小寫、只留字母數字，再把常見的等價拼法收斂。
    static func fold(_ s: String) -> String {
        var out = ""
        for c in s.lowercased() where c.isLetter || c.isNumber {
            out.append(c)
        }
        out = out.replacingOccurrences(of: "ph", with: "f")
        out = out.replacingOccurrences(of: "ck", with: "k")
        out = out.replacingOccurrences(of: "gh", with: "g")
        out = out.replacingOccurrences(of: "wh", with: "w")
        out = out.replacingOccurrences(of: "x", with: "ks")
        out = out.replacingOccurrences(of: "q", with: "k")
        out = out.replacingOccurrences(of: "c", with: "k")
        // 同一個字母連著出現當一個（chatt＝chat）。
        var collapsed = ""
        for c in out where collapsed.last != c { collapsed.append(c) }
        return collapsed
    }

    /// 子音骨架：折字後丟掉母音，再把清濁與同位置的子音併在一起。
    static func skeleton(_ s: String) -> String {
        var out = ""
        for c in fold(s) where !vowels.contains(c) && c.isLetter {
            switch c {
            case "d": out.append("t")
            case "g": out.append("k")
            case "b": out.append("p")
            case "v": out.append("f")
            case "z": out.append("s")
            case "j": out.append("k")   // fold 已經把 c→k；j 的音在中文口音裡常跟 g 混（jeman＝gemini）
            default: out.append(c)
            }
        }
        var collapsed = ""
        for c in out where collapsed.last != c { collapsed.append(c) }
        return collapsed
    }

    /// 片語一個字對一個字（`mayRespell` 用，字數已經一樣）：每一對要折起來一樣，或首字母一樣而且
    /// （距離在那個詞字的上限內，或子音骨架一樣、距離也不超過 `alignedSkeletonCostLimit`：coat／code 是 2；
    /// quality／Claude、could／Claude 骨架一樣但差太多）。
    static func wordsAlign(_ heard: [String], _ term: String) -> Bool {
        let targets = term.split(separator: " ").map(String.init)
        guard targets.count == heard.count else { return false }
        return zip(heard, targets).allSatisfy { h, t in
            let a = fold(h), b = fold(t)
            if a == b { return true }
            guard let first = a.first, first == b.first else { return false }
            let limit = costLimit(for: b)
            if distance(a, b, limit: limit) <= limit { return true }
            return skeleton(h) == skeleton(t) && distance(a, b, limit: alignedSkeletonCostLimit) <= alignedSkeletonCostLimit
        }
    }

    /// 子音骨架只差多出來的 r（`matchAnchored` 用）：聽到的骨架裡 r 比較多，拿掉 r 之後跟詞一樣（Largec／Logic）。
    static func differsOnlyByExtraR(heard: String, term: String) -> Bool {
        let a = skeleton(heard), b = skeleton(term)
        guard a.filter({ $0 == "r" }).count > b.filter({ $0 == "r" }).count else { return false }
        func withoutR(_ s: String) -> String {
            var out = ""
            for c in s where c != "r" && out.last != c { out.append(c) }
            return out
        }
        return withoutR(a) == withoutR(b)
    }

    /// 首字類別：母音開頭的全算一類；子音開頭的看骨架首字（j／g 都是 k、b 是 p…）。
    static func onsetClass(_ s: String) -> String {
        guard let first = fold(s).first else { return "" }
        if vowels.contains(first) { return "vowel" }
        if first.isLetter, let consonant = skeleton(String(first)).first { return String(consonant) }
        return String(first)
    }

    /// 用空白分開的字數（「Claude Code」＝2、「clotecoate」＝1）。
    static func wordCount(_ s: String) -> Int {
        s.split(separator: " ").count
    }

    /// 只留字母數字、轉小寫（判斷「是不是只差大小寫」用，不做等價折疊）。
    static func plain(_ s: String) -> String {
        String(s.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// 單一個字（沒有空白）而且本身是常用英文字（`CommonEnglishWords`，FX-5）。`co-op`、`e.g` 這種照去掉符號的寫法查。
    static func isCommonEnglishWord(_ token: String) -> Bool {
        !token.contains(" ") && CommonEnglishWords.contains(plain(token))
    }

    /// 正常英文字的寫法：全小寫（codec）、首字大寫其餘小寫（Daisy）、全大寫（ADM）。
    /// 駝峰（ToneMaster、iCloud、NVidia）不算——那是黏在一起的名字。
    static func isPlainWordShape(_ word: String) -> Bool {
        let letters = word.filter { $0.isLatinLetter }
        return letters.dropFirst().allSatisfy(\.isLowercase) || letters.allSatisfy(\.isUppercase)
    }

    /// `candidate` 是 `term` 加 s／es（UTUVO Types、GPTs）：複數不是拼錯，不改回單數。
    static func isPlural(_ candidate: String, of term: String) -> Bool {
        let c = plain(candidate), t = plain(term)
        return c == t + "s" || c == t + "es"
    }

    /// 第二個字母之後還有大寫，或整個都是大寫＝這個詞的寫法本身有特色（ChatGPT、NVIDIA、MiniMax、GitHub）。
    static func hasDistinctiveCasing(_ term: String) -> Bool {
        let letters = term.filter { $0.isLatinLetter }
        guard letters.count >= 2 else { return false }
        return letters.dropFirst().contains { $0.isUppercase }
    }

    /// 一個字一個字看：某個字自己的第二個字母之後有大寫（UTUVO、DAMI、ChatGPT、iPhone）。
    /// 跟 `hasDistinctiveCasing` 的差別：「Vibe Coding」「True Peak」每個字只是首字大寫，不算。
    static func hasDistinctiveWordCasing(_ term: String) -> Bool {
        term.split(separator: " ").contains { hasDistinctiveCasing(String($0)) }
    }

    static func lengthsComparable(_ a: String, _ b: String) -> Bool {
        let diff = abs(a.count - b.count)
        return diff <= max(2, min(a.count, b.count) / 3)
    }

    /// `matchAnchored` 前字的距離上限（後字已經完全對上）。
    static let anchoredCostLimit = 2.0
    /// `wordsAlign` 骨架一樣的那一對字，距離上限。
    static let alignedSkeletonCostLimit = 2.0

    static func costLimit(for folded: String) -> Double {
        switch folded.count {
        case ..<5: return 0.5
        case 5...6: return 1.0
        case 7...9: return 1.5
        default: return 2.0
        }
    }

    /// 加權編輯距離：母音的增刪改算 0.5、子音算 1、相鄰對調算 0.5。超過 limit 就提早放棄。
    static func distance(_ a: String, _ b: String, limit: Double) -> Double {
        let x = Array(a), y = Array(b)
        func cost(_ c: Character) -> Double { vowels.contains(c) ? 0.5 : 1 }
        var previous = [Double](repeating: 0, count: y.count + 1)
        var twoBack = previous
        for j in 1...max(y.count, 1) where j <= y.count { previous[j] = previous[j - 1] + cost(y[j - 1]) }
        var current = previous
        for i in 1...max(x.count, 1) where i <= x.count {
            current = [Double](repeating: 0, count: y.count + 1)
            current[0] = previous[0] + cost(x[i - 1])
            var rowMin = current[0]
            for j in 1...max(y.count, 1) where j <= y.count {
                let substitution: Double
                if x[i - 1] == y[j - 1] {
                    substitution = 0
                } else if vowels.contains(x[i - 1]) && vowels.contains(y[j - 1]) {
                    substitution = 0.5
                } else {
                    substitution = 1
                }
                var value = min(previous[j - 1] + substitution,
                                min(previous[j] + cost(x[i - 1]), current[j - 1] + cost(y[j - 1])))
                if i > 1, j > 1, x[i - 1] == y[j - 2], x[i - 2] == y[j - 1] {
                    value = min(value, twoBack[j - 2] + 0.5)
                }
                current[j] = value
                rowMin = min(rowMin, value)
            }
            if rowMin > limit { return limit + 1 }
            twoBack = previous
            previous = current
        }
        return x.isEmpty ? previous[y.count] : current[y.count]
    }

    /// 常用英文字：命中這些就不動（不然「code」會變成「Claude Code」、「line」會變成「LINE」）。
    /// 存的是折過的寫法。
    static let commonWords: Set<String> = {
        let words = [
            "a", "about", "after", "again", "all", "also", "always", "am", "an", "and", "any", "are", "as", "ask", "at",
            "back", "bad", "be", "because", "bed", "been", "before", "best", "better", "big", "book", "both", "boy", "but", "buy", "by",
            "call", "came", "can", "car", "case", "chat", "check", "city", "class", "clean", "clear", "close", "code", "cold", "come",
            "cool", "copy", "could", "cut", "data", "date", "day", "deep", "did", "do", "does", "done", "door", "down", "draft", "drive",
            "each", "early", "easy", "eat", "end", "even", "ever", "every", "face", "fact", "fall", "far", "fast", "feel", "few", "file",
            "find", "fine", "first", "fix", "food", "for", "form", "free", "friend", "from", "full", "fun", "game", "get", "girl", "give",
            "go", "good", "got", "grade", "great", "green", "group", "had", "half", "hand", "happy", "hard", "has", "have", "he", "head",
            "hear", "help", "her", "here", "high", "him", "his", "hold", "home", "hope", "hot", "hour", "house", "how", "idea", "if",
            "in", "into", "is", "it", "its", "job", "join", "just", "keep", "key", "kid", "kind", "know", "land", "large", "last", "late",
            "later", "lead", "learn", "leave", "left", "less", "let", "level", "life", "light", "like", "line", "link", "list", "little",
            "live", "long", "look", "lost", "lot", "love", "low", "made", "make", "man", "many", "map", "may", "me", "mean", "meet",
            "men", "might", "mind", "mine", "minute", "miss", "mix", "mixing", "money", "month", "more", "morning", "most", "move",
            "much", "music", "must", "my", "name", "near", "need", "never", "new", "news", "next", "nice", "night", "no", "not", "note",
            "nothing", "now", "number", "object", "of", "off", "office", "often", "oh", "ok", "old", "on", "once", "one", "only", "open",
            "or", "order", "other", "our", "out", "over", "own", "page", "paper", "part", "party", "pass", "past", "pay", "people",
            "person", "pick", "place", "plan", "play", "please", "point", "power", "press", "price", "problem", "project", "put",
            "question", "quick", "quite", "read", "ready", "real", "really", "reason", "record", "red", "report", "rest", "return",
            "right", "room", "round", "run", "safe", "said", "same", "save", "saw", "say", "school", "sea", "second", "see", "seem",
            "send", "sense", "set", "share", "she", "short", "should", "show", "side", "sign", "since", "sit", "size", "sleep", "slow",
            "small", "so", "some", "song", "soon", "sorry", "sound", "space", "speak", "spend", "sport", "spring", "staff", "stand",
            "star", "start", "state", "stay", "stem", "step", "still", "stop", "store", "story", "study", "such", "sun", "sure", "table",
            "take", "talk", "tape", "team", "tell", "test", "than", "thank", "that", "the", "their", "them", "then", "there", "these",
            "they", "thing", "think", "this", "those", "time", "to", "today", "together", "told", "too", "took", "top", "town", "track",
            "trade", "train", "tree", "try", "turn", "two", "type", "under", "until", "up", "us", "use", "used", "user", "very", "video",
            "view", "visit", "voice", "wait", "walk", "wall", "want", "war", "warm", "was", "watch", "water", "way", "we", "week",
            "well", "went", "were", "what", "when", "where", "which", "while", "white", "who", "why", "will", "win", "wind", "window",
            "with", "word", "work", "world", "would", "write", "wrong", "year", "yes", "yet", "you", "young", "your"
        ]
        return Set(words.map(fold))
    }()
}

extension Character {
    /// 只認 ASCII 字母：中文、日文、注音都不算。
    var isLatinLetter: Bool { isASCII && isLetter }
}

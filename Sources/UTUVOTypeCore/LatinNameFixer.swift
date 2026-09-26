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
/// 黏在一起的（`AppleNVidia`、`openAIChatGPT`）會先照詞庫切開再各自比對。
/// 為了不去動正常的英文，命中的字串如果本身是常用英文字（code、open、line、chat…）就不換。
public enum LatinNameFixer: Sendable {
    /// 一段文字裡可以被動到的最長拉丁字串（超過這個長度多半是網址、序號、程式碼）。
    static let maxRunLength = 40

    // MARK: - 對外

    /// `terms`＝使用者自己的詞（個人字典的輸出寫法、開著的詞庫包、聯絡人名字）。
    public static func fix(_ text: String, terms: [String]) -> String {
        let table = Table(terms: terms)
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

        var isEmpty: Bool { byFolded.isEmpty }

        init(terms: [String]) {
            var skeletonOwners: [String: Set<String>] = [:]
            for term in terms {
                let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.count >= 2, trimmed.allSatisfy({ $0.isLatinLetter || $0 == " " || $0 == "-" || $0 == "." || $0.isNumber }),
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
            if let direct = match(run) { return direct }
            // 黏在一起的：照詞表切開（最多三段），每段都要對得上才換。
            if !run.contains(" "), run.count >= 6, let parts = split(run) { return parts.joined(separator: " ") }
            guard run.contains(" ") else { return nil }
            // 「clote coate」這種分開講但其實是一個詞：把空白拿掉再試一次。
            let glued = run.replacingOccurrences(of: " ", with: "")
            if let direct = match(glued) { return direct }
            if glued.count >= 6, let parts = split(glued) { return parts.joined(separator: " ") }
            // 整串對不上（「Tesla OpenAIChatGPT」）：一個字一個字試，有修到才回。
            let words = run.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            var changed = false
            let fixed = words.map { word -> String in
                guard !word.isEmpty, let out = fixWord(word) else { return word }
                changed = true
                return out
            }
            return changed ? fixed.joined(separator: " ") : nil
        }

        /// 單一個英文字（沒有空白）：整個對、或照詞表切開。
        private func fixWord(_ word: String) -> String? {
            if let direct = match(word) { return direct }
            if word.count >= 6, let parts = split(word) { return parts.joined(separator: " ") }
            return nil
        }

        /// 單一字串對單一詞。
        func match(_ candidate: String) -> String? {
            let folded = LatinNameFixer.fold(candidate)
            guard folded.count >= 2 else { return nil }
            if let exact = byFolded[folded] {
                guard exact != candidate else { return nil }
                // 拼法真的不一樣（grook→Grok）一律修；只差大小寫時，只有「寫法本身特別」的詞才改
                // （OpenAI、ChatGPT、NVIDIA、MiniMax），單純首字大寫的（Apple、Tesla）不動，
                // 免得把英文句子裡的 apple、line 亂改成公司名。
                let sameLetters = LatinNameFixer.plain(candidate) == LatinNameFixer.plain(exact)
                return (!sameLetters || LatinNameFixer.hasDistinctiveCasing(exact)) ? exact : nil
            }
            guard !commonWords.contains(folded), folded.count >= 4 else { return nil }
            let skeleton = LatinNameFixer.skeleton(candidate)
            if skeleton.count >= 3, let owner = bySkeleton[skeleton],
               LatinNameFixer.lengthsComparable(folded, LatinNameFixer.fold(owner)) {
                return owner == candidate ? nil : owner
            }
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
            guard let winner = best, !tied, winner.text != candidate else { return nil }
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

    /// 只留字母數字、轉小寫（判斷「是不是只差大小寫」用，不做等價折疊）。
    static func plain(_ s: String) -> String {
        String(s.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// 第二個字母之後還有大寫，或整個都是大寫＝這個詞的寫法本身有特色（ChatGPT、NVIDIA、MiniMax、GitHub）。
    static func hasDistinctiveCasing(_ term: String) -> Bool {
        let letters = term.filter { $0.isLatinLetter }
        guard letters.count >= 2 else { return false }
        return letters.dropFirst().contains { $0.isUppercase }
    }

    static func lengthsComparable(_ a: String, _ b: String) -> Bool {
        let diff = abs(a.count - b.count)
        return diff <= max(2, min(a.count, b.count) / 3)
    }

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

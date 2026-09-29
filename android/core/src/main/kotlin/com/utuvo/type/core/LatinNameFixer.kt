package com.utuvo.type.core

/**
 * 英文專有名詞修正（同 Swift `LatinNameFixer`；行為以 Swift 為準）。
 *
 * 只在「一串拉丁字母」上動，中文一個字都不碰。三種比對：拼法一致（只差大小寫／空白）、
 * 子音骨架一致（丟母音＋清濁 d/t、g/k、b/p、v/f、z/s 折在一起）、加權編輯距離（母音 0.5、子音 1）。
 * 黏在一起的先照詞表切開。命中的字串本身是常用英文字就不換，免得動到正常英文。
 */
object LatinNameFixer {
    const val MAX_RUN_LENGTH = 40

    val VOWELS = setOf('a', 'e', 'i', 'o', 'u', 'y')

    private fun Char.isLatinLetter() = this.code < 128 && this.isLetter()

    fun fix(text: String, terms: List<String>): String {
        val table = Table(terms)
        if (table.isEmpty) return text
        val out = StringBuilder()
        var i = 0
        while (i < text.length) {
            val run = nextRun(text, i)
            if (run == null) { out.append(text, i, text.length); break }
            val (runStart, runEnd) = run
            out.append(text, i, runStart)
            // 超過上限的拉丁字串多半是網址、序號、程式碼、長句英文，整段原文保留、不進詞表比對，
            // 但 index 繼續往後走，讓後面的短 run 還能各自被修。
            val original = text.substring(runStart, runEnd)
            if (original.length > MAX_RUN_LENGTH) out.append(original)
            else out.append(table.fixRun(original) ?: original)
            i = runEnd
        }
        return out.toString()
    }

    /** 回傳 [start, endExclusive)；找不到回 null。 */
    private fun nextRun(text: String, from: Int): Pair<Int, Int>? {
        var first = from
        while (first < text.length && !text[first].isLatinLetter()) first++
        if (first >= text.length) return null
        var end = first
        var lastLetter = first
        while (end < text.length) {
            val c = text[end]
            if (c.isLatinLetter()) { lastLetter = end; end++ }
            else if (c == ' ' || c == '.' || c == '-') {
                if (end + 1 < text.length && text[end + 1].isLatinLetter()) end++ else break
            } else break
        }
        return first to lastLetter + 1
    }

    class Table(terms: List<String>) {
        private val byFolded = HashMap<String, String>()
        private val bySkeleton = HashMap<String, String>()
        private val canonical = ArrayList<Triple<String, String, String>>()   // folded, skeleton, text

        val isEmpty: Boolean get() = byFolded.isEmpty()

        init {
            val skeletonOwners = HashMap<String, MutableSet<String>>()
            for (term in terms) {
                val trimmed = term.trim()
                if (trimmed.length < 2) continue
                if (!trimmed.all { it.isLatinLetter() || it == ' ' || it == '-' || it == '.' || it.isDigit() }) continue
                if (trimmed.none { it.isLatinLetter() }) continue
                val folded = fold(trimmed)
                if (folded.length < 2 || folded in COMMON_WORDS) continue
                byFolded.putIfAbsent(folded, trimmed)
                val skeleton = skeleton(trimmed)
                if (skeleton.length >= 3) skeletonOwners.getOrPut(skeleton) { HashSet() }.add(trimmed)
                canonical.add(Triple(folded, skeleton, trimmed))
            }
            for ((skeleton, owners) in skeletonOwners) if (owners.size == 1) bySkeleton[skeleton] = owners.first()
        }

        fun fixRun(run: String): String? {
            match(run)?.let { return it }
            if (!run.contains(' ') && run.length >= 6) split(run)?.let { return it.joinToString(" ") }
            if (!run.contains(' ')) return null
            val glued = run.replace(" ", "")
            match(glued)?.let { return it }
            if (glued.length >= 6) split(glued)?.let { return it.joinToString(" ") }
            // 整串對不上（「Tesla OpenAIChatGPT」）：一個字一個字試，有修到才回。
            var changed = false
            val fixed = run.split(" ").map { word ->
                val out = if (word.isEmpty()) null else fixWord(word)
                if (out != null) { changed = true; out } else word
            }
            return if (changed) fixed.joinToString(" ") else null
        }

        /** 單一個英文字（沒有空白）：整個對、或照詞表切開。 */
        private fun fixWord(word: String): String? {
            match(word)?.let { return it }
            if (word.length >= 6) split(word)?.let { return it.joinToString(" ") }
            return null
        }

        fun match(candidate: String): String? {
            val folded = fold(candidate)
            if (folded.length < 2) return null
            byFolded[folded]?.let { exact ->
                if (exact == candidate) return null
                // 拼法真的不一樣（grook→Grok）一律修；只差大小寫時只改「寫法本身特別」的詞
                // （OpenAI、ChatGPT、NVIDIA、MiniMax），免得把英文句子裡的 apple、line 亂改。
                val sameLetters = plain(candidate) == plain(exact)
                return if (!sameLetters || hasDistinctiveCasing(exact)) exact else null
            }
            if (folded in COMMON_WORDS || folded.length < 4) return null
            val skeleton = skeleton(candidate)
            if (skeleton.length >= 3) {
                val owner = bySkeleton[skeleton]
                if (owner != null && lengthsComparable(folded, fold(owner))) return if (owner == candidate) null else owner
            }
            var best: Pair<Double, String>? = null
            var tied = false
            for ((entryFolded, _, text) in canonical) {
                if (!lengthsComparable(folded, entryFolded)) continue
                val limit = costLimit(entryFolded)
                val cost = distance(folded, entryFolded, limit)
                if (cost > limit) continue
                if (best == null || cost < best!!.first) { best = cost to text; tied = false }
                else if (cost == best!!.first && text != best!!.second) tied = true
            }
            val winner = best ?: return null
            if (tied || winner.second == candidate) return null
            return winner.second
        }

        private fun split(run: String, depth: Int = 0): List<String>? {
            if (depth >= 3) return null
            for (length in run.length - 2 downTo 2) {
                val headTerm = matchWhole(run.substring(0, length)) ?: continue
                val tail = run.substring(length)
                matchWhole(tail)?.let { return listOf(headTerm, it) }
                split(tail, depth + 1)?.let { return listOf(headTerm) + it }
            }
            return null
        }

        private fun matchWhole(piece: String): String? {
            val folded = fold(piece)
            if (folded.length < 2) return null
            byFolded[folded]?.let { return it }
            return match(piece)
        }
    }

    fun fold(s: String): String {
        val sb = StringBuilder()
        for (c in s.lowercase()) if (c.isLetter() || c.isDigit()) sb.append(c)
        var out = sb.toString()
            .replace("ph", "f").replace("ck", "k").replace("gh", "g").replace("wh", "w")
            .replace("x", "ks").replace("q", "k").replace("c", "k")
        val collapsed = StringBuilder()
        for (c in out) if (collapsed.lastOrNull() != c) collapsed.append(c)
        return collapsed.toString()
    }

    fun skeleton(s: String): String {
        val sb = StringBuilder()
        for (c in fold(s)) {
            if (c in VOWELS || !c.isLetter()) continue
            sb.append(
                when (c) {
                    'd' -> 't'; 'g' -> 'k'; 'b' -> 'p'; 'v' -> 'f'; 'z' -> 's'; 'j' -> 'k'
                    else -> c
                }
            )
        }
        val collapsed = StringBuilder()
        for (c in sb) if (collapsed.lastOrNull() != c) collapsed.append(c)
        return collapsed.toString()
    }

    /** 只留字母數字、轉小寫（判斷「是不是只差大小寫」用）。 */
    fun plain(s: String): String = s.lowercase().filter { it.isLetterOrDigit() }

    /** 第二個字母之後還有大寫＝寫法本身有特色（ChatGPT、NVIDIA、MiniMax、GitHub）。 */
    fun hasDistinctiveCasing(term: String): Boolean {
        val letters = term.filter { it.code < 128 && it.isLetter() }
        if (letters.length < 2) return false
        return letters.drop(1).any { it.isUpperCase() }
    }

    fun lengthsComparable(a: String, b: String): Boolean {
        val diff = kotlin.math.abs(a.length - b.length)
        return diff <= maxOf(2, minOf(a.length, b.length) / 3)
    }

    fun costLimit(folded: String): Double = when {
        folded.length < 5 -> 0.5
        folded.length <= 6 -> 1.0
        folded.length <= 9 -> 1.5
        else -> 2.0
    }

    /** 加權編輯距離：母音 0.5、子音 1、相鄰對調 0.5；超過 limit 提早放棄。 */
    fun distance(a: String, b: String, limit: Double): Double {
        fun cost(c: Char) = if (c in VOWELS) 0.5 else 1.0
        var previous = DoubleArray(b.length + 1)
        var twoBack = DoubleArray(b.length + 1)
        for (j in 1..b.length) previous[j] = previous[j - 1] + cost(b[j - 1])
        if (a.isEmpty()) return previous[b.length]
        var current = previous
        for (i in 1..a.length) {
            current = DoubleArray(b.length + 1)
            current[0] = previous[0] + cost(a[i - 1])
            var rowMin = current[0]
            for (j in 1..b.length) {
                val substitution = when {
                    a[i - 1] == b[j - 1] -> 0.0
                    a[i - 1] in VOWELS && b[j - 1] in VOWELS -> 0.5
                    else -> 1.0
                }
                var value = minOf(previous[j - 1] + substitution, previous[j] + cost(a[i - 1]), current[j - 1] + cost(b[j - 1]))
                if (i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1]) value = minOf(value, twoBack[j - 2] + 0.5)
                current[j] = value
                rowMin = minOf(rowMin, value)
            }
            if (rowMin > limit) return limit + 1
            twoBack = previous
            previous = current
        }
        return current[b.length]
    }

    /** 常用英文字（存折過的寫法）：命中就不動。與 Swift 同一份。 */
    val COMMON_WORDS: Set<String> = listOf(
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
    ).map { fold(it) }.toSet()
}

package com.utuvo.type.core

/**
 * 英文專有名詞修正（同 Swift `LatinNameFixer`；行為以 Swift 為準）。
 *
 * 只在「一串拉丁字母」上動，中文一個字都不碰。三種比對：拼法一致（只差大小寫／空白）、
 * 子音骨架一致（丟母音＋清濁 d/t、g/k、b/p、v/f、z/s 折在一起）、加權編輯距離（母音 0.5、子音 1）。
 * 黏在一起的先照詞表切開。命中的字串本身是常用英文字就不換，免得動到正常英文。
 *
 * 常用英文字護欄（FX-5，同 Swift）：單獨聽到的一個字本身就是常用英文字（[CommonEnglishWords]，english-words.txt
 * 的 SCOWL 10～35 級，前 49,877 行）→ 只准修大小寫（iphone→iPhone），不准換成別的詞（phone→iPhone、shop→Zhipu、types→Typeless 都不准）。
 * 多字詞與不是英文字的照舊比對；個人字典的明確替換在字典那一關照樣套。
 *
 * W2-1 verifier 補的四條（2026-10-22，同 Swift）：有數字的詞（3Coins、1Password、7-Eleven）不當比對目標（33Coins 疊字）；
 * 個人字典有明確規則的字（[fix] 的 `keep`）原樣留給字典那一關；詞的複數（UTUVO Types）不改回單數；
 * 智慧整理寫的文字（[TextSource.CLEANUP]）：正常寫法的單字（codec、Mickey）不換成另一個單字詞，全是常用字的片語
 * （Tone Master）不換成字數不同的詞，大小寫也只修寫法本身特別的字（UTUVO、DAMI），一般名詞小寫（vibe coding）不動。
 */
object LatinNameFixer {
    const val MAX_RUN_LENGTH = 40

    val VOWELS = setOf('a', 'e', 'i', 'o', 'u', 'y')

    /** 這段文字是誰寫的（同 Swift `TextSource`）。 */
    enum class TextSource {
        /** 辨識器的逐字稿（本機整理版、第一次貼上）：拼錯是常態，模糊比對照常。 */
        SPEECH,
        /** 已經過把關的智慧整理結果：只修使用者自己的寫法，模型寫對的英文一個字都不動。 */
        CLEANUP,
    }

    private fun Char.isLatinLetter() = this.code < 128 && this.isLetter()

    fun fix(text: String, terms: List<String>): String = fix(text, terms, TextSource.SPEECH)

    /** `keep`＝個人字典有明確替換規則的寫法（字典的 key）：完全一樣的字（或連續幾個字）原樣留給字典那一關。 */
    fun fix(text: String, terms: List<String>, source: TextSource, keep: Set<String> = emptySet()): String {
        val table = Table(terms, source, keep)
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

    class Table(terms: List<String>, val source: TextSource = TextSource.SPEECH, keep: Set<String> = emptySet()) {
        private val byFolded = HashMap<String, String>()
        private val bySkeleton = HashMap<String, String>()
        private val canonical = ArrayList<Triple<String, String, String>>()   // folded, skeleton, text
        /** 個人字典規則的 key 切成字（只留含拉丁字母的）。 */
        private val keepPhrases: List<List<String>> =
            keep.filter { k -> k.any { it.isLatinLetter() } }.map { k -> k.split(' ').filter { it.isNotEmpty() } }.filter { it.isNotEmpty() }

        val isEmpty: Boolean get() = byFolded.isEmpty()

        init {
            val skeletonOwners = HashMap<String, MutableSet<String>>()
            for (term in terms) {
                val trimmed = term.trim()
                if (trimmed.length < 2) continue
                // 有數字的詞不收（3Coins→33Coins，見檔頭）。
                if (!trimmed.all { it.isLatinLetter() || it == ' ' || it == '-' || it == '.' }) continue
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
            val words = run.split(" ")
            // 個人字典有明確規則的字（cloud→Claude）原樣留給字典那一關，其他字各自修（同 Swift）。
            val kept = keptWords(words)
            if (kept.any { it }) {
                var changed = false
                val fixed = words.mapIndexed { i, word ->
                    val out = if (kept[i] || word.isEmpty()) null else fixWord(word)
                    if (out != null) { changed = true; out } else word
                }
                return if (changed) fixed.joinToString(" ") else null
            }
            match(run)?.let { return it }
            // 常用英文字本身不切（FX-5）。
            if (!run.contains(' ') && run.length >= 6 && maySplit(run)) split(run)?.let { return it.joinToString(" ") }
            if (!run.contains(' ')) return null
            // 把空白拿掉再試一次（聽到的字數照原本的算）。
            val glued = run.replace(" ", "")
            match(glued, wordCount(run), run)?.let { return it }
            if (glued.length >= 6 && maySplit(run)) split(glued)?.let { return it.joinToString(" ") }
            // 「Largec Pro」「Large C Pro」（Logic Pro）：最後一個字對得上兩字詞的後字，前面那段再寬一點比（見 matchAnchored）。
            matchAnchored(words)?.let { return it }
            // 整串對不上（「Tesla OpenAIChatGPT」）：一個字一個字試，有修到才回。
            var changed = false
            val fixed = words.map { word ->
                val out = if (word.isEmpty()) null else fixWord(word)
                if (out != null) { changed = true; out } else word
            }
            return if (changed) fixed.joinToString(" ") else null
        }

        /**
         * 兩字詞的後字當錨（FX-5，同 Swift `matchAnchored`）：辨識器把「Logic Pro」聽成「Largec Pro」「Large C Pro」，
         * 前字多了一個 r、差兩個母音（加權距離 2），整串比的上限（1.5）不夠。只在這些條件都成立時換：辨識稿（智慧整理寫的不算）、
         * 聽到 2～3 個字、最後一個字跟兩字詞的後字折起來一樣（Pro）、前面那段黏起來不是常用英文字（lark Pro、large Pro 不動）、
         * 前字至少 5 個字母、跟前字同首字母、子音骨架只差多出來的 r（Largec＝l-r-k，Logic＝l-k；logins、Louis、David、Paris
         * 這種骨架不同的不換）、距離 ≤ [ANCHORED_COST_LIMIT]、唯一最近。
         */
        private fun matchAnchored(words: List<String>): String? {
            if (source != TextSource.SPEECH) return null
            val heard = words.filter { it.isNotEmpty() }
            if (heard.size !in 2..3) return null
            val prefix = heard.dropLast(1).joinToString("")
            if (isCommonEnglishWord(prefix)) return null
            val head = fold(prefix)
            val tail = fold(heard.last())
            if (head.length < 4) return null
            var best: Pair<Double, String>? = null
            var tied = false
            for ((_, _, text) in canonical) {
                val parts = text.split(' ').filter { it.isNotEmpty() }
                if (parts.size != 2 || fold(parts[1]) != tail) continue
                val target = fold(parts[0])
                if (target.length < 5 || target[0] != head[0] || !lengthsComparable(head, target) ||
                    !differsOnlyByExtraR(prefix, parts[0])) continue
                val cost = distance(head, target, ANCHORED_COST_LIMIT)
                if (cost > ANCHORED_COST_LIMIT) continue
                val current = best
                if (current != null && cost >= current.first) {
                    if (cost == current.first && text != current.second) tied = true
                } else {
                    best = cost to text
                    tied = false
                }
            }
            val winner = best ?: return null
            return if (tied || winner.second == heard.joinToString(" ")) null else winner.second
        }

        /** 每個字是不是落在某一條個人字典規則的 key 裡（整條 key 的字要連續、完全一樣，同 Swift keptWords）。 */
        private fun keptWords(words: List<String>): BooleanArray {
            val kept = BooleanArray(words.size)
            for (phrase in keepPhrases) {
                if (phrase.size > words.size) continue
                for (start in 0..(words.size - phrase.size)) {
                    if (phrase.indices.all { words[start + it] == phrase[it] }) for (i in start until start + phrase.size) kept[i] = true
                }
            }
            return kept
        }

        /** 單一個英文字（沒有空白）：整個對、或照詞表切開。 */
        private fun fixWord(word: String): String? {
            match(word)?.let { return it }
            if (word.length >= 6 && maySplit(word)) split(word)?.let { return it.joinToString(" ") }
            return null
        }

        /**
         * 聽到（或寫出來）的這串能不能換成拼法不同的 `term`（同 Swift mayRespell）：單一個常用英文字不行（FX-5）；
         * 智慧整理寫的正常寫法單字（codec、Mickey；駝峰 ToneMaster 不算）只准換成多字詞（Protus→Pro Tools）；
         * 智慧整理寫的、每個字都是常用字的片語只准換成一樣字數的詞（Special Audio→Spatial Audio；Tone Master→Tonmeister 不行）。
         */
        fun mayRespell(heard: String, term: String): Boolean {
            val words = heard.split(' ').filter { it.isNotEmpty() }
            if (words.size <= 1) {
                if (isCommonEnglishWord(heard)) return false
                return source == TextSource.SPEECH || !isPlainWordShape(heard) || wordCount(term) >= 2
            }
            // 每個字都是常用字、字數又一樣（兩種來源都一樣）：要一個字對一個字對得上（同 Swift；game music→DAMI music 不行）。
            val allCommon = words.all { isCommonEnglishWord(it) }
            if (allCommon && wordCount(term) == words.size) return wordsAlign(words, term)
            // 全是常用字、字數不一樣：只限辨識稿，而且開頭要同一個字母（access code→Xcode 不換；同 Swift）。
            if (allCommon) return source == TextSource.SPEECH && fold(heard).firstOrNull() == fold(term).firstOrNull()
            return true
        }

        /** 照詞表切開之前：單一個常用英文字不切（FX-5）；每個字都是常用字的片語不黏起來切（同 Swift maySplit）。 */
        fun maySplit(heard: String): Boolean {
            val words = heard.split(' ').filter { it.isNotEmpty() }
            if (words.size <= 1) return !isCommonEnglishWord(heard)
            // 全是常用字的片語不黏起來切（兩種來源都一樣；selective Type→Slack UTUVO Type；同 Swift）。
            return !words.all { isCommonEnglishWord(it) }
        }

        /** 單一字串對單一詞（聽到的字數＝字串本身用空白分開的字數）。 */
        fun match(candidate: String): String? = match(candidate, wordCount(candidate))

        /** `heardWords`：辨識器輸出時這串是幾個字（同 Swift `match(_:heardWords:)`）。 */
        fun match(candidate: String, heardWords: Int): String? = match(candidate, heardWords, candidate)

        /** `heard`：原本聽到（寫出來）的樣子，判斷 [mayRespell] 用（`candidate` 可能是拿掉空白的版本）。 */
        fun match(candidate: String, heardWords: Int, heard: String): String? {
            val folded = fold(candidate)
            if (folded.length < 2) return null
            // FX-5：聽到的單一個字本身就是常用英文字 → 只准修大小寫，不准換成別的詞（同 Swift；智慧整理寫的另有規則，見 [mayRespell]）。
            byFolded[folded]?.let { exact ->
                if (exact == candidate) return null
                // 拼法真的不一樣（grook→Grok）一律修；只差大小寫時只改「寫法本身特別」的詞
                // （OpenAI、ChatGPT、NVIDIA、MiniMax），免得把英文句子裡的 apple、line 亂改。
                val sameLetters = plain(candidate) == plain(exact)
                if (!sameLetters) return if (mayRespell(heard, exact) && !isPlural(candidate, exact)) exact else null
                // 智慧整理寫的：只看每個字自己的寫法（UTUVO、DAMI 才算；Vibe Coding 不算）。
                val distinctive = if (source == TextSource.CLEANUP) hasDistinctiveWordCasing(exact) else hasDistinctiveCasing(exact)
                return if (distinctive) exact else null
            }
            if (isCommonEnglishWord(heard) || folded in COMMON_WORDS || folded.length < 4) return null
            // 加權距離先算：距離內有唯一最近的詞就用它（同 Swift，2026-10-22 asr-vocab-v1：「Protus」不再變「Uber Eats」）。
            nearestByDistance(folded)?.let { return if (it == candidate || isPlural(candidate, it) || !mayRespell(heard, it)) null else it }
            // 只有骨架對得上：首字同類，聽成好幾個字的字數要跟詞一樣。
            val skeleton = skeleton(candidate)
            if (skeleton.length >= 3) {
                val owner = bySkeleton[skeleton]
                if (owner != null && lengthsComparable(folded, fold(owner)) &&
                    onsetClass(candidate) == onsetClass(owner) &&
                    (heardWords <= 1 || heardWords == wordCount(owner))
                ) return if (owner == candidate || isPlural(candidate, owner) || !mayRespell(heard, owner)) null else owner
            }
            return null
        }

        /** 加權編輯距離在上限內、而且唯一最近的詞；同分分不出來就回 null。 */
        private fun nearestByDistance(folded: String): String? {
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
            return if (tied) null else winner.second
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

    /**
     * 片語一個字對一個字（mayRespell 用，字數已經一樣；同 Swift `wordsAlign`）：每一對要折起來一樣，或首字母一樣而且
     * （距離在那個詞字的上限內，或子音骨架一樣、距離也不超過 [ALIGNED_SKELETON_COST_LIMIT]：coat／code 是 2；
     * quality／Claude、could／Claude 骨架一樣但差太多）。
     */
    fun wordsAlign(heard: List<String>, term: String): Boolean {
        val targets = term.split(' ').filter { it.isNotEmpty() }
        if (targets.size != heard.size) return false
        return heard.indices.all { i ->
            val a = fold(heard[i])
            val b = fold(targets[i])
            when {
                a == b -> true
                a.isEmpty() || b.isEmpty() || a[0] != b[0] -> false
                costLimit(b).let { limit -> distance(a, b, limit) <= limit } -> true
                else -> skeleton(heard[i]) == skeleton(targets[i]) &&
                    distance(a, b, ALIGNED_SKELETON_COST_LIMIT) <= ALIGNED_SKELETON_COST_LIMIT
            }
        }
    }

    /** 子音骨架只差多出來的 r（[Table.matchAnchored] 用，同 Swift `differsOnlyByExtraR`）：聽到的骨架裡 r 比較多，拿掉 r 之後跟詞一樣。 */
    fun differsOnlyByExtraR(heard: String, term: String): Boolean {
        val a = skeleton(heard)
        val b = skeleton(term)
        if (a.count { it == 'r' } <= b.count { it == 'r' }) return false
        fun withoutR(s: String): String {
            val out = StringBuilder()
            for (c in s) if (c != 'r' && out.lastOrNull() != c) out.append(c)
            return out.toString()
        }
        return withoutR(a) == withoutR(b)
    }

    /** 首字類別：母音開頭的全算一類；子音開頭的看骨架首字（同 Swift onsetClass）。 */
    fun onsetClass(s: String): String {
        val first = fold(s).firstOrNull() ?: return ""
        if (first in VOWELS) return "vowel"
        if (first.isLetter()) skeleton(first.toString()).firstOrNull()?.let { return it.toString() }
        return first.toString()
    }

    /** 用空白分開的字數（「Claude Code」＝2、「clotecoate」＝1；同 Swift wordCount）。 */
    fun wordCount(s: String): Int = s.split(" ").count { it.isNotEmpty() }

    /** 只留字母數字、轉小寫（判斷「是不是只差大小寫」用）。 */
    fun plain(s: String): String = s.lowercase().filter { it.isLetterOrDigit() }

    /** 單一個字（沒有空白）而且本身是常用英文字（[CommonEnglishWords]，FX-5；同 Swift isCommonEnglishWord）。 */
    fun isCommonEnglishWord(token: String): Boolean = !token.contains(' ') && CommonEnglishWords.contains(plain(token))

    /** 正常英文字的寫法：全小寫、首字大寫其餘小寫、全大寫；駝峰（ToneMaster、iCloud、NVidia）不算（同 Swift isPlainWordShape）。 */
    fun isPlainWordShape(word: String): Boolean {
        val letters = word.filter { it.isLatinLetter() }
        return letters.drop(1).all { it.isLowerCase() } || letters.all { it.isUpperCase() }
    }

    /** `candidate` 是 `term` 加 s／es（UTUVO Types、GPTs）：複數不是拼錯，不改回單數（同 Swift isPlural）。 */
    fun isPlural(candidate: String, term: String): Boolean {
        val c = plain(candidate)
        val t = plain(term)
        return c == t + "s" || c == t + "es"
    }

    /** 第二個字母之後還有大寫＝寫法本身有特色（ChatGPT、NVIDIA、MiniMax、GitHub）。 */
    fun hasDistinctiveCasing(term: String): Boolean {
        val letters = term.filter { it.code < 128 && it.isLetter() }
        if (letters.length < 2) return false
        return letters.drop(1).any { it.isUpperCase() }
    }

    /** 一個字一個字看（同 Swift hasDistinctiveWordCasing）：UTUVO、DAMI、ChatGPT 算；Vibe Coding、True Peak 不算。 */
    fun hasDistinctiveWordCasing(term: String): Boolean = term.split(' ').any { hasDistinctiveCasing(it) }

    fun lengthsComparable(a: String, b: String): Boolean {
        val diff = kotlin.math.abs(a.length - b.length)
        return diff <= maxOf(2, minOf(a.length, b.length) / 3)
    }

    /** [Table.matchAnchored] 前字的距離上限（後字已經完全對上；同 Swift `anchoredCostLimit`）。 */
    const val ANCHORED_COST_LIMIT = 2.0

    /** [wordsAlign] 骨架一樣的那一對字，距離上限（同 Swift `alignedSkeletonCostLimit`）。 */
    const val ALIGNED_SKELETON_COST_LIMIT = 2.0

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

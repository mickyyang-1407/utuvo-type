#!/usr/bin/env python3
"""編出英文專名修正（LatinNameFixer）用的「常用英文字」表：Swift core 與 Kotlin core 各一份，內容逐字相同。

為什麼需要（FX-5，2026-10-22）：模糊比對會把一般英文字拉成產品名——舊 Mac 的 16 個詞在前兩萬個常用字裡改到 100 個
（glad／cloud→Claude、apply→Apple），Android／iOS 用的整包 ai 改到 295 個（phone→iPhone、shop→Zhipu、stock→SDK、
types→Typeless、commits→commit），每個人的第一次貼上都會碰到。修正器拿這張表當護欄：單獨一個字、本身就是常用英文字，
只准修大小寫（iphone→iPhone），不准換成別的詞。

來源：`android/app/src/main/assets/english-words.txt`（scripts/build-english-words.py 從 SCOWL 2020.12.07 產生，
行號＝常用度排名；授權見 THIRD_PARTY_NOTICES.md）。取 SCOWL 大小級 10＋20＋35 的全部（SCOWL 的 small 大小，
檔案裡第 1～49,877 行；後面的 40、50 級多半是罕用字與人名地名），只留純 ASCII 字母的字（撇號字在修正器裡本來就會被
切成兩段），轉小寫、去重、照字母排。

為什麼不是「前兩萬行」：那份檔案同一級裡是照字長排的，前兩萬行剛好切在 35 級的六個字母，七個字母以上的 35 級常用字
（nineteen、metering、partials、timeless、Christmas、telegraph）全在外面——只護前兩萬行時它們照樣被改成
Notion、mastering、Pro Tools、Typeless、Cohere stems、Telegram（FX-5 量測）。

為什麼不直接讀 english-words.txt：那是 Android app 模組的 asset（87 萬 bytes、9 萬字），Swift core（Mac、iOS 主程式、
iOS 鍵盤 extension 都連它）讀不到、也不該為了四萬字多帶 87 萬 bytes；core 用 SwiftPM resource 又會讓直接連 core 原始碼的
工具（segbench）編不起來。所以兩邊各內嵌一份，由這支腳本一次產生，`--check` 與兩邊的測試確保內容一致。

用法：
    python3 scripts/build-common-english-words.py            # 重新產生兩個檔案
    python3 scripts/build-common-english-words.py --check    # 只比對，不一致 exit 1
"""
import argparse
import pathlib
import re
import sys

LINE_WIDTH = 100
MAX_CHUNK_BYTES = 60_000   # Kotlin 單一字串常數上限 65,535 bytes
ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "android/app/src/main/assets/english-words.txt"
SWIFT = ROOT / "Sources/UTUVOTypeCore/CommonEnglishWords.swift"
KOTLIN = ROOT / "android/core/src/main/kotlin/com/utuvo/type/core/CommonEnglishWords.kt"
LETTERS = re.compile(r"^[A-Za-z]+$")


def ranked() -> list[str]:
    return [w.strip() for w in SOURCE.read_text(encoding="utf-8").split("\n") if w.strip()]


def rank_cutoff(rs: list[str]) -> int:
    """35 級最後一行的下一行。build-english-words.py 照（級、字長、字母）排，所以字長變短的地方就是換級。"""
    starts = [i for i in range(1, len(rs)) if len(rs[i]) < len(rs[i - 1])]
    if len(starts) != 4:
        sys.exit(f"english-words.txt 應該有 5 級（10/20/35/40/50），找到 {len(starts) + 1} 級：{starts}")
    return starts[2]


def words() -> tuple[int, list[str]]:
    rs = ranked()
    cutoff = rank_cutoff(rs)
    return cutoff, sorted({w.lower() for w in rs[:cutoff] if LETTERS.match(w)})


def chunks(ws: list[str]) -> list[tuple[str, list[str]]]:
    """照首字母分段（Kotlin 單一字串常數上限 65,535 bytes；兩邊用同樣的分段，比對時一段對一段）。"""
    out: dict[str, list[str]] = {}
    for w in ws:
        out.setdefault(w[0], []).append(w)
    for letter, group in out.items():
        size = sum(len(w) + 1 for w in group)
        if size > MAX_CHUNK_BYTES:
            sys.exit(f"首字母 {letter} 這段 {size} bytes，超過 Kotlin 字串常數上限，要再細分")
    return sorted(out.items())


def wrap(ws: list[str], indent: str) -> str:
    lines, line = [], ""
    for w in ws:
        if line and len(line) + 1 + len(w) > LINE_WIDTH:
            lines.append(line)
            line = w
        else:
            line = f"{line} {w}" if line else w
    if line:
        lines.append(line)
    return "\n".join(indent + l for l in lines)


HEADER = """由 scripts/build-common-english-words.py 產生，不要手改（改了 `--check` 與兩邊的測試會紅）。
來源：android/app/src/main/assets/english-words.txt（SCOWL 2020.12.07，授權見 THIRD_PARTY_NOTICES.md）
前 {cutoff:,} 行（SCOWL 大小級 10＋20＋35），只留純 ASCII 字母的字、轉小寫、去重、照字母排，
共 {count:,} 個字（{size:,} bytes）。另一份：{other}（內容逐字相同）。"""


def swift(cutoff: int, ws: list[str]) -> str:
    size = sum(len(w) + 1 for w in ws)
    head = HEADER.format(cutoff=cutoff, count=len(ws), size=size,
                         other="android/core/src/main/kotlin/com/utuvo/type/core/CommonEnglishWords.kt")
    parts = ["\n".join("// " + l for l in head.split("\n")), "",
             "/// 常用英文字（FX-5）：`LatinNameFixer` 不會把單獨出現的這些字換成別的詞（只差大小寫的同一個字照修）。",
             "enum CommonEnglishWords {",
             f"    /// 取來源詞表的前幾行（SCOWL 35 級的最後一行）。",
             f"    static let rankCutoff = {cutoff}",
             f"    /// 字數（測試用）。",
             f"    static let count = {len(ws)}",
             "",
             "    /// 小寫的字是不是在表裡。",
             "    static func contains(_ lowercased: String) -> Bool { words.contains(lowercased) }",
             "",
             f"    /// 第一次查才展開（{len(ws):,} 個字）。",
             "    static let words: Set<String> = {",
             "        var out = Set<String>(minimumCapacity: count)",
             "        for chunk in chunks {",
             "            for word in chunk.split(whereSeparator: { $0 == \" \" || $0 == \"\\n\" }) { out.insert(String(word)) }",
             "        }",
             "        return out",
             "    }()",
             "",
             "    /// 照首字母分段，段內空白／換行分隔。",
             "    static let chunks: [String] = ["]
    for _, group in chunks(ws):
        # 字串內容貼齊左邊：Kotlin 原始字串會把縮排一起編進字串常數（多幾十 KB），兩邊同樣排法方便比對。
        parts.append('"""')
        parts.append(wrap(group, ""))
        parts.append('""",')
    parts.append("    ]")
    parts.append("}")
    return "\n".join(parts) + "\n"


def kotlin(cutoff: int, ws: list[str]) -> str:
    size = sum(len(w) + 1 for w in ws)
    head = HEADER.format(cutoff=cutoff, count=len(ws), size=size,
                         other="Sources/UTUVOTypeCore/CommonEnglishWords.swift")
    parts = ["\n".join("// " + l for l in head.split("\n")),
             "package com.utuvo.type.core",
             "",
             "/** 常用英文字（FX-5）：[LatinNameFixer] 不會把單獨出現的這些字換成別的詞（只差大小寫的同一個字照修）。 */",
             "internal object CommonEnglishWords {",
             "    /** 取來源詞表的前幾行（SCOWL 35 級的最後一行）。 */",
             f"    const val RANK_CUTOFF = {cutoff}",
             "    /** 字數（測試用）。 */",
             f"    const val COUNT = {len(ws)}",
             "",
             "    /** 小寫的字是不是在表裡。 */",
             "    fun contains(lowercased: String): Boolean = lowercased in words",
             "",
             f"    /** 第一次查才展開（{len(ws):,} 個字）。 */",
             "    val words: Set<String> by lazy {",
             "        val out = HashSet<String>(COUNT * 2)",
             "        for (chunk in CHUNKS) for (word in chunk.split(' ', '\\n')) if (word.isNotEmpty()) out.add(word)",
             "        out",
             "    }",
             "",
             "    /** 照首字母分段，段內空白／換行分隔（Kotlin 單一字串常數上限 65,535 bytes）。 */",
             "    val CHUNKS: Array<String> = arrayOf("]
    for _, group in chunks(ws):
        # 字串內容貼齊左邊：Kotlin 原始字串會把縮排一起編進字串常數（多幾十 KB），兩邊同樣排法方便比對。
        parts.append('"""')
        parts.append(wrap(group, ""))
        parts.append('""",')
    parts.append("    )")
    parts.append("}")
    return "\n".join(parts) + "\n"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="只比對既有檔案，不一致 exit 1")
    args = ap.parse_args()
    cutoff, ws = words()
    outputs = {SWIFT: swift(cutoff, ws), KOTLIN: kotlin(cutoff, ws)}
    if args.check:
        bad = [p for p, text in outputs.items() if not p.exists() or p.read_text(encoding="utf-8") != text]
        for p in bad:
            print("DIFFERENT", p.relative_to(ROOT))
        print("same" if not bad else "")
        sys.exit(1 if bad else 0)
    for p, text in outputs.items():
        p.write_text(text, encoding="utf-8")
        print(f"{p.relative_to(ROOT)}: rank cutoff {cutoff}, {len(ws)} words, {len(text.encode()):,} bytes")


if __name__ == "__main__":
    main()

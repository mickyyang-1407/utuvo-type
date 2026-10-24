#!/usr/bin/env python3
"""編出 Mac 修改學習用的常用英文字表 `Sources/UTUVOTypeCore/EnglishCommonWords.swift`。

為什麼需要（2026-10-22 修補 verifier mac-learning2）：從修改學字典時，全大寫的詞要分得出是品牌縮寫（UTUVO、DAMI）
還是強調（important→IMPORTANT）。`LatinNameFixer.commonWords` 只有約 400 字，important 不在裡面。
core 是純 Foundation、沒有資源檔，所以從 repo 既有的英文詞表取一段常用字，產生成 Swift 原始碼。

來源：`android/app/src/main/assets/english-words.txt`（scripts/build-english-words.py 從 SCOWL 2020.12.07 編出，
授權見 THIRD_PARTY_NOTICES.md）。那份檔案依（SCOWL 大小級、字長、字母序）排序，所以「字長變短」就是進到下一級；
這裡取前兩級（10、20，SCOWL 的常用字），只留純英文字母的字（去掉 don't 這類），轉小寫、排序。

用法：
    python3 scripts/build-english-common-words.py           # 重新產生
    python3 scripts/build-english-common-words.py --check   # 只比對既有檔案是否與重建結果相同
"""
import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "android/app/src/main/assets/english-words.txt"
OUTPUT = ROOT / "Sources/UTUVOTypeCore/EnglishCommonWords.swift"
LEVELS = 2   # SCOWL 10、20
WORD = re.compile(r"^[A-Za-z]+$")


def common_words(source: pathlib.Path) -> list[str]:
    words = [line.strip() for line in source.read_text(encoding="utf-8").splitlines() if line.strip()]
    level, out, previous = 0, set(), 0
    for w in words:
        if len(w) < previous:
            level += 1
            if level >= LEVELS:
                break
        previous = len(w)
        if WORD.match(w):
            out.add(w.lower())
    return sorted(out)


def render(words: list[str]) -> str:
    lines, line = [], ""
    for w in words:
        if line and len(line) + 1 + len(w) > 110:
            lines.append(line)
            line = w
        else:
            line = f"{line} {w}" if line else w
    if line:
        lines.append(line)
    body = "\n".join(lines)
    return f'''// 由 scripts/build-english-common-words.py 產生，不要手改。
// 來源：android/app/src/main/assets/english-words.txt 的 SCOWL 10＋20 級（{len(words)} 字，純英文字母、小寫）。
import Foundation

/// 常用英文字（小寫）。修改學習判斷全大寫是品牌縮寫（UTUVO）還是強調（IMPORTANT）用。
enum EnglishCommonWords {{
    static let count = {len(words)}

    static func contains(_ lowercased: String) -> Bool {{ words.contains(lowercased) }}

    static let words: Set<String> = Set(raw.split(whereSeparator: {{ $0 == " " || $0 == "\\n" }}).map(String.init))

    private static let raw = """
{body}
"""
}}
'''


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()
    text = render(common_words(SOURCE))
    if args.check:
        same = OUTPUT.exists() and OUTPUT.read_text(encoding="utf-8") == text
        print("same" if same else "DIFFERENT")
        sys.exit(0 if same else 1)
    OUTPUT.write_text(text, encoding="utf-8")
    print(f"{OUTPUT}: {text.count(chr(10))} lines")


if __name__ == "__main__":
    main()

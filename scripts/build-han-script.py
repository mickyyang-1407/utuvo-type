#!/usr/bin/env python3
"""產生辨識提示詞用的簡繁判斷表（Mac core HanScriptData.swift ＋ Android core HanScriptData.kt，兩份內容相同）。

為什麼要：提示詞以前整串跑 ICU Hans-Hant，已經是繁體的字會被改掉（周杰倫→周傑倫、干擾→乾擾、奇岩站→奇巖站、
于美人→於美人）。現在只轉「真的是簡體寫的詞」，判斷靠兩張字表：

- simplifiedOnly：OpenCC STCharacters 的鍵、候選裡沒有自己（码→碼；杰→傑 杰、干→幹 乾 干 兩邊都能用，不算），
  再去掉台灣標準字形（TWVariants 的值：床 秘 群 峰…）與台灣詞庫裡真的有人用的字：小麥注音（McBopomofo，MIT，
  repo 裡的 ios/Keyboard/Resources/zhuyin.dat）至少 3 個多字詞用到（雇主、頭前庄、倒霉、疱疹：雇 庄 霉 疱 晒 肴…）。
  只出現在 0–2 個詞的（扰 机 体 网 条）照樣當簡體。
- traditionalOnly：OpenCC TSCharacters 的鍵、候選裡沒有自己（倫→伦、擾→扰；乾→乾 干 不算）。

只收 BMP（U+0000–U+FFFF）的字。需要 Homebrew opencc（opencc_dict）。
用法：python3 -I scripts/build-han-script.py
"""
import collections, os, struct, subprocess, tempfile

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
swift_out = os.path.join(root, "Sources", "UTUVOTypeCore", "HanScriptData.swift")
kotlin_out = os.path.join(root, "android", "core", "src", "main", "kotlin", "com", "utuvo", "type", "core", "HanScriptData.kt")
zhuyin = os.path.join(root, "ios", "Keyboard", "Resources", "zhuyin.dat")
TAIWAN_PHRASES = 3

prefix = subprocess.run(["brew", "--prefix", "opencc"], capture_output=True, text=True, check=True).stdout.strip()
src = os.path.join(prefix, "share", "opencc")
version = subprocess.run(["opencc", "--version"], capture_output=True, text=True).stdout.strip().splitlines()[0].strip()


def load(tmp, name):
    raw = os.path.join(tmp, name + ".txt")
    subprocess.run(["opencc_dict", "-i", os.path.join(src, name + ".ocd2"), "-o", raw, "-f", "ocd2", "-t", "text"], check=True)
    table = {}
    with open(raw, encoding="utf-8") as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 2 and parts[0]:
                table[parts[0]] = parts[1].split(" ")
    return table


def taiwan_phrase_counts(path):
    """zhuyin.dat（格式見 scripts/build-zhuyin-data.py）裡每個字出現在幾個多字詞。"""
    data = open(path, "rb").read()
    magic, _, _, key_count, _, _, _, records = struct.unpack_from("<4sIIIIIII", data, 0)
    assert magic == b"UTZY"
    counts = collections.Counter()
    pos = records
    for _ in range(key_count):
        pos += 1 + 2 * data[pos]
        (m,) = struct.unpack_from("<H", data, pos)
        pos += 2
        for _ in range(m):
            length = data[pos + 2]
            word = data[pos + 3:pos + 3 + length].decode("utf-8")
            pos += 3 + length
            if len(word) > 1:
                counts.update(set(word))
    return counts


with tempfile.TemporaryDirectory() as tmp:
    st, ts, tw = load(tmp, "STCharacters"), load(tmp, "TSCharacters"), load(tmp, "TWVariants")

taiwan = {c for values in tw.values() for c in values}
phrases = taiwan_phrase_counts(zhuyin)
simplified = sorted(k for k, v in st.items() if len(k) == 1 and ord(k) <= 0xFFFF and k not in v
                    and k not in taiwan and phrases[k] < TAIWAN_PHRASES)
traditional = sorted(k for k, v in ts.items() if len(k) == 1 and ord(k) <= 0xFFFF and k not in v)


def lines(chars, indent):
    return "\n".join(indent + "".join(chars[i:i + 40]) for i in range(0, len(chars), 40))


header = (f"由 scripts/build-han-script.py 從 {version} 的 STCharacters／TSCharacters／TWVariants"
          "＋小麥注音詞庫（zhuyin.dat）產生，不要手改。\n"
          "OpenCC：Apache-2.0，https://github.com/BYVoid/OpenCC；McBopomofo：MIT。"
          "Mac 與 Android 是同一份（BuiltInVocabularyTests 逐字比對）。")
comment = "\n".join("/// " + line for line in header.split("\n"))

with open(swift_out, "w", encoding="utf-8") as f:
    f.write(f"""{comment}
enum HanScriptData {{
    /// 只在簡體出現的字（{len(simplified)} 字）。
    static let simplifiedOnly = \"\"\"
{lines(simplified, "        ")}
        \"\"\"

    /// 只在繁體出現的字（{len(traditional)} 字）。
    static let traditionalOnly = \"\"\"
{lines(traditional, "        ")}
        \"\"\"
}}
""")

kdoc = "/**\n" + "\n".join(" * " + line for line in header.split("\n")) + "\n */"
with open(kotlin_out, "w", encoding="utf-8") as f:
    f.write(f"""package com.utuvo.type.core

{kdoc}
internal object HanScriptData {{
    /** 只在簡體出現的字（{len(simplified)} 字）。 */
    const val SIMPLIFIED_ONLY = \"\"\"
{lines(simplified, "        ")}
    \"\"\"

    /** 只在繁體出現的字（{len(traditional)} 字）。 */
    const val TRADITIONAL_ONLY = \"\"\"
{lines(traditional, "        ")}
    \"\"\"
}}
""")

print(f"simplifiedOnly {len(simplified)}, traditionalOnly {len(traditional)} ({version})")

#!/usr/bin/env python3
"""從 OpenCC（Apache-2.0）原始詞典產生 iOS 用的繁中修正字典（ios/Shared/Resources/OpenCC/）。

用途：iOS 新辨識引擎（SpeechTranscriber）的繁中是逐字硬轉（回家→迴家、頭髮→頭發、干擾→幹擾），
app 端先轉回簡體（t2s）、再按詞轉台灣繁體（s2tw），見 ios/Shared/TraditionalFixer.swift。
每個詞只留第一個候選，檔案是「原詞<TAB>轉換後」。需要 Homebrew opencc（opencc_dict）。
用法：python3 scripts/build-opencc.py
"""
import os, subprocess, sys, tempfile

DICTS = ["TSPhrases", "TSCharacters", "STPhrases", "STCharacters", "TWVariants"]
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
out_dir = os.path.join(root, "ios", "Shared", "Resources", "OpenCC")
prefix = subprocess.run(["brew", "--prefix", "opencc"], capture_output=True, text=True, check=True).stdout.strip()
src = os.path.join(prefix, "share", "opencc")
version = subprocess.run(["opencc", "--version"], capture_output=True, text=True).stdout.strip().splitlines()[0]
os.makedirs(out_dir, exist_ok=True)
with tempfile.TemporaryDirectory() as tmp:
    for name in DICTS:
        raw = os.path.join(tmp, name + ".txt")
        subprocess.run(["opencc_dict", "-i", os.path.join(src, name + ".ocd2"), "-o", raw, "-f", "ocd2", "-t", "text"], check=True)
        n = 0
        with open(raw, encoding="utf-8") as fin, open(os.path.join(out_dir, name + ".txt"), "w", encoding="utf-8") as fout:
            for line in fin:
                parts = line.rstrip("\n").split("\t")
                if len(parts) < 2 or not parts[0]:
                    continue
                fout.write(parts[0] + "\t" + parts[1].split(" ")[0] + "\n")
                n += 1
        print(f"{name}: {n}")
with open(os.path.join(out_dir, "NOTICE.txt"), "w", encoding="utf-8") as f:
    f.write(f"Dictionaries derived from OpenCC ({version}), https://github.com/BYVoid/OpenCC\n"
            "Licensed under the Apache License, Version 2.0: https://www.apache.org/licenses/LICENSE-2.0\n"
            "Only the first candidate of each entry is kept.\n")

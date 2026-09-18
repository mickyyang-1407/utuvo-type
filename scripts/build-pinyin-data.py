#!/usr/bin/env python3
"""把 rime-pinyin-simp 的簡體拼音詞庫編成 iOS 鍵盤用的 `ios/Keyboard/Resources/pinyin.dat`。

用法：
    python3 scripts/build-pinyin-data.py <pinyin_simp.dict.yaml 路徑> [--output 路徑]

資料來源與授權
--------------
只用 https://github.com/rime/rime-pinyin-simp 的 `pinyin_simp.dict.yaml`（Apache-2.0；
檔頭註明衍生自 Android 開源專案 AOSP PinyinIME，亦為 Apache-2.0）。
本 repo 使用的版本見 THIRD_PARTY_NOTICES.md（記錄了 commit SHA）。
不讀、不混用任何 LGPL／GPL 詞庫。

來源格式：YAML 檔頭（到 `...` 為止）之後每行 `詞<TAB>拼音<TAB>權重`，
拼音是以空白分隔、不帶聲調的音節（例 `你好<TAB>ni hao<TAB>20728`），ü 寫成 v（`lv`、`nv`）。

權重 → 分數
-----------
權重是 AOSP PinyinIME 的詞頻（單字與詞共用同一個計數空間），轉成 log10 機率：
    score = log10((weight + 1) / (Σweight + 詞條數))
（加一平滑，讓權重 0 的罕用字也有有限分數）。Viterbi 把路徑上各段的分數相加
＝機率相乘，所以切成越多段的路徑自然吃虧，不需要另外的「段數懲罰」。
分數 × 2000 取整存成 i16（量化誤差 ≤ 0.00025，範圍約 −9…−1.6）。

過濾與排序
----------
- 拼音只接受 [a-z]+ 音節；詞的字數必須等於音節數（不符就中止，不默默丟）。
- 同一拼音下同一個詞只留權重最高的一筆。
- 同一拼音內依權重由高到低排序（同權重保留原檔順序），輸出完全決定性。

檔案格式（全部 little-endian，版本 1）
--------------------------------------
    [Header 40 bytes]
      0  magic         4 bytes  "UTPY"
      4  version       u32      1
      8  syllableCount u32      音節表筆數
     12  keyCount      u32      拼音鍵筆數
     16  entryCount    u32      詞條總數（僅供資訊）
     20  syllableTable u32      音節表的檔內位移
     24  keyIndex      u32      拼音鍵索引的檔內位移
     28  records       u32      紀錄區的檔內位移
     32  maxKeyLength  u32      最長的鍵有幾個音節（本詞庫＝4）
     36  reserved      u32      0

    [音節表] 位於 syllableTable
      (syllableCount + 1) × u32   每個音節字串在字串區內的起點（最後一筆＝字串區總長）
      字串區                      音節的 ASCII，依位元組序排序；音節 ID＝它在表中的索引。
                                  因為照字母排序，「以某字串開頭的所有音節」（例 zh → zha…zhuo）
                                  必然是一段連續的 ID 區間——縮寫與未打完的音節靠這點查詢。

    [拼音鍵索引] 位於 keyIndex
      keyCount × u32   每把鍵的紀錄相對於 records 的位移。
                       鍵依「音節 ID 序列」做字典序排序（前綴在前），所以可以二分搜尋，
                       也能用 lower bound 取出「第 k 個音節落在某個 ID 區間」的一整段鍵。

    [紀錄] 每把鍵一筆，緊密排列
      u8        n            這把鍵的音節數（1…maxKeyLength）
      n × u16   syllableIDs  音節 ID 序列
      u16       m            詞條數
      m × {
        i16     score        分數 × 2000 取整
        u8      len          詞的 UTF-8 位元組長度
        len     text         詞的 UTF-8
      }

版面與 scripts/build-zhuyin-data.py 的 zhuyin.dat 相同（只多了 maxKeyLength 欄位、magic 不同）。
繁體版 pinyin-hant.dat 由 scripts/build-pinyin-hant-data.py 以同一個格式編出（共用本檔的
encode／decode_all／write_verified）。
Swift 端（Sources/UTUVOTypeCore/Pinyin/PinyinLexicon.swift）以 mmap 開檔、原地二分搜尋，
不把整份詞庫讀進 Swift 字典（鍵盤 extension 記憶體上限約 60 MB）。
寫檔前會把產物完整解碼回來跟來源逐筆比對，不符就中止。
"""
import argparse
import math
import os
import re
import struct
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_OUTPUT = os.path.join(ROOT, 'ios', 'Keyboard', 'Resources', 'pinyin.dat')
MAGIC = b'UTPY'
VERSION = 1
HEADER_SIZE = 40
SCORE_SCALE = 2000
SYLLABLE_RE = re.compile(r'^[a-z]+$')


def load(path):
    """回傳 {拼音鍵（空白分隔）: [(詞, 權重), …]}，每把鍵內已依權重排序、去重。"""
    with open(path, encoding='utf-8') as f:
        lines = f.read().split('\n')
    try:
        body_start = lines.index('...') + 1
    except ValueError:
        sys.exit('找不到 YAML 檔頭結尾 `...`，不是 Rime dict.yaml？')

    by_key = {}
    order = 0
    for lineno, line in enumerate(lines[body_start:], start=body_start + 1):
        if not line or line.startswith('#'):
            continue
        parts = line.split('\t')
        if len(parts) != 3:
            sys.exit(f'第 {lineno} 行無法解析（需要 詞<TAB>拼音<TAB>權重）：{line!r}')
        text, code, weight = parts[0], parts[1], parts[2]
        syllables = code.split(' ')
        if any(not SYLLABLE_RE.match(s) for s in syllables):
            sys.exit(f'第 {lineno} 行拼音含非 [a-z] 音節：{code!r}')
        if len(syllables) != len(text):
            sys.exit(f'第 {lineno} 行字數與音節數不符：{text} / {code}')
        try:
            w = float(weight)
        except ValueError:
            sys.exit(f'第 {lineno} 行權重不是數字：{weight!r}')
        if w < 0:
            sys.exit(f'第 {lineno} 行權重為負：{weight!r}')
        by_key.setdefault(code, []).append((w, order, text))
        order += 1

    table = {}
    for key, items in by_key.items():
        items.sort(key=lambda t: (-t[0], t[1]))
        seen = set()
        entries = []
        for w, _, text in items:
            if text in seen:
                continue
            seen.add(text)
            entries.append((text, w))
        table[key] = entries
    return table


def to_scores(table):
    """權重 → log10 機率（加一平滑）。回傳 {鍵: [(詞, 分數), …]}。"""
    n = sum(len(v) for v in table.values())
    total = sum(w for v in table.values() for _, w in v) + n
    return {k: [(t, math.log10((w + 1) / total)) for t, w in v] for k, v in table.items()}


def encode(table):
    syllables = sorted({s for key in table for s in key.split(' ')}, key=lambda s: s.encode('ascii'))
    if len(syllables) > 0xFFFF:
        sys.exit('音節數超過 u16')
    sid = {s: i for i, s in enumerate(syllables)}

    keys = sorted(table.keys(), key=lambda k: [sid[s] for s in k.split(' ')])
    max_len = max(len(k.split(' ')) for k in keys)

    syl_blob = bytearray()
    syl_offsets = []
    for s in syllables:
        syl_offsets.append(len(syl_blob))
        syl_blob += s.encode('ascii')
    syl_offsets.append(len(syl_blob))
    syl_section = struct.pack(f'<{len(syl_offsets)}I', *syl_offsets) + bytes(syl_blob)

    records = bytearray()
    key_offsets = []
    entry_count = 0
    for key in keys:
        ids = [sid[s] for s in key.split(' ')]
        entries = table[key]
        if len(ids) > 255 or len(entries) > 0xFFFF:
            sys.exit(f'鍵太長或詞條太多：{key}')
        key_offsets.append(len(records))
        records += struct.pack(f'<B{len(ids)}HH', len(ids), *ids, len(entries))
        for text, score in entries:
            raw = text.encode('utf-8')
            q = round(score * SCORE_SCALE)
            if not (-32768 <= q <= 32767) or len(raw) > 255:
                sys.exit(f'超出格式範圍：{key} {text} {score}')
            records += struct.pack('<hB', q, len(raw)) + raw
            entry_count += 1

    syl_off = HEADER_SIZE
    key_off = syl_off + len(syl_section)
    rec_off = key_off + 4 * len(keys)
    header = MAGIC + struct.pack('<9I', VERSION, len(syllables), len(keys), entry_count,
                                 syl_off, key_off, rec_off, max_len, 0)
    assert len(header) == HEADER_SIZE
    blob = header + syl_section + struct.pack(f'<{len(keys)}I', *key_offsets) + bytes(records)
    return blob, len(syllables), len(keys), entry_count, max_len


def decode_all(blob):
    """完整解回來，跟來源逐筆比對（避免格式寫錯卻一路綠）。"""
    assert blob[:4] == MAGIC
    version, nsyl, nkey, nent, syl_off, key_off, rec_off, max_len, _ = struct.unpack_from('<9I', blob, 4)
    assert version == VERSION
    offs = struct.unpack_from(f'<{nsyl + 1}I', blob, syl_off)
    base = syl_off + 4 * (nsyl + 1)
    syllables = [blob[base + offs[i]:base + offs[i + 1]].decode('ascii') for i in range(nsyl)]
    assert syllables == sorted(syllables), '音節表沒有照字母排序'
    key_offsets = struct.unpack_from(f'<{nkey}I', blob, key_off)
    out = {}
    prev = None
    count = 0
    for ko in key_offsets:
        p = rec_off + ko
        n = blob[p]
        assert 1 <= n <= max_len
        ids = list(struct.unpack_from(f'<{n}H', blob, p + 1))
        assert prev is None or prev < ids, '鍵沒有照音節 ID 字典序排序'
        prev = ids
        p += 1 + 2 * n
        (m,) = struct.unpack_from('<H', blob, p)
        p += 2
        entries = []
        for _ in range(m):
            q, ln = struct.unpack_from('<hB', blob, p)
            p += 3
            entries.append((blob[p:p + ln].decode('utf-8'), q / SCORE_SCALE))
            p += ln
        count += m
        out[' '.join(syllables[i] for i in ids)] = entries
    assert count == nent, '詞條總數與檔頭不符'
    return out


def syllables_of(path):
    """讀一份已編好的 .dat 的音節表（build-pinyin-hant-data.py 用來檢查音節是否合法）。"""
    with open(path, 'rb') as f:
        blob = f.read()
    assert blob[:4] == MAGIC, f'{path} 不是 pinyin.dat 格式'
    return {s for key in decode_all(blob) for s in key.split(' ')}


def write_verified(table, output):
    """編碼 {鍵: [(詞, 分數), …]}（每把鍵內已依分數排序），完整解碼比對後寫檔。"""
    blob, nsyl, nkey, nent, max_len = encode(table)

    decoded = decode_all(blob)
    if decoded.keys() != table.keys():
        sys.exit('解碼後的鍵集合與來源不符')
    for key, entries in table.items():
        got = decoded[key]
        if [t for t, _ in got] != [t for t, _ in entries]:
            sys.exit(f'解碼後詞條順序不符：{key}')
        if any(abs(a[1] - b[1]) > 0.5 / SCORE_SCALE + 1e-9 for a, b in zip(got, entries)):
            sys.exit(f'解碼後分數誤差超過量化精度：{key}')

    os.makedirs(os.path.dirname(os.path.abspath(output)), exist_ok=True)
    with open(output, 'wb') as f:
        f.write(blob)
    out = os.path.abspath(output)
    shown = os.path.relpath(out, ROOT) if out.startswith(ROOT + os.sep) else out
    print(f'音節 {nsyl}、拼音鍵 {nkey}（最長 {max_len} 音節）、詞條 {nent}；寫出 {len(blob):,} bytes → {shown}')


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('dict_yaml', help='rime-pinyin-simp 的 pinyin_simp.dict.yaml')
    ap.add_argument('--output', default=DEFAULT_OUTPUT)
    args = ap.parse_args()
    write_verified(to_scores(load(args.dict_yaml)), args.output)


if __name__ == '__main__':
    main()

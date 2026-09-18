#!/usr/bin/env python3
"""把小麥注音（McBopomofo，MIT）的詞庫編成 iOS 鍵盤用的 `ios/Keyboard/Resources/zhuyin.dat`。

用法：
    python3 scripts/build-zhuyin-data.py <McBopomofo 的 Source/Data 目錄> [--output 路徑] [--rebuild]

資料來源與授權
--------------
只用 McBopomofo 的 Source/Data（MIT；其中 BPMFMappings.txt 的詞表源自 libtabe tsi.src，BSD）。
分數不自己發明：直接跑 McBopomofo 自己的編譯流程（`make data.txt`，純 Python、可離線），
取它產出的 `data.txt`——也就是小麥注音執行期實際用的「讀音 詞 分數」表
（分數＝以 phrase.occ 計數正規化後取 log10、並經破音字與 Postprocess 規則調整）。
data.txt 已存在且沒有 --rebuild 時直接沿用。授權全文見 repo 根目錄 THIRD_PARTY_NOTICES.md。

過濾規則
--------
- 丟掉 `_` 開頭的鍵（標點／控制鍵對應，鍵盤 UI 自己處理標點）。
- 丟掉 `MACRO@` 值（日期時間巨集，需要執行期展開）。
- 同一讀音下同一個詞只留分數最高的一筆（等同 McBopomofoLM 的 insertedValues 去重）。
- 同一讀音內依分數由高到低排序（同分保留原檔順序）。

檔案格式（全部 little-endian，版本 1）
--------------------------------------
    [Header 32 bytes]
      0  magic         4 bytes  "UTZY"
      4  version       u32      1
      8  syllableCount u32      音節表筆數
     12  keyCount      u32      讀音鍵筆數
     16  entryCount    u32      詞條總數（僅供資訊）
     20  syllableTable u32      音節表的檔內位移
     24  keyIndex      u32      讀音鍵索引的檔內位移
     28  records       u32      紀錄區的檔內位移

    [音節表] 位於 syllableTable
      (syllableCount + 1) × u32   每個音節字串在字串區內的起點（最後一筆＝字串區總長）
      字串區                      音節的 UTF-8，依 UTF-8 位元組序排序；音節 ID＝它在表中的索引

    [讀音鍵索引] 位於 keyIndex
      keyCount × u32   每把讀音鍵的紀錄相對於 records 的位移。
                       鍵依「音節 ID 序列」做字典序排序（前綴在前），所以可以二分搜尋，
                       也能用 lower bound 判斷「有沒有以某段讀音開頭的詞」。

    [紀錄] 每把鍵一筆，緊密排列
      u8        n            這把鍵的音節數（1…9）
      n × u16   syllableIDs  音節 ID 序列
      u16       m            詞條數
      m × {
        i16     score        分數 × 2000 取整（log10 機率，範圍約 −8…−1.8）
        u8      len          詞的 UTF-8 位元組長度
        len     text         詞的 UTF-8
      }

鍵在概念上就是 McBopomofo 的「以 - 連接的讀音」（例：ㄋㄧˇ-ㄏㄠˇ）；
檔案裡把每個音節換成 u16 ID 存，省空間也省比對時間。
Swift 端（Sources/UTUVOTypeCore/Zhuyin/ZhuyinLexicon.swift）以 mmap 開檔、原地二分搜尋，
不把整份詞庫讀進 Swift 字典（鍵盤 extension 記憶體上限約 60 MB）。
"""
import argparse
import os
import struct
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_OUTPUT = os.path.join(ROOT, 'ios', 'Keyboard', 'Resources', 'zhuyin.dat')
MAGIC = b'UTZY'
VERSION = 1
SCORE_SCALE = 2000
BOPOMOFO = set('ㄅㄆㄇㄈㄉㄊㄋㄌㄍㄎㄏㄐㄑㄒㄓㄔㄕㄖㄗㄘㄙㄧㄨㄩㄚㄛㄜㄝㄞㄟㄠㄡㄢㄣㄤㄥㄦˊˇˋ˙')


def build_data_txt(data_dir, rebuild):
    path = os.path.join(data_dir, 'data.txt')
    if rebuild or not os.path.exists(path):
        # McBopomofo 自己的編譯流程（純 Python，不需網路）
        subprocess.run(['make', 'data.txt'], cwd=data_dir, check=True)
    return path


def load(path):
    by_key = {}
    order = 0
    with open(path, encoding='utf-8') as f:
        for line in f:
            line = line.rstrip('\n')
            if not line or line.startswith('#'):
                continue
            parts = line.split(' ')
            if len(parts) != 3:
                sys.exit(f'無法解析的行：{line!r}')
            key, text, score = parts[0], parts[1], float(parts[2])
            if key.startswith('_') or text.startswith('MACRO@'):
                continue
            syllables = key.split('-')
            if any(not s or any(ch not in BOPOMOFO for ch in s) for s in syllables):
                sys.exit(f'讀音含非注音字元：{key!r}')
            by_key.setdefault(key, []).append((score, order, text))
            order += 1
    result = {}
    for key, items in by_key.items():
        items.sort(key=lambda t: (-t[0], t[1]))
        seen = set()
        entries = []
        for score, _, text in items:
            if text in seen:
                continue
            seen.add(text)
            entries.append((text, score))
        result[key] = entries
    return result


def encode(table):
    syllables = sorted({s for key in table for s in key.split('-')}, key=lambda s: s.encode('utf-8'))
    if len(syllables) > 0xFFFF:
        sys.exit('音節數超過 u16')
    sid = {s: i for i, s in enumerate(syllables)}

    keys = sorted(table.keys(), key=lambda k: [sid[s] for s in k.split('-')])

    # 音節表
    syl_blob = bytearray()
    syl_offsets = []
    for s in syllables:
        syl_offsets.append(len(syl_blob))
        syl_blob += s.encode('utf-8')
    syl_offsets.append(len(syl_blob))
    syl_section = struct.pack(f'<{len(syl_offsets)}I', *syl_offsets) + bytes(syl_blob)

    # 紀錄
    records = bytearray()
    key_offsets = []
    entry_count = 0
    for key in keys:
        ids = [sid[s] for s in key.split('-')]
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

    header_size = 32
    syl_off = header_size
    key_off = syl_off + len(syl_section)
    rec_off = key_off + 4 * len(keys)
    header = MAGIC + struct.pack('<7I', VERSION, len(syllables), len(keys), entry_count, syl_off, key_off, rec_off)
    blob = header + syl_section + struct.pack(f'<{len(keys)}I', *key_offsets) + bytes(records)
    return blob, len(syllables), len(keys), entry_count


def decode_all(blob):
    """完整解回來，跟來源逐筆比對（避免格式寫錯卻一路綠）。"""
    assert blob[:4] == MAGIC
    version, nsyl, nkey, nent, syl_off, key_off, rec_off = struct.unpack_from('<7I', blob, 4)
    assert version == VERSION
    offs = struct.unpack_from(f'<{nsyl + 1}I', blob, syl_off)
    base = syl_off + 4 * (nsyl + 1)
    syllables = [blob[base + offs[i]:base + offs[i + 1]].decode('utf-8') for i in range(nsyl)]
    key_offsets = struct.unpack_from(f'<{nkey}I', blob, key_off)
    out = {}
    prev = None
    for ko in key_offsets:
        p = rec_off + ko
        n = blob[p]
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
        out['-'.join(syllables[i] for i in ids)] = entries
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('data_dir', help='McBopomofo 的 Source/Data 目錄')
    ap.add_argument('--output', default=DEFAULT_OUTPUT)
    ap.add_argument('--rebuild', action='store_true', help='強制重跑 McBopomofo 的 make data.txt')
    args = ap.parse_args()

    data_txt = build_data_txt(os.path.abspath(args.data_dir), args.rebuild)
    table = load(data_txt)
    blob, nsyl, nkey, nent = encode(table)

    decoded = decode_all(blob)
    if decoded.keys() != table.keys():
        sys.exit('解碼後的鍵集合與來源不符')
    for key, entries in table.items():
        got = decoded[key]
        if [t for t, _ in got] != [t for t, _ in entries]:
            sys.exit(f'解碼後詞條順序不符：{key}')
        if any(abs(a[1] - b[1]) > 0.5 / SCORE_SCALE + 1e-9 for a, b in zip(got, entries)):
            sys.exit(f'解碼後分數誤差超過量化精度：{key}')

    os.makedirs(os.path.dirname(os.path.abspath(args.output)), exist_ok=True)
    with open(args.output, 'wb') as f:
        f.write(blob)
    print(f'音節 {nsyl}、讀音鍵 {nkey}、詞條 {nent}；寫出 {len(blob):,} bytes → {os.path.relpath(args.output, ROOT)}')


if __name__ == '__main__':
    main()

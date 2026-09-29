#!/usr/bin/env python3
"""編出 iOS 鍵盤「聯想詞」（選字後接著建議下一段）用的 `assoc-hant.dat`／`assoc-hans.dat`。

用法：
    python3 scripts/build-association-data.py <McBopomofo 的 Source/Data 目錄> \
        [--rime <pinyin_simp.dict.yaml>] [--output-dir 路徑] [--rebuild]

資料來源與授權（不自己發明任何頻率）
------------------------------------
- 繁體（注音、繁體拼音共用）：直接用小麥注音 McBopomofo（MIT）自己產的
  `associated-phrases-v2.txt`（`make associated-phrases-v2.txt`，純 Python、可離線）——
  就是小麥注音執行期實際用的聯想詞表：從 data.txt 取「每個字都是 Unicode Lo 類、2 字以上、
  分數 > −8（排除 emoji 等符號）」的詞，依「首字＋首字讀音」分組、每組取分數最高的 60 個。
  分數＝小麥注音 data.txt 的 log10 機率，原樣沿用。
- 簡體：rime-pinyin-simp（Apache-2.0）沒有聯想詞表。用**同一條規則**推導：
  直接 import 小麥注音的 `curation.builders.phrase_deriver`（Entry 的過濾與 MAX_ENTRIES_PER_PREFIX），
  詞與分數則 import 本 repo `build-pinyin-data.py` 的 `load`／`to_scores`（與 pinyin.dat 同一份分數），
  不另寫一套過濾或計分。
兩份都只含原資料裡本來就有的詞；本腳本只做「拆掉讀音、同詞留最高分、重新編碼」。

查詢方式（Swift 端 Sources/UTUVOTypeCore/Prediction/PhraseAssociations.swift）
-----------------------------------------------------------------------------
詞依 UTF-8 位元組序排序；給一段剛送出的文字（例「你好」），以二分搜尋找到所有以它開頭、
且比它長的詞（例「你好嗎」），剩下的部分（「嗎」）就是聯想候選，依分數排序。

檔案格式（全部 little-endian，版本 1）
--------------------------------------
    [Header 20 bytes]
      0  magic         4 bytes  "UTAS"
      4  version       u32      1
      8  count         u32      詞數
     12  index         u32      索引的檔內位移
     16  records       u32      紀錄區的檔內位移
    [索引] count × u32：每筆紀錄相對於 records 的位移（依詞的 UTF-8 位元組序）
    [紀錄] i16 score（log10 × 2000 取整）、u8 len、len bytes UTF-8
"""
import argparse
import importlib.util
import os
import struct
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_OUTPUT_DIR = os.path.join(ROOT, 'ios', 'Keyboard', 'Resources')
MAGIC = b'UTAS'
VERSION = 1
HEADER_SIZE = 20
SCORE_SCALE = 2000
PRAGMA = '# format org.openvanilla.mcbopomofo.sorted'


def import_phrase_deriver(data_dir):
    """小麥注音自己的聯想詞推導模組（過濾規則的唯一正本）。"""
    sys.path.insert(0, data_dir)
    try:
        from curation.builders import phrase_deriver
    finally:
        sys.path.pop(0)
    return phrase_deriver


def import_pinyin_builder():
    """本 repo 的 build-pinyin-data.py（檔名有連字號，用 spec 載入）。"""
    path = os.path.join(ROOT, 'scripts', 'build-pinyin-data.py')
    spec = importlib.util.spec_from_file_location('build_pinyin_data', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def hant_phrases(data_dir, rebuild):
    """解析小麥注音的 associated-phrases-v2.txt → {詞: 最高分}。"""
    path = os.path.join(data_dir, 'associated-phrases-v2.txt')
    if rebuild or not os.path.exists(path):
        subprocess.run(['make', 'associated-phrases-v2.txt'], cwd=data_dir, check=True)
    phrases = {}
    with open(path, encoding='utf-8') as f:
        if f.readline().strip() != PRAGMA:
            sys.exit(f'{path} 不是預期的 McBopomofo 排序格式')
        for line in f:
            line = line.rstrip('\n')
            if not line or '_punctuation' in line:   # 標點聯想（例「〈」→「〉」）由鍵盤自己處理
                continue
            key, score = line.rsplit(' ', 1)
            parts = key.split('-')
            if len(parts) % 2:
                sys.exit(f'無法解析的聯想詞行：{line!r}')
            text = ''.join(parts[0::2])
            if len(text) != len(parts) // 2:
                sys.exit(f'聯想詞的字與讀音數不符：{line!r}')
            s = float(score)
            if s > phrases.get(text, -1e9):
                phrases[text] = s
    return phrases


def hans_phrases(data_dir, rime_path):
    """rime-pinyin-simp 的詞，套小麥注音 phrase_deriver 的同一條規則 → {詞: 最高分}。"""
    deriver = import_phrase_deriver(data_dir)
    pinyin = import_pinyin_builder()
    table = pinyin.to_scores(pinyin.load(rime_path))   # {「ni hao」: [(詞, log10 分數), ...]}
    groups = {}
    for key, entries in table.items():
        reading = key.replace(' ', '-')
        for text, score in entries:
            e = deriver.Entry(reading, text, score)
            rvs = e.zipped_readings_and_values()
            if not rvs or len(rvs) < 2:
                continue
            groups.setdefault(f'{rvs[0][1]}-{rvs[0][0]}', []).append(e)
    phrases = {}
    for entries in groups.values():
        entries.sort(key=lambda e: e.score, reverse=True)
        for e in entries[:deriver.MAX_ENTRIES_PER_PREFIX]:
            if e.score > phrases.get(e.value, -1e9):
                phrases[e.value] = e.score
    return phrases


def encode(phrases):
    items = sorted(phrases.items(), key=lambda kv: kv[0].encode('utf-8'))
    records = bytearray()
    offsets = []
    for text, score in items:
        raw = text.encode('utf-8')
        if len(raw) > 255:
            continue
        q = round(score * SCORE_SCALE)
        if not -32768 <= q <= 32767:
            sys.exit(f'分數超出 i16：{text} {score}')
        offsets.append(len(records))
        records += struct.pack('<hB', q, len(raw)) + raw
    index_off = HEADER_SIZE
    records_off = index_off + 4 * len(offsets)
    header = MAGIC + struct.pack('<IIII', VERSION, len(offsets), index_off, records_off)
    return header + struct.pack(f'<{len(offsets)}I', *offsets) + bytes(records), len(offsets)


def decode(blob):
    """反向解碼（寫檔後自我驗證用）。"""
    assert blob[:4] == MAGIC
    _, count, index_off, records_off = struct.unpack_from('<IIII', blob, 4)
    out = {}
    for i in range(count):
        p = records_off + struct.unpack_from('<I', blob, index_off + 4 * i)[0]
        q, n = struct.unpack_from('<hB', blob, p)
        out[blob[p + 3:p + 3 + n].decode('utf-8')] = q / SCORE_SCALE
    return out


def write_verified(phrases, output):
    blob, count = encode(phrases)
    back = decode(blob)
    if set(back) != set(phrases) or any(abs(back[k] - phrases[k]) > 0.5 / SCORE_SCALE for k in back):
        sys.exit('自我驗證失敗：解碼結果與來源不符')
    keys = list(back)
    if keys != sorted(keys, key=lambda k: k.encode('utf-8')):
        sys.exit('自我驗證失敗：沒有依 UTF-8 位元組序排序')
    tmp = output + '.tmp'
    with open(tmp, 'wb') as f:
        f.write(blob)
    os.replace(tmp, output)
    print(f'聯想詞 {count} 筆；寫出 {len(blob):,} bytes → {output}')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('data_dir', help='McBopomofo 的 Source/Data 目錄')
    ap.add_argument('--rime', help='rime-pinyin-simp 的 pinyin_simp.dict.yaml（給了才編簡體）')
    ap.add_argument('--output-dir', default=DEFAULT_OUTPUT_DIR)
    ap.add_argument('--rebuild', action='store_true', help='重跑 McBopomofo 的 make')
    args = ap.parse_args()
    write_verified(hant_phrases(args.data_dir, args.rebuild), os.path.join(args.output_dir, 'assoc-hant.dat'))
    if args.rime:
        write_verified(hans_phrases(args.data_dir, args.rime), os.path.join(args.output_dir, 'assoc-hans.dat'))


if __name__ == '__main__':
    main()

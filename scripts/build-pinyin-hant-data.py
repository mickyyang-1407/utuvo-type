#!/usr/bin/env python3
"""把小麥注音（McBopomofo，MIT）的繁體詞庫轉成拼音鍵，編成 `ios/Keyboard/Resources/pinyin-hant.dat`。

用法：
    python3 scripts/build-pinyin-hant-data.py <McBopomofo 的 Source/Data 目錄> [--output 路徑] [--rebuild]

讓繁體也能用拼音打：跟 zhuyin.dat 同一份資料來源（McBopomofo Source/Data，MIT；多字詞表源自
libtabe，BSD；授權見 THIRD_PARTY_NOTICES.md），不引入新的授權。
檔案格式與 pinyin.dat 完全相同（見 scripts/build-pinyin-data.py 檔頭），同一個
PinyinLexicon／PinyinEngine 直接開。

流程
----
1. 取 McBopomofo 自己編出的 data.txt（`make data.txt`；與 build-zhuyin-data.py 共用同一段程式，
   同樣丟掉 `_` 開頭的標點鍵與 MACRO@ 值）。分數沿用小麥注音的 log10 機率，不另外換算。
2. 丟掉詞本身含注音符號的條目（例：讀音 ㄅ → 詞「ㄅ」，那是符號表，不是字）。
3. 每個注音音節去掉聲調後，用下方 `BOPOMOFO_TO_PINYIN` 表轉成不帶調的漢語拼音（ü 寫 v）。
   表以外的讀音只允許出現在 `SKIPPED_READINGS`（該條目整筆丟掉並計數），其他一律中止——
   不默默丟資料。
4. 去掉聲調後同一拼音鍵下同一個詞可能出現多次（例 你 ㄋㄧˇ 與破音），只留最高分。
   同一鍵內依分數由高到低排序（同分保留原檔順序），輸出完全決定性。

對照表的慣例（刻意的選擇）
--------------------------
- 零聲母依拼音正字法：ㄧ→yi、ㄨ→wu、ㄩ→yu、ㄧㄡ→you、ㄨㄟ→wei、ㄩㄝ→yue、ㄩㄢ→yuan、ㄩㄣ→yun、ㄩㄥ→yong。
- ㄐㄑㄒ 後的 ㄩ 寫 u（ju、que、xuan、jun），ㄋㄌ 後寫 v（nv、lv）；ㄋㄩㄝ／ㄌㄩㄝ 寫 nue／lue，
  與 rime-pinyin-simp 的 pinyin.dat 一致（打 nve／lve 由引擎的別名接住）。
- ㄓㄔㄕㄖㄗㄘㄙ 單獨成音節 → zhi chi shi ri zi ci si；ㄦ → er。
- ㄨㄥ 接聲母寫 ong（dong、zhong），零聲母寫 weng；ㄩㄥ 接 ㄐㄑㄒ 寫 iong。
- ㄝ 單獨成音節（誒）拼成 ei，與 ㄟ 合併——拼音鍵盤沒有 ê 鍵，使用者打的是 ei。
- 臺灣讀音裡 pinyin.dat 沒有的音節照實拼出（見 `TAIWAN_ONLY_SYLLABLES`），例 ㄧㄞ→yai（崖）。
"""
import argparse
import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def _load_sibling(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), os.path.join(HERE, name + '.py'))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


pinyin_data = _load_sibling('build-pinyin-data')
zhuyin_data = _load_sibling('build-zhuyin-data')

DEFAULT_OUTPUT = os.path.join(pinyin_data.ROOT, 'ios', 'Keyboard', 'Resources', 'pinyin-hant.dat')
SIMP_DAT = os.path.join(pinyin_data.ROOT, 'ios', 'Keyboard', 'Resources', 'pinyin.dat')
TONES = 'ˊˇˋ˙'
BOPOMOFO_CHARS = set('ㄅㄆㄇㄈㄉㄊㄋㄌㄍㄎㄏㄐㄑㄒㄓㄔㄕㄖㄗㄘㄙㄧㄨㄩㄚㄛㄜㄝㄞㄟㄠㄡㄢㄣㄤㄥㄦ')

# 不帶聲調的注音音節 → 不帶調漢語拼音。依聲母分行，逐條人工核對過。
BOPOMOFO_TO_PINYIN = {
    # ㄅ
    'ㄅㄚ': 'ba', 'ㄅㄛ': 'bo', 'ㄅㄞ': 'bai', 'ㄅㄟ': 'bei', 'ㄅㄠ': 'bao', 'ㄅㄢ': 'ban', 'ㄅㄣ': 'ben',
    'ㄅㄤ': 'bang', 'ㄅㄥ': 'beng', 'ㄅㄧ': 'bi', 'ㄅㄧㄝ': 'bie', 'ㄅㄧㄠ': 'biao', 'ㄅㄧㄢ': 'bian',
    'ㄅㄧㄣ': 'bin', 'ㄅㄧㄤ': 'biang', 'ㄅㄧㄥ': 'bing', 'ㄅㄨ': 'bu',
    # ㄆ
    'ㄆㄚ': 'pa', 'ㄆㄛ': 'po', 'ㄆㄞ': 'pai', 'ㄆㄟ': 'pei', 'ㄆㄠ': 'pao', 'ㄆㄡ': 'pou', 'ㄆㄢ': 'pan',
    'ㄆㄣ': 'pen', 'ㄆㄤ': 'pang', 'ㄆㄥ': 'peng', 'ㄆㄧ': 'pi', 'ㄆㄧㄚ': 'pia', 'ㄆㄧㄝ': 'pie',
    'ㄆㄧㄠ': 'piao', 'ㄆㄧㄢ': 'pian', 'ㄆㄧㄣ': 'pin', 'ㄆㄧㄥ': 'ping', 'ㄆㄨ': 'pu',
    # ㄇ
    'ㄇㄚ': 'ma', 'ㄇㄛ': 'mo', 'ㄇㄜ': 'me', 'ㄇㄞ': 'mai', 'ㄇㄟ': 'mei', 'ㄇㄠ': 'mao', 'ㄇㄡ': 'mou',
    'ㄇㄢ': 'man', 'ㄇㄣ': 'men', 'ㄇㄤ': 'mang', 'ㄇㄥ': 'meng', 'ㄇㄧ': 'mi', 'ㄇㄧㄝ': 'mie',
    'ㄇㄧㄠ': 'miao', 'ㄇㄧㄡ': 'miu', 'ㄇㄧㄢ': 'mian', 'ㄇㄧㄣ': 'min', 'ㄇㄧㄥ': 'ming', 'ㄇㄨ': 'mu',
    # ㄈ
    'ㄈㄚ': 'fa', 'ㄈㄛ': 'fo', 'ㄈㄟ': 'fei', 'ㄈㄡ': 'fou', 'ㄈㄢ': 'fan', 'ㄈㄣ': 'fen', 'ㄈㄤ': 'fang',
    'ㄈㄥ': 'feng', 'ㄈㄧㄠ': 'fiao', 'ㄈㄨ': 'fu',
    # ㄉ
    'ㄉㄚ': 'da', 'ㄉㄜ': 'de', 'ㄉㄞ': 'dai', 'ㄉㄟ': 'dei', 'ㄉㄠ': 'dao', 'ㄉㄡ': 'dou', 'ㄉㄢ': 'dan',
    'ㄉㄣ': 'den', 'ㄉㄤ': 'dang', 'ㄉㄥ': 'deng', 'ㄉㄧ': 'di', 'ㄉㄧㄚ': 'dia', 'ㄉㄧㄝ': 'die',
    'ㄉㄧㄠ': 'diao', 'ㄉㄧㄡ': 'diu', 'ㄉㄧㄢ': 'dian', 'ㄉㄧㄥ': 'ding', 'ㄉㄨ': 'du', 'ㄉㄨㄛ': 'duo',
    'ㄉㄨㄟ': 'dui', 'ㄉㄨㄢ': 'duan', 'ㄉㄨㄣ': 'dun', 'ㄉㄨㄥ': 'dong',
    # ㄊ
    'ㄊㄚ': 'ta', 'ㄊㄜ': 'te', 'ㄊㄞ': 'tai', 'ㄊㄟ': 'tei', 'ㄊㄠ': 'tao', 'ㄊㄡ': 'tou', 'ㄊㄢ': 'tan',
    'ㄊㄤ': 'tang', 'ㄊㄥ': 'teng', 'ㄊㄧ': 'ti', 'ㄊㄧㄝ': 'tie', 'ㄊㄧㄠ': 'tiao', 'ㄊㄧㄢ': 'tian',
    'ㄊㄧㄥ': 'ting', 'ㄊㄨ': 'tu', 'ㄊㄨㄛ': 'tuo', 'ㄊㄨㄟ': 'tui', 'ㄊㄨㄢ': 'tuan', 'ㄊㄨㄣ': 'tun',
    'ㄊㄨㄥ': 'tong',
    # ㄋ
    'ㄋㄚ': 'na', 'ㄋㄜ': 'ne', 'ㄋㄞ': 'nai', 'ㄋㄟ': 'nei', 'ㄋㄠ': 'nao', 'ㄋㄡ': 'nou', 'ㄋㄢ': 'nan',
    'ㄋㄣ': 'nen', 'ㄋㄤ': 'nang', 'ㄋㄥ': 'neng', 'ㄋㄧ': 'ni', 'ㄋㄧㄝ': 'nie', 'ㄋㄧㄠ': 'niao',
    'ㄋㄧㄡ': 'niu', 'ㄋㄧㄢ': 'nian', 'ㄋㄧㄣ': 'nin', 'ㄋㄧㄤ': 'niang', 'ㄋㄧㄥ': 'ning', 'ㄋㄨ': 'nu',
    'ㄋㄨㄛ': 'nuo', 'ㄋㄨㄢ': 'nuan', 'ㄋㄨㄣ': 'nun', 'ㄋㄨㄥ': 'nong', 'ㄋㄩ': 'nv', 'ㄋㄩㄝ': 'nue',
    # ㄌ
    'ㄌㄚ': 'la', 'ㄌㄛ': 'lo', 'ㄌㄜ': 'le', 'ㄌㄞ': 'lai', 'ㄌㄟ': 'lei', 'ㄌㄠ': 'lao', 'ㄌㄡ': 'lou',
    'ㄌㄢ': 'lan', 'ㄌㄤ': 'lang', 'ㄌㄥ': 'leng', 'ㄌㄧ': 'li', 'ㄌㄧㄚ': 'lia', 'ㄌㄧㄝ': 'lie',
    'ㄌㄧㄠ': 'liao', 'ㄌㄧㄡ': 'liu', 'ㄌㄧㄢ': 'lian', 'ㄌㄧㄣ': 'lin', 'ㄌㄧㄤ': 'liang', 'ㄌㄧㄥ': 'ling',
    'ㄌㄨ': 'lu', 'ㄌㄨㄛ': 'luo', 'ㄌㄨㄢ': 'luan', 'ㄌㄨㄣ': 'lun', 'ㄌㄨㄥ': 'long', 'ㄌㄩ': 'lv',
    'ㄌㄩㄝ': 'lue', 'ㄌㄩㄢ': 'lvan',
    # ㄍ
    'ㄍㄚ': 'ga', 'ㄍㄜ': 'ge', 'ㄍㄞ': 'gai', 'ㄍㄟ': 'gei', 'ㄍㄠ': 'gao', 'ㄍㄡ': 'gou', 'ㄍㄢ': 'gan',
    'ㄍㄣ': 'gen', 'ㄍㄤ': 'gang', 'ㄍㄥ': 'geng', 'ㄍㄨ': 'gu', 'ㄍㄨㄚ': 'gua', 'ㄍㄨㄛ': 'guo',
    'ㄍㄨㄞ': 'guai', 'ㄍㄨㄟ': 'gui', 'ㄍㄨㄢ': 'guan', 'ㄍㄨㄣ': 'gun', 'ㄍㄨㄤ': 'guang', 'ㄍㄨㄥ': 'gong',
    # ㄎ
    'ㄎㄚ': 'ka', 'ㄎㄜ': 'ke', 'ㄎㄞ': 'kai', 'ㄎㄟ': 'kei', 'ㄎㄠ': 'kao', 'ㄎㄡ': 'kou', 'ㄎㄢ': 'kan',
    'ㄎㄣ': 'ken', 'ㄎㄤ': 'kang', 'ㄎㄥ': 'keng', 'ㄎㄨ': 'ku', 'ㄎㄨㄚ': 'kua', 'ㄎㄨㄛ': 'kuo',
    'ㄎㄨㄞ': 'kuai', 'ㄎㄨㄟ': 'kui', 'ㄎㄨㄢ': 'kuan', 'ㄎㄨㄣ': 'kun', 'ㄎㄨㄤ': 'kuang', 'ㄎㄨㄥ': 'kong',
    # ㄏ
    'ㄏㄚ': 'ha', 'ㄏㄜ': 'he', 'ㄏㄞ': 'hai', 'ㄏㄟ': 'hei', 'ㄏㄠ': 'hao', 'ㄏㄡ': 'hou', 'ㄏㄢ': 'han',
    'ㄏㄣ': 'hen', 'ㄏㄤ': 'hang', 'ㄏㄥ': 'heng', 'ㄏㄨ': 'hu', 'ㄏㄨㄚ': 'hua', 'ㄏㄨㄛ': 'huo',
    'ㄏㄨㄞ': 'huai', 'ㄏㄨㄟ': 'hui', 'ㄏㄨㄢ': 'huan', 'ㄏㄨㄣ': 'hun', 'ㄏㄨㄤ': 'huang', 'ㄏㄨㄥ': 'hong',
    # ㄐ
    'ㄐㄧ': 'ji', 'ㄐㄧㄚ': 'jia', 'ㄐㄧㄝ': 'jie', 'ㄐㄧㄠ': 'jiao', 'ㄐㄧㄡ': 'jiu', 'ㄐㄧㄢ': 'jian',
    'ㄐㄧㄣ': 'jin', 'ㄐㄧㄤ': 'jiang', 'ㄐㄧㄥ': 'jing', 'ㄐㄩ': 'ju', 'ㄐㄩㄝ': 'jue', 'ㄐㄩㄢ': 'juan',
    'ㄐㄩㄣ': 'jun', 'ㄐㄩㄥ': 'jiong',
    # ㄑ
    'ㄑㄧ': 'qi', 'ㄑㄧㄚ': 'qia', 'ㄑㄧㄝ': 'qie', 'ㄑㄧㄠ': 'qiao', 'ㄑㄧㄡ': 'qiu', 'ㄑㄧㄢ': 'qian',
    'ㄑㄧㄣ': 'qin', 'ㄑㄧㄤ': 'qiang', 'ㄑㄧㄥ': 'qing', 'ㄑㄩ': 'qu', 'ㄑㄩㄝ': 'que', 'ㄑㄩㄢ': 'quan',
    'ㄑㄩㄣ': 'qun', 'ㄑㄩㄥ': 'qiong',
    # ㄒ
    'ㄒㄧ': 'xi', 'ㄒㄧㄚ': 'xia', 'ㄒㄧㄝ': 'xie', 'ㄒㄧㄠ': 'xiao', 'ㄒㄧㄡ': 'xiu', 'ㄒㄧㄢ': 'xian',
    'ㄒㄧㄣ': 'xin', 'ㄒㄧㄤ': 'xiang', 'ㄒㄧㄥ': 'xing', 'ㄒㄩ': 'xu', 'ㄒㄩㄝ': 'xue', 'ㄒㄩㄢ': 'xuan',
    'ㄒㄩㄣ': 'xun', 'ㄒㄩㄥ': 'xiong',
    # ㄓ
    'ㄓ': 'zhi', 'ㄓㄚ': 'zha', 'ㄓㄜ': 'zhe', 'ㄓㄞ': 'zhai', 'ㄓㄟ': 'zhei', 'ㄓㄠ': 'zhao', 'ㄓㄡ': 'zhou',
    'ㄓㄢ': 'zhan', 'ㄓㄣ': 'zhen', 'ㄓㄤ': 'zhang', 'ㄓㄥ': 'zheng', 'ㄓㄨ': 'zhu', 'ㄓㄨㄚ': 'zhua',
    'ㄓㄨㄛ': 'zhuo', 'ㄓㄨㄞ': 'zhuai', 'ㄓㄨㄟ': 'zhui', 'ㄓㄨㄢ': 'zhuan', 'ㄓㄨㄣ': 'zhun',
    'ㄓㄨㄤ': 'zhuang', 'ㄓㄨㄥ': 'zhong',
    # ㄔ
    'ㄔ': 'chi', 'ㄔㄚ': 'cha', 'ㄔㄜ': 'che', 'ㄔㄞ': 'chai', 'ㄔㄠ': 'chao', 'ㄔㄡ': 'chou', 'ㄔㄢ': 'chan',
    'ㄔㄣ': 'chen', 'ㄔㄤ': 'chang', 'ㄔㄥ': 'cheng', 'ㄔㄨ': 'chu', 'ㄔㄨㄚ': 'chua', 'ㄔㄨㄛ': 'chuo',
    'ㄔㄨㄞ': 'chuai', 'ㄔㄨㄟ': 'chui', 'ㄔㄨㄢ': 'chuan', 'ㄔㄨㄣ': 'chun', 'ㄔㄨㄤ': 'chuang',
    'ㄔㄨㄥ': 'chong',
    # ㄕ
    'ㄕ': 'shi', 'ㄕㄚ': 'sha', 'ㄕㄜ': 'she', 'ㄕㄞ': 'shai', 'ㄕㄟ': 'shei', 'ㄕㄠ': 'shao', 'ㄕㄡ': 'shou',
    'ㄕㄢ': 'shan', 'ㄕㄣ': 'shen', 'ㄕㄤ': 'shang', 'ㄕㄥ': 'sheng', 'ㄕㄨ': 'shu', 'ㄕㄨㄚ': 'shua',
    'ㄕㄨㄛ': 'shuo', 'ㄕㄨㄞ': 'shuai', 'ㄕㄨㄟ': 'shui', 'ㄕㄨㄢ': 'shuan', 'ㄕㄨㄣ': 'shun',
    'ㄕㄨㄤ': 'shuang',
    # ㄖ
    'ㄖ': 'ri', 'ㄖㄜ': 're', 'ㄖㄠ': 'rao', 'ㄖㄡ': 'rou', 'ㄖㄢ': 'ran', 'ㄖㄣ': 'ren', 'ㄖㄤ': 'rang',
    'ㄖㄥ': 'reng', 'ㄖㄨ': 'ru', 'ㄖㄨㄚ': 'rua', 'ㄖㄨㄛ': 'ruo', 'ㄖㄨㄟ': 'rui', 'ㄖㄨㄢ': 'ruan',
    'ㄖㄨㄣ': 'run', 'ㄖㄨㄥ': 'rong',
    # ㄗ
    'ㄗ': 'zi', 'ㄗㄚ': 'za', 'ㄗㄜ': 'ze', 'ㄗㄞ': 'zai', 'ㄗㄟ': 'zei', 'ㄗㄠ': 'zao', 'ㄗㄡ': 'zou',
    'ㄗㄢ': 'zan', 'ㄗㄣ': 'zen', 'ㄗㄤ': 'zang', 'ㄗㄥ': 'zeng', 'ㄗㄨ': 'zu', 'ㄗㄨㄛ': 'zuo', 'ㄗㄨㄟ': 'zui',
    'ㄗㄨㄢ': 'zuan', 'ㄗㄨㄣ': 'zun', 'ㄗㄨㄥ': 'zong',
    # ㄘ
    'ㄘ': 'ci', 'ㄘㄚ': 'ca', 'ㄘㄜ': 'ce', 'ㄘㄞ': 'cai', 'ㄘㄠ': 'cao', 'ㄘㄡ': 'cou', 'ㄘㄢ': 'can',
    'ㄘㄣ': 'cen', 'ㄘㄤ': 'cang', 'ㄘㄥ': 'ceng', 'ㄘㄨ': 'cu', 'ㄘㄨㄛ': 'cuo', 'ㄘㄨㄟ': 'cui',
    'ㄘㄨㄢ': 'cuan', 'ㄘㄨㄣ': 'cun', 'ㄘㄨㄥ': 'cong',
    # ㄙ
    'ㄙ': 'si', 'ㄙㄚ': 'sa', 'ㄙㄜ': 'se', 'ㄙㄞ': 'sai', 'ㄙㄟ': 'sei', 'ㄙㄠ': 'sao', 'ㄙㄡ': 'sou',
    'ㄙㄢ': 'san', 'ㄙㄣ': 'sen', 'ㄙㄤ': 'sang', 'ㄙㄥ': 'seng', 'ㄙㄨ': 'su', 'ㄙㄨㄛ': 'suo', 'ㄙㄨㄟ': 'sui',
    'ㄙㄨㄢ': 'suan', 'ㄙㄨㄣ': 'sun', 'ㄙㄨㄥ': 'song',
    # 零聲母：單韻母
    'ㄚ': 'a', 'ㄛ': 'o', 'ㄜ': 'e', 'ㄝ': 'ei', 'ㄞ': 'ai', 'ㄟ': 'ei', 'ㄠ': 'ao', 'ㄡ': 'ou', 'ㄢ': 'an',
    'ㄣ': 'en', 'ㄤ': 'ang', 'ㄥ': 'eng', 'ㄦ': 'er',
    # 零聲母：ㄧ
    'ㄧ': 'yi', 'ㄧㄚ': 'ya', 'ㄧㄛ': 'yo', 'ㄧㄝ': 'ye', 'ㄧㄞ': 'yai', 'ㄧㄠ': 'yao', 'ㄧㄡ': 'you',
    'ㄧㄢ': 'yan', 'ㄧㄣ': 'yin', 'ㄧㄤ': 'yang', 'ㄧㄥ': 'ying',
    # 零聲母：ㄨ
    'ㄨ': 'wu', 'ㄨㄚ': 'wa', 'ㄨㄛ': 'wo', 'ㄨㄞ': 'wai', 'ㄨㄟ': 'wei', 'ㄨㄢ': 'wan', 'ㄨㄣ': 'wen',
    'ㄨㄤ': 'wang', 'ㄨㄥ': 'weng',
    # 零聲母：ㄩ
    'ㄩ': 'yu', 'ㄩㄝ': 'yue', 'ㄩㄢ': 'yuan', 'ㄩㄣ': 'yun', 'ㄩㄥ': 'yong',
}

# 刻意多對一的對照（其餘必須一對一，抓抄錯）。
INTENTIONAL_MERGES = {'ㄝ'}

# pinyin.dat（rime-pinyin-simp 的 415 個音節）裡沒有、但確實存在的音節（多為臺灣讀音，例 崖 ㄧㄞˊ、孿 ㄌㄩㄢˊ）。
TAIWAN_ONLY_SYLLABLES = {'biang', 'lvan', 'nun', 'pia', 'rua', 'sei', 'yai'}

# 允許整筆丟掉的讀音（不是普通話音節）：
#   ''     只有聲調記號、沒有音節本體的鍵
#   ㄧㄜ   資料裡的非標準讀音（意ㄧㄜˋ 等 3 筆）
#   單獨的 ㄅ…ㄒ 聲母（詞本身是注音符號的條目已先濾掉；若留下別的字就在這裡丟）
SKIPPED_READINGS = {'', 'ㄧㄜ'} | set('ㄅㄆㄇㄈㄉㄊㄋㄌㄍㄎㄏㄐㄑㄒ')


def check_table(valid):
    """表本身的健全性：值都是合法拼音、除刻意合併外一對一。"""
    bad = {b: p for b, p in BOPOMOFO_TO_PINYIN.items() if p not in valid}
    if bad:
        sys.exit(f'對照表有不合法的拼音：{bad}')
    seen = {}
    for b, p in BOPOMOFO_TO_PINYIN.items():
        if b in INTENTIONAL_MERGES:
            continue
        if p in seen:
            sys.exit(f'對照表不是一對一：{seen[p]} 與 {b} 都對到 {p}')
        seen[p] = b
    for b in BOPOMOFO_TO_PINYIN:
        if any(ch not in BOPOMOFO_CHARS for ch in b):
            sys.exit(f'對照表的鍵含非注音字元：{b!r}')


def convert(zhuyin_table):
    """{注音鍵: [(詞, 分數), …]} → {拼音鍵: [(詞, 分數), …]}。回傳（表, 統計）。"""
    merged = {}
    order = 0
    skipped_symbol = skipped_reading = 0
    unknown = set()
    for key, entries in zhuyin_table.items():
        bases = [s.rstrip(TONES) for s in key.split('-')]
        pinyin = []
        skip = False
        for b in bases:
            p = BOPOMOFO_TO_PINYIN.get(b)
            if p is None:
                if b not in SKIPPED_READINGS:
                    unknown.add(b)
                skip = True
                break
            pinyin.append(p)
        for text, score in entries:
            if any(ch in BOPOMOFO_CHARS for ch in text):
                skipped_symbol += 1
                continue
            if skip:
                skipped_reading += 1
                continue
            k = ' '.join(pinyin)
            bucket = merged.setdefault(k, {})
            if text not in bucket or score > bucket[text][0]:
                bucket[text] = (score, bucket[text][1] if text in bucket else order)
            order += 1
    if unknown:
        sys.exit(f'對照表沒有涵蓋這些讀音：{sorted(unknown)}')
    table = {}
    for k, bucket in merged.items():
        items = sorted(bucket.items(), key=lambda kv: (-kv[1][0], kv[1][1]))
        table[k] = [(text, score) for text, (score, _) in items]
    return table, skipped_symbol, skipped_reading


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('data_dir', help='McBopomofo 的 Source/Data 目錄')
    ap.add_argument('--output', default=DEFAULT_OUTPUT)
    ap.add_argument('--rebuild', action='store_true', help='強制重跑 McBopomofo 的 make data.txt')
    ap.add_argument('--simp-dat', default=SIMP_DAT, help='用來核對音節合法性的 pinyin.dat')
    args = ap.parse_args()

    valid = pinyin_data.syllables_of(args.simp_dat) | TAIWAN_ONLY_SYLLABLES
    check_table(valid)

    data_txt = zhuyin_data.build_data_txt(os.path.abspath(args.data_dir), args.rebuild)
    table, skipped_symbol, skipped_reading = convert(zhuyin_data.load(data_txt))
    used = {s for k in table for s in k.split(' ')}
    unused = sorted(set(BOPOMOFO_TO_PINYIN.values()) - used)
    print(f'略過：詞為注音符號 {skipped_symbol} 筆、非普通話讀音 {skipped_reading} 筆；'
          f'對照表中資料沒用到的拼音：{unused or "無"}')
    pinyin_data.write_verified(table, args.output)


if __name__ == '__main__':
    main()

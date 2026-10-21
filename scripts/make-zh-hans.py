#!/usr/bin/env python3
"""iOS 简中（zh-Hans）翻譯產生器：String Catalog 收 key → OpenCC tw2sp → 大陸 iOS 用語詞表。

用法（在 repo 根目錄跑，可重複執行）：
  python3 scripts/make-zh-hans.py --build          # 先用 SWIFT_EMIT_LOC_STRINGS=YES 編一次，收 .stringsdata
  python3 scripts/make-zh-hans.py                  # 用上次編出來的 .stringsdata 同步、補翻譯
  python3 scripts/make-zh-hans.py --mark-reviewed  # 人工逐條看過後，把機器翻譯標成 translated（之後不再覆寫）
  python3 scripts/make-zh-hans.py --check          # 只檢查：缺翻譯／還沒審的／比 git HEAD 少掉的 zh-Hans，有就 exit 1
  python3 scripts/make-zh-hans.py --force          # 連 translated 的也重算（OVERRIDES 仍優先）

key 的來源＝編譯器自己吐的 .stringsdata（`xcstringstool sync`），所以含插值的 key
（%@、%lld）跟 runtime 查表用的是同一份格式，不靠手抄。
Info.plist 的權限說明（NS*UsageDescription）另外寫進 App／Keyboard 各自的 InfoPlist.xcstrings。

手動條目（extractionState=manual，例 vocab.pack.*.name 這種 String(localized:) 動態 key）與
key 本身沒有中文、但人工給過 zh-Hans 的條目（例 "Google Gemini"、"%@・%@"）：原文取 zh-Hant 值，
已有的 zh-Hans 一律保留。sync 前先存一份 zh-Hans 快照，寫回前比對；有任何一條消失就補回，
補不回（整個 key 被刪）就不寫檔、exit 1。2026-09-26 實際踩過：32 條被清成 shouldTranslate=false，
简中使用者會看到繁體詞庫名。

--build 預設帶 -clonedSourcePackagesDirPath（UTUVO_L10N_SOURCE_PACKAGES 可覆寫，設空字串＝不帶）
與 -skipPackagePluginValidation -skipMacroValidation；這台機器不帶會解析不到套件。

依賴：`pip3 install opencc`（Apache-2.0，只在建置期用，不進 app）。
"""
from __future__ import annotations

import argparse
import json
import os
import plistlib
import re
import subprocess
import sys
from pathlib import Path

import opencc

ROOT = Path(__file__).resolve().parent.parent
IOS = ROOT / "ios"
CATALOG = IOS / "Shared" / "Localizable.xcstrings"
INFOPLIST_CATALOGS = {
    IOS / "App" / "InfoPlist.xcstrings": IOS / "App" / "Info.plist",
    IOS / "Keyboard" / "InfoPlist.xcstrings": IOS / "Keyboard" / "Info.plist",
}
DERIVED = ROOT / ".derivedData-l10n"
DEFAULT_SOURCE_PACKAGES = Path.home() / "Library/Caches/UTUVOTypeASRBench/ios-qwen-spike/build/SourcePackages"
INFOPLIST_KEYS = ("NSMicrophoneUsageDescription", "NSSpeechRecognitionUsageDescription")

SOURCE = "zh-Hant"
TARGET = "zh-Hans"
MACHINE_STATE = "needs_review"
REVIEWED_STATE = "translated"

# OpenCC tw2sp 之後才套的大陸 iOS 用語（照順序、長的在前）。左邊是 tw2sp 的輸出。
GLOSSARY: list[tuple[str, str]] = [
    ("设置 → 一般", "设置 → 通用"),          # 系統設定路徑：一般＝通用
    ("加入新键盘", "添加新键盘"),
    # iOS 27 繁中改叫「新增鍵盤」「允許完整取用」（2026-09-26 模擬器實見）；简中 iOS 仍是「添加新键盘」「允许完全访问」。
    ("新增键盘", "添加新键盘"),
    ("添加键盘", "添加新键盘"),       # tw2sp 會先把「新增」轉成「添加」
    ("允许完整取用", "允许完全访问"),
    ("完整取用", "完全访问"),
    ("允许完整访问", "允许完全访问"),
    ("完整访问", "完全访问"),
    ("语音辨识", "语音识别"),
    ("辨识", "识别"),
    ("装置端", "设备端"),
    ("装置", "设备"),
    ("选配", "可选"),
    ("伺服器", "服务器"),
    ("设定", "设置"),
    ("讯息", "信息"),
    ("萤幕", "屏幕"),
    ("工作阶段", "会话"),
    ("拷贝", "复制"),            # tw2sp 把「複製」轉成選單用語「拷贝」；App 內按鈕大陸慣用「复制」
    ("纪录", "记录"),
    ("字典", "词典"),            # 個人字典＝个人词典
    ("逐字稿", "转录文本"),
    ("放开", "松开"),
    ("回传", "返回"),
    ("不离机", "不离开设备"),
    ("只用设备端识别", "仅使用设备端识别"),
    ("你开了", "你开启了"),
    ("会送到", "会发送到"),
    ("画面", "界面"),
    ("走服务器识别", "使用服务器识别"),
    ("「", "“"),                 # 大陸用彎引號，不用直角引號
    ("」", "”"),
]
# 大陸 UI 寫「App」（Apple 简中慣例）；只換獨立的英文字 app。
APP_WORD = re.compile(r"(?<![A-Za-z])app(?![A-Za-z])")

# 人工審過的逐條修正（key＝zh-Hant 原文）。優先於 OpenCC＋詞表，一律標 translated。
# 2026-09-18 逐條審 182 條後的修正：
OVERRIDES: dict[str, str] = {
    # 版面（layout）：大陸 iOS 用「布局」
    "切換鍵盤版面": "切换键盘布局",
    # 時間單位：大陸不用單字「分／時」當單位
    "%@ 時": "%@ 小时",
    "%lld 分": "%lld 分钟",
    "<1 分": "<1 分钟",
    # 語言名：大陸習慣「X语」
    "英文": "英语",
    "英文（美國）": "英语（美国）",
    "日文": "日语",
    "韓文": "韩语",
    "法文": "法语",
    "德文": "德语",
    "西班牙文": "西班牙语",
    "義大利文": "意大利语",
    "葡萄牙文": "葡萄牙语",
    "荷蘭文": "荷兰语",
    "俄文": "俄语",
    "烏克蘭文": "乌克兰语",
    "波蘭文": "波兰语",
    "土耳其文": "土耳其语",
    "阿拉伯文": "阿拉伯语",
    "印地文": "印地语",
    "印尼文": "印尼语",
    "泰文": "泰语",
    "越南文": "越南语",
    # 送出鍵：照 iOS 简中系統鍵盤
    "送出": "发送",
    "下一個": "下一项",
    "空白": "空格",
    # 用詞／語序
    "略過": "跳过",
    "目前": "当前",
    "文字清理": "文本清理",
    "還沒啟用": "尚未启用",
    "鍵盤語音已開啟": "键盘语音已开启",
    "在任何 app 裡用說的打字": "在任何 App 里用语音打字",
    "Keychain 已存一把 key（不顯示內容）。": "Keychain 中已存有一个 key（不显示内容）。",
    "已存進 Keychain。": "已存入 Keychain。",
    "尚未設定；留空＝完全本機，不連任何雲端。": "尚未设置；留空＝完全在本机处理，不连接任何云端。",
    "或點左上角「◀︎」回去，在鍵盤上點光球說話": "或点左上角的“◀︎”返回，在键盘上点光球说话",
    "找不到可用的麥克風輸入（模擬器通常沒有）。請改用實機，或接上輸入裝置再試。":
        "找不到可用的麦克风输入（模拟器通常没有）。请改用真机，或连接输入设备后再试。",
    "換個字試試；raw 逐字稿也會被搜到。": "换个词试试；原始转录文本也会被搜到。",
    "有選取文字時，鍵盤的光球會變成「說出要怎麼改」（轉成薰衣草色）；長按光球滑到語言、放開就翻譯。":
        "选中文字时，键盘的光球会变成“说出要怎么改”（变为薰衣草色）；长按光球滑到语言、松开就翻译。",
    "選取已取消，沒有改動文字": "选中已取消，文字未改动",
    "說完再點一下，改寫會取代選取": "说完再点一下，改写结果会替换所选内容",
    "正在開啟 UTUVO Type 啟動麥克風…回來就在錄了": "正在打开 UTUVO Type 启动麦克风…回来时就已经在录了",
    "端點網址錯誤": "端点地址错误",
    "這個方向系統不支援，會用 Apple Intelligence": "系统不支持这个翻译方向，将使用 Apple Intelligence",
    "可下載裝置端翻譯包（沒下載時用 Apple Intelligence）": "可下载设备端翻译包（未下载时使用 Apple Intelligence）",
    "這台裝置沒有 Apple Intelligence（iOS 26），也沒設雲端 key；到主 app 設定 → 雲端翻譯加入 key 即可":
        "这台设备没有 Apple Intelligence（iOS 26），也没有设置云端 key；在主 App 的“设置 → 云端翻译”中添加 key 即可",
    "閒置 %lld 分鐘後自動關麥克風": "闲置 %lld 分钟后自动关闭麦克风",
    "雲端回應格式無法解析": "无法解析云端响应格式",
    "修好後回到鍵盤，再點一次光球。": "解决后回到键盘，再点一次光球。",
    "滑到語言，放開就翻譯；放開在別處取消": "滑到语言，松开就翻译；在别处松开则取消",
    "翻成%@中…": "正在翻译成%@…",
    "再點一下完成，翻成%@": "再点一下完成，翻译成%@",
    "翻譯與改寫走 Apple Intelligence，文字不離機": "翻译与改写使用 Apple Intelligence，文字不离开设备",
    "翻譯與改寫走你自己的雲端 key": "翻译与改写使用你自己的云端 key",
    "改寫引擎回了空白，輸出沒有動。": "改写引擎返回了空白内容，输出未改动。",
    "輸入新的 key 以取代": "输入新的 key 以替换",
    "你開了「只用裝置端辨識」，但這個語言在這台裝置沒有裝置端辨識":
        "你开启了“仅使用设备端识别”，但这台设备不支持该语言的设备端识别",
    "你開了「只用裝置端辨識」，但這台裝置在%@沒有裝置端辨識可用。關掉這個開關才會改用雲端辨識（音訊會送到 Apple 伺服器）。":
        "你开启了“仅使用设备端识别”，但这台设备不支持%@的设备端识别。关闭此开关后才会改用云端识别（音频会发送到 Apple 服务器）。",
    # 2026-10-09 i18n 稽核修正（tasks/i18n-fix-2026-10-09/Type-fixlist.md）：防 --force 蓋回機器譯文
    "vocab.pack.computing.name": "信息与计算机",
    "資訊與電腦": "信息与计算机",
    "電機與土木工程學術名詞：電路、訊號、控制、材料、結構、交通運輸、大地工程等。": "电气与土木工程学术名词：电路、信号、控制、材料、结构、交通运输、岩土工程等。",
    "vocab.pack.engineering.summary": "电气与土木工程学术名词：电路、信号、控制、材料、结构、交通运输、岩土工程等。",
    "vocab.pack.finance.summary": "经济、会计、财经法相关学术名词：宏观经济、财务会计、保险金融、税务等。",
    "經濟、會計、財經法相關學術名詞：總體經濟、財務會計、保險金融、稅務等。": "经济、会计、财经法相关学术名词：宏观经济、财务会计、保险金融、税务等。",
    "醫學、藥學、人體解剖、醫事檢驗等學術名詞：常用疾病、藥物、解剖構造、檢驗項目。": "医学、药学、人体解剖、医学检验等学术名词：常用疾病、药物、解剖结构、检验项目。",
    "vocab.pack.medicine.summary": "医学、药学、人体解剖、医学检验等学术名词：常用疾病、药物、解剖结构、检验项目。",
    "使用教學": "使用教程",
    "使用教學：怎麼設定、怎麼用鍵盤講話": "使用教程：怎么设置、怎么用键盘讲话",
    "可以用（%1$lld 毫秒）：%2$@": "可以用（%1$lld 毫秒）：%2$@",
    "可以用（%lld 毫秒）：%@": "可以用（%1$lld 毫秒）：%2$@",
    "同一把 key 可供雲端翻譯與智慧整理使用；未設定時兩者都不會連線。": "同一个 key 可用于云端翻译与智能整理；未设置时两者都不会连接。",
    "填入任何 OpenAI 相容服務的端點網址與模型名稱（例如自己架的伺服器）。": "填入任何 OpenAI 兼容服务的端点地址与模型名称（例如自建的服务器）。",
    "已加入 %lld 筆。": "已添加 %lld 条。",
    "已存進這支手機的鑰匙圈。": "已存入本机的钥匙串。",
    "按下去的當下就震（不是放開才震），選字、切換鍵盤也有。震動需要在系統設定打開「允許完整取用」（跟語音一樣），按鍵聲音不用；手機靜音或系統把觸覺回饋關掉時都不會有。": "按下去的当下就振（不是松开才振），选字、切换键盘也有。振动需要在系统设置打开“允许完全访问”（跟语音一样），按键声音不用；手机静音或系统把触觉反馈关掉时都不会有。",
    "現在連不到 App Store，稍後再試。": "暂时无法连接 App Store，请稍后再试。",
    "用 Qwen3-ASR 在這支手機上重新辨識你講完的整段話，並參考你的字典，專有名詞與整體錯字明顯減少（實測錯字約少六成）。音訊不離開手機。目前只用在 UTUVO Type App 內的聽寫；鍵盤聽寫時 App 在背景，iOS 不允許背景使用 GPU，鍵盤仍用 Apple 辨識。建議連上 Wi-Fi 再下載。": "用 Qwen3-ASR 在这台手机上重新识别你说完的整段话，并参考你的词典，专有名词与整体错字明显减少（实测错字约少六成）。音频不离开手机。目前只用在 UTUVO Type App 内的听写；键盘听写时 App 在后台，iOS 不允许后台使用 GPU，键盘仍用 Apple 识别。建议连上 Wi-Fi 再下载。",
    "端點網址（…/chat/completions）": "端点地址（…/chat/completions）",
    "第一次會跳到 UTUVO Type 開麥克風？看完整教學": "第一次会跳到 UTUVO Type 开麦克风？查看完整教程",
    "等待核准中（例如家長同意），完成後會自動入帳。": "等待批准中（例如家长同意），完成后会自动入账。",
    "設定 → 字典（選「新增詞彙」）。人名、品牌、術語（Atmos、Pro Tools…）加進去：英文專名貼上前會照字典改正拼法，高準確度辨識、雲端辨識和智慧整理也會參考這些詞。手機內建辨識本身不一定認得。": "设置 → 词典（选“新增词汇”）。人名、品牌、术语（Atmos、Pro Tools…）加进去：英文专名粘贴前会按词典改正拼写，高准确度识别、云端识别和智能整理也会参考这些词。手机内置识别本身不一定认得。",
    "輸入詞目片段可即時過濾；結果上限 100 筆。": "输入词条片段可实时过滤；结果上限 100 条。",
    "這一把 key 同時供雲端翻譯與智慧整理使用。": "这个 key 同时用于云端翻译与智能整理。",
    "這裡不重複輸入；請到「設定」裡的阿里雲百鍊頁管理同一把 key。": "这里不重复输入；请到“设置”里的阿里云百炼页管理同一个 key。",
    "鍵盤第一次講話會跳到 UTUVO Type 開麥克風，之後在這段時間內都不用再跳。時間越長越少跳；期間麥克風保持開啟（狀態列有橘點），但只有你點光球時才會處理聲音。": "键盘第一次讲话会跳到 UTUVO Type 开麦克风，之后在这段时间内都不用再跳。时间越长越少跳；期间麦克风保持打开（状态栏有橙点），但只有你点光球时才会处理声音。",
    "雲端辨識（選配）": "云端识别（可选）",
    "雲端辨識（選配，需自己的 key）": "云端识别（可选，需自己的 key）",
    "顯示前 %lld 筆（共 %lld 筆）": "显示前 %lld 条（共 %lld 条）",
}


def run(cmd: list[str]) -> None:
    print("$", " ".join(cmd), flush=True)
    subprocess.run(cmd, check=True)


def build(derived: Path) -> None:
    packages = os.environ.get("UTUVO_L10N_SOURCE_PACKAGES", str(DEFAULT_SOURCE_PACKAGES))
    extra: list[str] = []
    if packages:
        if not Path(packages).is_dir():
            sys.exit(f"找不到 SourcePackages：{packages}（設 UTUVO_L10N_SOURCE_PACKAGES 指到別處，或設空字串不帶）")
        extra += ["-clonedSourcePackagesDirPath", packages]
    run([
        "xcodebuild", "build",
        "-project", str(IOS / "UTUVO Type.xcodeproj"),
        "-scheme", "UTUVOTypeiOS",
        "-destination", "generic/platform=iOS Simulator",
        "-derivedDataPath", str(derived),
        *extra,
        "-skipPackagePluginValidation",
        "-skipMacroValidation",
        "SWIFT_EMIT_LOC_STRINGS=YES",
        "CODE_SIGNING_ALLOWED=NO",
        "-quiet",
    ])


# 每個 target 編了哪些 Swift 原始碼資料夾（對照 ios/project.yml 的 sources）。
TARGET_SOURCES = {
    "UTUVOTypeiOS.build": ("App", "Shared"),
    "UTUVOKeyboard.build": ("Keyboard", "Shared"),
}


def stringsdata_files(derived: Path) -> list[Path]:
    """收 .stringsdata，而且要「每個 Swift 檔都有一份」才算數。

    沒帶 SWIFT_EMIT_LOC_STRINGS=YES 的建置會把逐檔的 .stringsdata 清掉；拿殘缺的一組去 sync，
    xcstringstool 會把所有 key 標成 stale（2026-09-18 實際踩到：178 條全 stale）。所以缺一份就停。
    """
    files: list[Path] = []
    missing: list[str] = []
    for target, folders in TARGET_SOURCES.items():
        found = {p.stem: p for p in derived.rglob("*.stringsdata") if target in p.parts}
        for folder in folders:
            for swift in sorted((IOS / folder).glob("*.swift")):
                if swift.stem in found:
                    files.append(found[swift.stem])
                else:
                    missing.append(f"{target}/{swift.stem}")
    if missing:
        sys.exit(
            f"{derived} 的 .stringsdata 不完整（缺 {len(missing)} 份，例：{missing[0]}）。\n"
            "先跑 --build，或用 --derived-data 指到帶 SWIFT_EMIT_LOC_STRINGS=YES 的建置；不然 sync 會把 key 全標成 stale。"
        )
    return files


_converter = opencc.OpenCC("tw2sp")


def to_hans(text: str) -> str:
    if text in OVERRIDES:
        return OVERRIDES[text]
    out = _converter.convert(text)
    for src, dst in GLOSSARY:
        out = out.replace(src, dst)
    return APP_WORD.sub("App", out)


def has_cjk(text: str) -> bool:
    return any("㐀" <= ch <= "鿿" for ch in text)


def fill(entries: dict, source_text, force: bool) -> tuple[int, int]:
    """補 zh-Hans。回傳（新寫入或更新, 保留人工）。"""
    written = kept = 0
    for key, entry in entries.items():
        if entry.get("extractionState") == "stale":
            continue
        src = source_text(key, entry)
        locs = entry.setdefault("localizations", {})
        unit = locs.get(TARGET, {}).get("stringUnit")
        if not has_cjk(src):
            if unit:
                kept += 1  # 人工給過 zh-Hans（"Google Gemini"、"%@・%@"）：保留，不標 shouldTranslate=false
                continue
            # 純格式／英文（%lld、EN…）：不需要翻譯。
            entry["shouldTranslate"] = False
            locs.pop(TARGET, None)
            if not locs:
                entry.pop("localizations")
            continue
        if key in OVERRIDES:
            state = REVIEWED_STATE
        elif unit and unit.get("state") == REVIEWED_STATE and not force:
            kept += 1  # 人工審過（或在 Xcode 裡改過）的不動
            continue
        else:
            state = MACHINE_STATE
        value = to_hans(src)
        if not unit or unit.get("value") != value or unit.get("state") != state:
            written += 1
        locs[TARGET] = {"stringUnit": {"state": state, "value": value}}
    return written, kept


def localizable_source(key: str, entry: dict | None = None) -> str:
    """Localizable 的原文：manual 條目（String(localized:) 的動態 key，例 vocab.pack.law.name）
    key 不是原文，要讀 zh-Hant 值；其他條目 key 就是原文。"""
    if entry and entry.get("extractionState") == "manual":
        value = entry.get("localizations", {}).get(SOURCE, {}).get("stringUnit", {}).get("value")
        if value:
            return value
    return key


def target_units(entries: dict) -> dict[str, dict]:
    """key → zh-Hans stringUnit（只收有值的）。"""
    out = {}
    for key, entry in entries.items():
        unit = entry.get("localizations", {}).get(TARGET, {}).get("stringUnit")
        if unit and unit.get("value"):
            out[key] = unit
    return out


def lost_units(baseline: dict[str, dict], entries: dict) -> list[str]:
    """baseline 有 zh-Hans、現在沒了的 key（整個 key 被刪也算）。stale 的條目 zh-Hans 還在就不算。"""
    lost = []
    for key in baseline:
        entry = entries.get(key)
        if entry is None or not entry.get("localizations", {}).get(TARGET, {}).get("stringUnit", {}).get("value"):
            lost.append(key)
    return sorted(lost)


def restore_units(baseline: dict[str, dict], entries: dict) -> list[str]:
    """把 sync／fill 弄丟的 zh-Hans 補回去（連同拿掉 shouldTranslate=false）。回傳補回的 key。"""
    restored = []
    for key in lost_units(baseline, entries):
        entry = entries.get(key)
        if entry is None:
            continue  # 整個 key 被刪：補不回，交給呼叫端報錯
        entry.setdefault("localizations", {})[TARGET] = {"stringUnit": dict(baseline[key])}
        if entry.get("shouldTranslate") is False:
            del entry["shouldTranslate"]
        restored.append(key)
    return restored


def git_baseline(path: Path) -> dict | None:
    rel = path.relative_to(ROOT)
    proc = subprocess.run(["git", "-C", str(ROOT), "show", f"HEAD:{rel}"], capture_output=True, text=True)
    if proc.returncode != 0:
        return None
    return json.loads(proc.stdout)


def load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def save(path: Path, data: dict) -> None:
    # Xcode 的格式：key 排序、" : " 分隔、2 空白縮排。
    text = json.dumps(data, ensure_ascii=False, indent=2, sort_keys=True, separators=(",", " : "))
    path.write_text(text + "\n", encoding="utf-8")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--build", action="store_true", help="先編一次收 .stringsdata")
    ap.add_argument("--derived-data", type=Path, default=DERIVED)
    ap.add_argument("--force", action="store_true", help="translated 的也重算")
    ap.add_argument("--mark-reviewed", action="store_true", help="needs_review → translated")
    ap.add_argument("--check", action="store_true", help="只檢查，不寫檔")
    ap.add_argument("--list", action="store_true", help="印出全部 zh-Hant → zh-Hans 對照")
    ap.add_argument("--baseline", type=Path, help="--check 比對用的舊 catalog（預設 git HEAD 版）")
    args = ap.parse_args()

    snapshot: dict[str, dict] = {}
    snapshot_bytes = CATALOG.read_bytes()
    if not args.check and not args.list:
        if args.build:
            build(args.derived_data)
        files = stringsdata_files(args.derived_data)
        snapshot = target_units(load(CATALOG)["strings"])
        cmd = ["xcrun", "xcstringstool", "sync", str(CATALOG)]
        for f in files:
            cmd += ["--stringsdata", str(f)]
        print(f"$ xcrun xcstringstool sync {CATALOG.relative_to(ROOT)} （{len(files)} 個 .stringsdata）", flush=True)
        subprocess.run(cmd, check=True)

    # 每份 catalog 配一個「key → zh-Hant 原文」：Localizable 的 key 就是原文；
    # InfoPlist 的 key 是 plist 欄位名，原文從 Info.plist（xcodegen 由 project.yml 產生）讀。
    catalogs: dict[Path, object] = {CATALOG: localizable_source}
    for cat_path, plist_path in INFOPLIST_CATALOGS.items():
        plist = plistlib.loads(plist_path.read_bytes())
        sources = {k: plist[k] for k in INFOPLIST_KEYS if k in plist}
        if not args.check and not args.list:
            data = load(cat_path)
            for k, text in sources.items():
                entry = data["strings"].setdefault(k, {})
                entry["comment"] = "Info.plist 權限說明；原文在 ios/project.yml"
                entry["extractionState"] = "manual"
                # 原文也要明寫一份：InfoPlist catalog 沒有 zh-Hant 值時，編出來的
                # zh-Hant.lproj/InfoPlist.strings 會是「key = key」，權限框直接顯示欄位名。
                entry.setdefault("localizations", {})[SOURCE] = {"stringUnit": {"state": REVIEWED_STATE, "value": text}}
            save(cat_path, data)
        catalogs[cat_path] = lambda key, entry=None, s=sources: s[key]

    problems = 0
    total = 0
    for path, source_text in catalogs.items():
        data = load(path)
        entries = data["strings"]
        if args.check or args.list:
            for key, entry in sorted(entries.items()):
                if entry.get("extractionState") == "stale" or entry.get("shouldTranslate") is False:
                    continue
                unit = entry.get("localizations", {}).get(TARGET, {}).get("stringUnit")
                total += 1
                if args.list:
                    print(f"{source_text(key, entry)}\n  → {unit['value'] if unit else '（缺）'}  [{unit['state'] if unit else '-'}]")
                if not unit or unit.get("state") != REVIEWED_STATE:
                    problems += 1
                    if args.check:
                        print(f"未審／缺：{path.relative_to(ROOT)}  {key}")
                if path != CATALOG:
                    src_unit = entry.get("localizations", {}).get(SOURCE, {}).get("stringUnit") or {}
                    if src_unit.get("value") != source_text(key, entry):
                        problems += 1
                        print(f"原文跟 Info.plist 不同步：{path.relative_to(ROOT)}  {key}（重跑本腳本）")
            if args.check and path == CATALOG:
                if args.baseline:
                    base = load(args.baseline)
                else:
                    base = git_baseline(path)
                    if base is None:
                        print("讀不到 git HEAD 的 catalog，略過 zh-Hans 消失檢查（用 --baseline 指定）")
                if base is not None:
                    for key in lost_units(target_units(base["strings"]), entries):
                        problems += 1
                        print(f"zh-Hans 消失：{path.relative_to(ROOT)}  {key}")
            continue
        written, kept = fill(entries, source_text, args.force)
        if path == CATALOG:
            restored = restore_units(snapshot, entries)
            for key in restored:
                print(f"補回 zh-Hans：{key}")
            gone = lost_units(snapshot, entries)
            if gone:
                CATALOG.write_bytes(snapshot_bytes)  # sync 已經改寫了檔案：還原成跑之前的樣子
                sys.exit(f"sync 刪掉了 {len(gone)} 條有 zh-Hans 的 key（例：{gone[0]}），已還原 catalog、未寫入。")
        if args.mark_reviewed:
            for entry in entries.values():
                unit = entry.get("localizations", {}).get(TARGET, {}).get("stringUnit")
                if unit and unit.get("state") == MACHINE_STATE:
                    unit["state"] = REVIEWED_STATE
        save(path, data)
        live = sum(1 for e in entries.values() if e.get("extractionState") != "stale" and e.get("shouldTranslate") is not False)
        stale = sum(1 for e in entries.values() if e.get("extractionState") == "stale")
        print(f"{path.relative_to(ROOT)}：{live} 條需翻譯（新寫入 {written}、保留人工 {kept}、stale {stale}）")
    if args.check:
        print(f"{total} 條，未審或缺 {problems} 條")
        return 1 if problems else 0
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""iOS 简中（zh-Hans）翻譯產生器：String Catalog 收 key → OpenCC tw2sp → 大陸 iOS 用語詞表。

用法（在 repo 根目錄跑，可重複執行）：
  python3 scripts/make-zh-hans.py --build          # 先用 SWIFT_EMIT_LOC_STRINGS=YES 編一次，收 .stringsdata
  python3 scripts/make-zh-hans.py                  # 用上次編出來的 .stringsdata 同步、補翻譯
  python3 scripts/make-zh-hans.py --mark-reviewed  # 人工逐條看過後，把機器翻譯標成 translated（之後不再覆寫）
  python3 scripts/make-zh-hans.py --check          # 只檢查：有沒有缺翻譯／還沒審的，有就 exit 1
  python3 scripts/make-zh-hans.py --force          # 連 translated 的也重算（OVERRIDES 仍優先）

key 的來源＝編譯器自己吐的 .stringsdata（`xcstringstool sync`），所以含插值的 key
（%@、%lld）跟 runtime 查表用的是同一份格式，不靠手抄。
Info.plist 的權限說明（NS*UsageDescription）另外寫進 App／Keyboard 各自的 InfoPlist.xcstrings。

依賴：`pip3 install opencc`（Apache-2.0，只在建置期用，不進 app）。
"""
from __future__ import annotations

import argparse
import json
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
INFOPLIST_KEYS = ("NSMicrophoneUsageDescription", "NSSpeechRecognitionUsageDescription")

SOURCE = "zh-Hant"
TARGET = "zh-Hans"
MACHINE_STATE = "needs_review"
REVIEWED_STATE = "translated"

# OpenCC tw2sp 之後才套的大陸 iOS 用語（照順序、長的在前）。左邊是 tw2sp 的輸出。
GLOSSARY: list[tuple[str, str]] = [
    ("设置 → 一般", "设置 → 通用"),          # 系統設定路徑：一般＝通用
    ("加入新键盘", "添加新键盘"),
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
}


def run(cmd: list[str]) -> None:
    print("$", " ".join(cmd), flush=True)
    subprocess.run(cmd, check=True)


def build() -> None:
    run([
        "xcodebuild", "build",
        "-project", str(IOS / "UTUVO Type.xcodeproj"),
        "-scheme", "UTUVOTypeiOS",
        "-destination", "generic/platform=iOS Simulator",
        "-derivedDataPath", str(DERIVED),
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
        src = source_text(key)
        if not has_cjk(src):
            # 純格式／英文（%lld、EN…）：不需要翻譯。
            entry["shouldTranslate"] = False
            entry.get("localizations", {}).pop(TARGET, None)
            continue
        locs = entry.setdefault("localizations", {})
        unit = locs.get(TARGET, {}).get("stringUnit")
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
    args = ap.parse_args()

    if not args.check and not args.list:
        if args.build:
            build()
        files = stringsdata_files(args.derived_data)
        cmd = ["xcrun", "xcstringstool", "sync", str(CATALOG)]
        for f in files:
            cmd += ["--stringsdata", str(f)]
        print(f"$ xcrun xcstringstool sync {CATALOG.relative_to(ROOT)} （{len(files)} 個 .stringsdata）", flush=True)
        subprocess.run(cmd, check=True)

    # 每份 catalog 配一個「key → zh-Hant 原文」：Localizable 的 key 就是原文；
    # InfoPlist 的 key 是 plist 欄位名，原文從 Info.plist（xcodegen 由 project.yml 產生）讀。
    catalogs: dict[Path, object] = {CATALOG: lambda key: key}
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
        catalogs[cat_path] = sources.__getitem__

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
                    print(f"{source_text(key)}\n  → {unit['value'] if unit else '（缺）'}  [{unit['state'] if unit else '-'}]")
                if not unit or unit.get("state") != REVIEWED_STATE:
                    problems += 1
                    if args.check:
                        print(f"未審／缺：{path.relative_to(ROOT)}  {key}")
                if path != CATALOG:
                    src_unit = entry.get("localizations", {}).get(SOURCE, {}).get("stringUnit") or {}
                    if src_unit.get("value") != source_text(key):
                        problems += 1
                        print(f"原文跟 Info.plist 不同步：{path.relative_to(ROOT)}  {key}（重跑本腳本）")
            continue
        written, kept = fill(entries, source_text, args.force)
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

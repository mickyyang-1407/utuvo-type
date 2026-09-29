#!/usr/bin/env python3
"""UTUVO Type Android 鍵盤端對端測試（adb＋uiautomator，模擬器或真機都能跑）。

走使用者路徑：打開主 app → 點試打框 → 在我們的鍵盤上打字 → 讀回輸入框的字。
用法：ANDROID_SERIAL=emulator-5554 python3 android/scripts/e2e-keyboard.py [截圖資料夾]
任何一步對不上就 exit 1。
"""
import os
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

ADB = os.path.expanduser("~/Library/Android/sdk/platform-tools/adb")
SHOTS = sys.argv[1] if len(sys.argv) > 1 else None
failures = []


def adb(*args, check=True):
    return subprocess.run([ADB, *args], capture_output=True, text=True, check=check).stdout


def dump():
    # --windows：鍵盤是獨立視窗，預設只 dump 目前 app 的視窗會看不到鍵盤
    adb("shell", "uiautomator", "dump", "--windows", "/sdcard/ui.xml")
    return ET.fromstring(adb("shell", "cat", "/sdcard/ui.xml"))


def find(root, text=None, desc=None):
    for n in root.iter("node"):
        if text is not None and n.get("text") == text:
            return n
        if desc is not None and n.get("content-desc") == desc:
            return n
    return None


def center(node):
    x1, y1, x2, y2 = map(int, re.findall(r"\d+", node.get("bounds")))
    return (x1 + x2) // 2, (y1 + y2) // 2


def tap(text=None, desc=None, root=None):
    root = root if root is not None else dump()
    n = find(root, text, desc)
    if n is None:
        raise AssertionError(f"畫面上找不到 {text or desc}")
    adb("shell", "input", "tap", *map(str, center(n)))
    time.sleep(0.35)


def type_keys(keys):
    root = dump()          # 一次 dump、連續點（鍵盤版面在打字時不會變）
    for k in keys:
        tap(text=k, root=root)


def field_text():
    n = find(dump(), desc="tryField")
    return n.get("text") if n is not None else None


def shot(name):
    if SHOTS:
        os.makedirs(SHOTS, exist_ok=True)
        with open(os.path.join(SHOTS, f"{name}.png"), "wb") as f:
            f.write(subprocess.run([ADB, "exec-out", "screencap", "-p"], capture_output=True, check=True).stdout)


def check(name, want_prefix):
    got = field_text() or ""
    ok = got.startswith(want_prefix)
    print(("ok  " if ok else "FAIL"), name, repr(got))
    if not ok:
        failures.append(f"{name}: 想要以 {want_prefix!r} 開頭，實際 {got!r}")


def settle(timeout=15):
    """等語音區靜下來：不在錄、不在整理（錯誤訊息晚到會蓋掉下一步的提示）。"""
    end = time.time() + timeout
    while time.time() < end:
        texts = [n.get("text") or "" for n in dump().iter("node")]
        if not any(t.startswith("再點一下完成") or t == "整理中…" or t == "翻譯中…" for t in texts):
            time.sleep(1.0)
            return
        time.sleep(0.7)


def clear_field():
    tap(desc="tryField")
    adb("shell", "input", "keyevent", "KEYCODE_MOVE_END")
    for _ in range(40):
        adb("shell", "input", "keyevent", "KEYCODE_DEL")


def scroll_to(desc, tries=8):
    for _ in range(tries):
        root = dump()
        n = find(root, desc=desc)
        if n is not None:
            y = center(n)[1]
            if 300 < y < 1400:          # 在鍵盤上方、看得到的位置
                return root
        adb("shell", "input", "swipe", "540", "1300", "540", "700", "300")
        time.sleep(0.5)
    raise AssertionError(f"捲不到 {desc}")


def dictionary_ui():
    """主 app 個人字典：新增詞彙、替換各加一筆 → 清單出現 → 刪掉（用不會跟 Micky 字典撞名的字）。"""
    vocab, heard, out = "Zqvocab", "zqheard", "ZQOUT"
    scroll_to("dictionaryTerm")
    tap(desc="dictModeVocab")
    tap(desc="dictionaryTerm")
    adb("shell", "input", "text", vocab)
    tap(desc="dictionaryAdd")
    tap(desc="dictModeReplace")
    tap(desc="dictionaryTerm")
    adb("shell", "input", "text", heard)
    tap(desc="dictionaryOutput")
    adb("shell", "input", "text", out)
    tap(desc="dictionaryAdd")
    root = scroll_to("dictionaryTerm")
    shot("09-dictionary")
    v = find(root, desc=f"dictEntry:{vocab}")
    r = find(root, desc=f"dictEntry:{heard}")
    ok = v is not None and r is not None and "詞彙" in (v.get("text") or "") and (r.get("text") or "") == f"{heard} → {out}"
    print("ok  " if ok else "FAIL", "字典：詞彙＋替換各一筆出現在清單",
          repr(v.get("text") if v is not None else None), repr(r.get("text") if r is not None else None))
    if not ok:
        failures.append("字典清單沒有正確顯示新增的詞彙／替換")
    for key in (vocab, heard):
        if find(dump(), desc=f"dictDelete:{key}") is not None:
            tap(desc=f"dictDelete:{key}")
    root = dump()
    gone = find(root, desc=f"dictEntry:{vocab}") is None and find(root, desc=f"dictEntry:{heard}") is None
    print("ok  " if gone else "FAIL", "字典：刪除")
    if not gone:
        failures.append("字典刪除後還在清單")


def main():
    adb("shell", "am", "force-stop", "com.utuvo.type")
    # 測試前置：重裝／connectedAndroidTest 會把麥克風權限清掉（真實使用者在主 app 按「允許麥克風」）
    adb("shell", "pm", "grant", "com.utuvo.type", "android.permission.RECORD_AUDIO")
    # force-stop 鍵盤所在的 app，系統會把預設鍵盤換回別的；重新設回我們的（真實使用者不會 force-stop）
    # 重裝後系統會把我們的鍵盤「停用」（Android 17 實測），沒啟用的不能 set；剛裝完幾秒內也還不認得。先 enable 再 set，重試到成功。
    for _ in range(20):
        adb("shell", "ime", "enable", "com.utuvo.type/.UTUVOImeService", check=False)
        if "selected" in adb("shell", "ime", "set", "com.utuvo.type/.UTUVOImeService", check=False):
            break
        time.sleep(1)
    else:
        raise SystemExit("設不成 UTUVO Type 鍵盤")
    adb("shell", "am", "start", "-n", "com.utuvo.type/.MainActivity")
    time.sleep(2)
    tap(desc="tryField")
    time.sleep(1)
    if find(dump(), desc="繁中鍵盤") is None:
        raise SystemExit("叫不出 UTUVO Type 鍵盤（語音區沒有「繁」鈕）")
    shot("01-voice")

    # 長按光球：出現語言弧，滑到「翻成日文」放開 → 開始錄、提示講明翻成日文；再點一下停止（沒講話＝沒聽到聲音）
    root = dump()
    ox, oy = center(find(root, desc="聽寫"))
    adb("shell", "input", "motionevent", "DOWN", str(ox), str(oy))
    time.sleep(0.9)
    root = dump()
    ja = find(root, desc="翻成日文")
    shot("01b-translate-arc")
    if ja is None:
        failures.append("長按光球沒有出現語言弧（找不到「翻成日文」）")
        adb("shell", "input", "motionevent", "UP", str(ox), str(oy))
    else:
        jx, jy = center(ja)
        for k in range(1, 6):
            adb("shell", "input", "motionevent", "MOVE", str(ox + (jx - ox) * k // 5), str(oy + (jy - oy) * k // 5))
        adb("shell", "input", "motionevent", "UP", str(jx), str(jy))
        time.sleep(1.2)
        root = dump()
        hint_ok = any("翻成日文" in (n.get("text") or "") for n in root.iter("node"))
        arc_gone = find(root, desc="翻成日文") is None
        print("ok  " if hint_ok and arc_gone else "FAIL", "長按→日文：開始錄、提示寫翻成日文、弧收起")
        if not (hint_ok and arc_gone):
            failures.append(f"長按選日文後：提示有翻成日文={hint_ok}，弧收起={arc_gone}")
        shot("01c-translate-listening")
        # 沒人講話時辨識器會自己因靜音結束；還在錄才點停止（已經結束還點＝開一段新的聽寫，09-19 實測踩過）
        if any("再點一下完成" in (n.get("text") or "") for n in dump().iter("node")):
            tap(desc="聽寫")
        settle()
    # 長按後放開在弧外＝取消，不開始錄
    adb("shell", "input", "motionevent", "DOWN", str(ox), str(oy))
    time.sleep(0.9)
    adb("shell", "input", "motionevent", "MOVE", str(ox), str(oy + 400))
    adb("shell", "input", "motionevent", "UP", str(ox), str(oy + 400))
    time.sleep(0.6)
    root = dump()
    idle = any((n.get("text") or "") == "點一下開始說" for n in root.iter("node"))
    print("ok  " if idle else "FAIL", "長按放開在弧外＝取消")
    if not idle:
        hints = [n.get("text") for n in root.iter("node") if n.get("package") == "com.utuvo.type" and n.get("text")]
        failures.append(f"長按放開在弧外沒有取消（提示不是「點一下開始說」）：{hints}")

    # 繁（注音）：ㄋㄧˇㄏㄠˇ → 候選「你好」
    tap(desc="繁中鍵盤")
    root = dump()
    if find(root, text="拼") is None and find(root, text="注") is not None:
        tap(text="注", root=root)                 # 上次停在繁拼音，先回注音
    type_keys(["ㄋ", "ㄧ", "ˇ", "ㄏ", "ㄠ", "ˇ"])
    shot("02-zhuyin")
    tap(text="你好")
    check("注音 ㄋㄧˇㄏㄠˇ 選你好", "你好")

    # 繁切拼音：taibei 選臺北／台北
    tap(text="拼")
    type_keys(list("taibei"))
    shot("03-pinyin-hant")
    root = dump()
    # 不能用 `a or b`：沒有子節點的 XML 元素會被當成 False
    cand = find(root, text="臺北")
    if cand is None:
        cand = find(root, text="台北")
    if cand is None:
        failures.append("繁拼音 taibei 候選列沒有臺北／台北")
    else:
        adb("shell", "input", "tap", *map(str, center(cand)))
        time.sleep(0.3)
    tap(text="注")                                 # 還原成注音
    check("繁拼音 taibei", "你好")
    got = field_text() or ""
    if "臺北" not in got and "台北" not in got:
        failures.append(f"繁拼音 taibei 沒進輸入框：{got!r}")

    # 简：nihao 空白送出最佳轉換
    tap(desc="切換鍵盤版面")                      # 繁 → 简
    type_keys(list("nihao"))
    shot("04-pinyin-hans")
    tap(text="空白")
    got = field_text() or ""
    if not got.endswith("你好"):
        failures.append(f"简 nihao 空白送出，結尾不是你好：{got!r}")
    print("ok  " if got.endswith("你好") else "FAIL", "简 nihao 空白送出", repr(got))

    # 回語音：「🎙 語音」
    tap(desc="語音")
    if find(dump(), desc="繁中鍵盤") is None:
        failures.append("點「🎙 語音」沒有回到語音區")
    shot("05-back-voice")

    # EN：句首自動大寫
    clear_field()
    tap(desc="英文鍵盤")
    type_keys(["H"])        # 打完第一個字會從大寫切回小寫，所以各自重讀畫面
    type_keys(["i"])
    tap(text="space")
    check("EN 句首大寫 Hi", "Hi ")
    shot("06-english")

    # 123：EN 數字、中文全形標點
    tap(desc="切換數字符號")
    type_keys(["1", "2"])
    shot("07-numbers")
    tap(desc="切換數字符號")                       # ABC
    tap(desc="切換鍵盤版面")                       # EN → 繁
    tap(desc="切換數字符號")
    type_keys(["，", "？"])
    shot("08-chinese-punct")
    got = field_text() or ""
    ok = got.endswith("12，？")
    print("ok  " if ok else "FAIL", "123 層數字＋全形標點", repr(got))
    if not ok:
        failures.append(f"123 層：結尾不是 12，？：{got!r}")

    dictionary_ui()

    if failures:
        print("\n".join(["", "失敗："] + failures))
        sys.exit(1)
    print("\n全部通過")


if __name__ == "__main__":
    main()

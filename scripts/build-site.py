#!/usr/bin/env python3
"""Build docs/ (GitHub Pages) from site/template.html: English at /, Traditional Chinese at /zh/.

比照 utuvo-paw：模板只寫英文，zh 字串表在這裡；模板裡找不到的字串直接 exit 1，
不會靜靜漏翻。改文案要兩邊一起改。
"""
import os, sys
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
tpl = open(os.path.join(ROOT, 'site/template.html'), encoding='utf-8').read()
SITE = 'https://mickyyang-1407.github.io/utuvo-type/'

HEAD = '''<!doctype html>
<html lang="{lang}">
<head>
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="description" content="{desc}">
<meta property="og:title" content="UTUVO Type"><meta property="og:description" content="{desc}"><meta property="og:image" content="{site}assets/og.png"><meta name="twitter:card" content="summary_large_image">
<link rel="alternate" hreflang="en" href="{site}"><link rel="alternate" hreflang="zh-Hant" href="{site}zh/">
<link rel="icon" href="{base}assets/logo.png">
'''

DESC = {
    'en': "UTUVO Type — free, open-source, local-first voice dictation for macOS. Transcribes on your Mac, cleans up deterministically, pastes where your cursor is.",
    'zh': "UTUVO Type——免費開源、本機優先的 macOS 語音輸入。在你的 Mac 上轉錄、用確定性規則整理、貼到游標所在的地方。",
}

ZH = {
    # nav
    '<a href="#modes">Modes</a><a href="#privacy">Privacy</a><a href="#install">Install</a>': '<a href="#modes">模式</a><a href="#privacy">隱私</a><a href="#install">安裝</a>',
    # hero
    'Local-first dictation for macOS': '本機優先的 macOS 語音輸入',
    'Speak.<br>It types.': '你說。<br>它打字。',
    "A menu bar app that turns your voice into clean, paste-ready text. Transcription runs on your Mac. Cleanup is deterministic first, model second. Nothing leaves the machine unless you say so.":
        "一個 menu bar 小工具，把你的聲音變成乾淨、可直接貼上的文字。轉錄在你的 Mac 上跑；整理先走確定性規則，模型只是輔助。你不點頭，什麼都不會離開這台機器。",
    'Download for Mac': '下載 Mac 版', 'View source': '看原始碼',
    '<b>Free</b> · Open source · MIT · No account, no API key required': '<b>免費</b>・開源・MIT・不用帳號、不用 API key',
    'UTUVO Type mark: a glass speech bubble with a text cursor, beside a waveform, three dots and a microphone': 'UTUVO Type 標誌：玻璃語音泡泡與文字游標，旁邊是波形、三個點與麥克風',
    # steps
    'The UTUVO Type menu bar popover with four modes and a Start dictation button': 'UTUVO Type 的 menu bar 面板：四種模式與開始聽寫按鈕',
    '<h3>Press the shortcut</h3><small>⌥Space by default, or hold it for push-to-talk. Any key you like.</small>': '<h3>按快捷鍵</h3><small>預設 ⌥Space，按住就是 push-to-talk。想換哪顆鍵都行。</small>',
    "<h3>Say it</h3><small>A small capsule shows you're live. Esc cancels. Nothing is recorded until you start.</small>": '<h3>開口說</h3><small>小膠囊告訴你正在錄。Esc 取消。你沒按之前不會錄任何東西。</small>',
    "<h3>It lands where your cursor is</h3><small>Punctuation, fillers, numbers and your own dictionary — cleaned up and pasted into the app you're in.</small>": '<h3>落在游標所在的地方</h3><small>標點、贅詞、數字、你的個人字典——整理好，貼進你正在用的 app。</small>',
    # modes
    'Four modes': '四種模式', 'Pick how much help you want.': '你決定要多少幫忙。',
    'Fast never calls a large model. The others only do what you ask, and fall back to the deterministic path if a model fails.': 'Fast 永遠不呼叫大模型。其他模式只做你要求的事，模型失敗就退回確定性路徑。',
    'Transcribe and normalize on-device. Instant, predictable, no LLM.': '本機轉錄＋規則整理。即時、可預期、沒有 LLM。',
    'A small local editor tidies sentences. Still on your Mac.': '本機小型 editor 順句子。還是在你的 Mac 上。',
    'Select text, say what to change. The rewrite replaces the selection.': '選一段文字，說你要改什麼。改寫結果直接取代選取。',
    'Long-form notes with a larger model — local 27B or cloud, only when you choose it.': '長文筆記交給大一點的模型——本機 27B 或雲端，只在你選擇時。',
    # chinese
    'Built for Traditional Chinese': '為繁體中文而做', 'Cleanup you can predict.': '看得懂的整理邏輯。',
    'Most of the polish is rules, not guesses. The same input gives the same output, every time.': '大部分的修飾是規則，不是猜測。同樣的輸入永遠得到同樣的輸出。',
    'Chinese punctuation, spacing between CJK and Latin, filler words removed': '中文標點、中英之間的空格、贅詞去除',
    "Numbers, dates and amounts written the way you'd type them": '數字、日期、金額寫成你自己會打的樣子',
    'Taiwan wording for software and everyday terms; mixed English stays English': '台灣用語（軟體、日常詞）；夾雜的英文保持英文',
    'A personal dictionary for names, products and jargon': '個人字典：人名、產品名、術語',
    'Per-app presets: a terse style for chat, a fuller one for documents': '依 app 的預設：聊天用簡短風格、文件用完整風格',
    'UTUVO Type settings, General tab, with Liquid Glass sidebar and cards': 'UTUVO Type 設定「一般」分頁：Liquid Glass 側欄與卡片',
    # privacy
    'Private by default': '預設就是私密', 'Your voice stays on your Mac.': '你的聲音留在你的 Mac 上。',
    'The default install is fully local: Qwen3-ASR 0.6B running through MLX on Apple silicon. No account, no telemetry, no network after setup.': '預設安裝完全本機：Qwen3-ASR 0.6B 透過 MLX 在 Apple silicon 上跑。沒有帳號、沒有遙測、裝好之後不需要網路。',
    'Accessibility is used to read the focused field and paste back — never the whole screen': '輔助使用只用來讀取目前輸入框與貼回——從不讀整個螢幕',
    'Recording is always announced by the capsule and a sound cue': '錄音一定有膠囊與提示音，不會偷偷錄',
    'Cloud formatting is a separate, opt-in adapter with your own key, stored in the Keychain': '雲端整理是獨立、需要你打開的 adapter，用你自己的 key，存在 Keychain',
    'Everything is in the open: read the routing rules, run the benchmark, audit the prompts': '全部公開：路由規則看得到、benchmark 跑得動、prompt 查得到',
    'UTUVO Type settings, Models tab, showing the local model and optional cloud models': 'UTUVO Type 設定「模型」分頁：本機模型與選配雲端模型',
    # native
    'Native, top to bottom': '從頭到尾都是原生', 'Liquid Glass. Light and dark.': 'Liquid Glass。淡色與深色。',
    'Swift, AppKit and SwiftUI. Built against the macOS 26 design language with a Liquid Glass popover, floating sidebar and a tiny overlay capsule — and a plain material fallback on macOS 14 and 15.': 'Swift、AppKit 與 SwiftUI。依 macOS 26 的設計語言：Liquid Glass 面板、浮動側欄、一顆小小的狀態膠囊；macOS 14、15 退回一般材質。',
    'Listening capsule with an orange waveform': '聆聽中的膠囊：橘色波形', 'Processing capsule with three lavender dots': '處理中的膠囊：三個薰衣草色點', 'Listening capsule in dark mode': '深色模式的聆聽膠囊',
    'The UTUVO Type popover in dark mode': '深色模式的 UTUVO Type 面板',
    # install
    'Three commands.': '三行指令。',
    'Or grab the signed, notarized build from Releases. Building from source takes about a minute plus a one-time 1.2 GB model download.': '或直接從 Releases 下載已簽名、已公證的版本。從原始碼建置約一分鐘，外加一次性的 1.2 GB 模型下載。',
    '# Python venv + Qwen3-ASR model, one time': '# Python venv＋Qwen3-ASR 模型，一次性',
    '<span><b>Apple silicon</b> for the local engine</span><span><b>macOS 14+</b> · Liquid Glass on 26+</span><span><b>8 GB</b> memory for Fast · <b>16 GB</b> for the local editor</span><span><b>~1.5 GB</b> disk for the model</span><span><b>Intel Macs</b> can use cloud or built-in speech</span>':
        '<span>本機引擎需要 <b>Apple silicon</b></span><span><b>macOS 14+</b>・26+ 有 Liquid Glass</span><span>Fast 需 <b>8 GB</b> 記憶體・本機 editor 建議 <b>16 GB</b></span><span>模型約占 <b>1.5 GB</b></span><span><b>Intel Mac</b> 可走雲端或系統內建語音</span>',
    'The DMG is small: the speech model is not inside it. Settings → General → <b>Install Local Engine</b> downloads Qwen3-ASR 0.6B (about 1.2 GB, once) into your Application Support folder. Nothing is downloaded until you click.':
        'DMG 很小：語音模型不在裡面。設定 → 一般 → <b>安裝本機引擎</b>會把 Qwen3-ASR 0.6B（約 1.2 GB，一次性）下載到你的 Application Support 資料夾。你沒按之前不會下載任何東西。',
    # footer
    'MIT License</a> · The UTUVO Type name and mark are not part of the license.': 'MIT 授權</a>・「UTUVO Type」名稱與標誌不在授權範圍內。',
    'Made in Taipei · <a href="https://github.com/mickyyang-1407/utuvo-type/blob/main/PRIVACY.md">Privacy</a> · <a href="https://github.com/mickyyang-1407/utuvo-type/issues">Issues</a>': '台北製造・<a href="https://github.com/mickyyang-1407/utuvo-type/blob/main/PRIVACY.md">隱私</a>・<a href="https://github.com/mickyyang-1407/utuvo-type/issues">回報問題</a>',
}
NAV = {'Modes': '模式', 'Privacy': '隱私', 'Install': '安裝'}


def build(lang):
    s = tpl
    base = '' if lang == 'en' else '../'
    if lang == 'zh':
        for en, zh in ZH.items():
            if en not in s:
                sys.exit(f'zh: string not found in template: {en[:70]}')
            s = s.replace(en, zh)
        s = s.replace('.eyebrow{font-size:.8rem;font-weight:700;letter-spacing:.14em;text-transform:uppercase;', '.eyebrow{font-size:.8rem;font-weight:700;letter-spacing:.08em;')
        s = s.replace('--font:-apple-system,', '--font:-apple-system,BlinkMacSystemFont,"PingFang TC","Noto Sans TC",')
        s = s.replace('<a href="./" data-lang="en">EN</a><a href="zh/" data-lang="zh">中文</a>',
                      '<a href="../" data-lang="en">EN</a><a href="./" data-lang="zh" aria-current="page">中文</a>')
    else:
        s = s.replace('<a href="./" data-lang="en">EN</a>', '<a href="./" data-lang="en" aria-current="page">EN</a>')
    s = s.replace('src="assets/', f'src="{base}assets/')
    s = s.replace('<script>\n</script>', '<script>\n' + '''document.querySelectorAll('.lang a').forEach(function(a){a.addEventListener('click',function(){try{localStorage.setItem('type-lang',a.dataset.lang)}catch(e){}})});
''' + ("try{if(!localStorage.getItem('type-lang')&&/^zh/i.test(navigator.language)){location.replace('zh/')}}catch(e){}\n" if lang == 'en' else '') + '</script>', 1)
    head = HEAD.format(lang='en' if lang == 'en' else 'zh-Hant', desc=DESC[lang], base=base, site=SITE)
    i = s.index('</style>') + len('</style>')
    out = head + s[:i] + '\n</head>\n<body>\n' + s[i:].lstrip('\n') + '\n</body>\n</html>\n'
    path = os.path.join(ROOT, 'docs', 'index.html' if lang == 'en' else 'zh/index.html')
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, 'w', encoding='utf-8').write(out)
    print('wrote', os.path.relpath(path, ROOT), len(out))


build('en')
build('zh')

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
    'zh': "UTUVO Type，免費開源、本機優先的 macOS 語音輸入。在你的 Mac 上轉錄，用規則整理，貼到游標所在的地方。",
}

ZH = {
    # nav
    '<a href="#modes">Modes</a><a href="#privacy">Privacy</a><a href="#install">Install</a>': '<a href="#modes">模式</a><a href="#privacy">隱私</a><a href="#install">安裝</a>',
    # hero
    'Local-first dictation for macOS': '本機優先的 macOS 語音輸入',
    'Speak.<br>It types.': '你說。<br>它打字。',
    "A menu bar app that turns your voice into clean, paste-ready text. Transcription runs on your Mac. Cleanup is deterministic first, model second. Nothing leaves the machine unless you say so.":
        "住在 menu bar 的語音輸入。你講話，它在你的 Mac 上轉成文字、整理好，貼到游標所在的地方。整理大多靠規則，模型只在你選的模式裡介入。沒有打開雲端的話，不會有任何東西離開這台電腦。",
    'Download for Mac': '下載 Mac 版', 'View source': '看原始碼',
    '<b>Free</b> · Open source · MIT · No account, no API key required': '<b>免費</b>・開源・MIT・不用帳號、不用 API key',
    'UTUVO Type mark: a glass speech bubble with a text cursor, beside a waveform, three dots and a microphone': 'UTUVO Type 標誌：玻璃語音泡泡與文字游標，旁邊是波形、三個點與麥克風',
    # steps
    'The UTUVO Type menu bar popover with four modes and a Start dictation button': 'UTUVO Type 的 menu bar 面板：四種模式與開始聽寫按鈕',
    '<h3>Press the shortcut</h3><small>⌥Space by default, or hold it for push-to-talk. Any key you like.</small>': '<h3>按快捷鍵</h3><small>預設是 ⌥Space，按住不放就是 push-to-talk，快捷鍵可以自己改。</small>',
    "<h3>Say it</h3><small>A small capsule shows you're live. Esc cancels. Nothing is recorded until you start.</small>": '<h3>開口說</h3><small>螢幕上會出現一顆小膠囊表示正在錄音，按 Esc 取消。沒按快捷鍵的時候麥克風不會開。</small>',
    "<h3>It lands where your cursor is</h3><small>Punctuation, fillers, numbers and your own dictionary — cleaned up and pasted into the app you're in.</small>": '<h3>貼到游標所在的地方</h3><small>整理完標點、贅詞、數字和你字典裡的詞之後，直接貼進你正在用的 app。</small>',
    # modes
    'Four modes': '四種模式', 'Pick how much help you want.': '差別在模型介入多少。',
    'Fast never calls a large model. The others only do what you ask, and fall back to the deterministic path if a model fails.': 'Fast 完全不用大模型。其他三種只在你選的時候才用模型，模型出錯就退回規則路徑。',
    'Transcribe and normalize on-device. Instant, predictable, no LLM.': '本機轉錄加規則整理，最快，結果也最可預期。',
    'A small local editor tidies sentences. Still on your Mac.': '本機的小型 editor 幫你順句子，一樣不出這台 Mac。',
    'Select text, say what to change. The rewrite replaces the selection.': '先選一段文字，再用講的說要改什麼，改好的版本直接取代原本那段。',
    'Long-form notes with a larger model — local 27B or cloud, only when you choose it.': '長篇筆記交給比較大的模型，本機 27B 或雲端都可以，要你自己選才會用。',
    # chinese
    'Built for Traditional Chinese': '為繁體中文而做', 'Cleanup you can predict.': '整理的結果可以預期。',
    'Most of the polish is rules, not guesses. The same input gives the same output, every time.': '大部分整理靠規則，同樣的輸入每次都得到同樣的輸出。',
    'Chinese punctuation, spacing between CJK and Latin, filler words removed': '補中文標點，中英文之間留空格，去掉贅詞',
    "Numbers, dates and amounts written the way you'd type them": '數字、日期、金額照你平常打字的寫法',
    'Taiwan wording for software and everyday terms; mixed English stays English': '用台灣的用語，夾在中間的英文照原樣保留',
    'A personal dictionary for names, products and jargon': '個人字典，放人名、產品名和專有名詞',
    'Per-app presets: a terse style for chat, a fuller one for documents': '可以依 app 設定風格，例如聊天軟體用短句，文件用完整句子',
    'UTUVO Type settings, General tab, with Liquid Glass sidebar and cards': 'UTUVO Type 設定「一般」分頁：Liquid Glass 側欄與卡片',
    # privacy
    'Private by default': '預設不連網', 'Your voice stays on your Mac.': '你的聲音留在你的 Mac 上。',
    'The default install is fully local: Qwen3-ASR 0.6B running through MLX on Apple silicon. No account, no telemetry, no network after setup.': '預設安裝就是純本機，語音辨識用 Qwen3-ASR 0.6B，透過 MLX 在 Apple silicon 上跑。不用帳號，沒有遙測，模型裝好之後不需要網路。',
    'Accessibility is used to read the focused field and paste back — never the whole screen': '輔助使用權限只拿來讀目前的輸入框和貼回文字，不會讀整個螢幕',
    'Recording is always announced by the capsule and a sound cue': '錄音時一定有膠囊和提示音',
    'Cloud formatting is a separate, opt-in adapter with your own key, stored in the Keychain': '雲端整理要自己打開，用你自己的 API key，key 存在 Keychain',
    'Everything is in the open: read the routing rules, run the benchmark, audit the prompts': '程式碼全部公開，路由規則、benchmark 和 prompt 都在 repo 裡',
    'UTUVO Type settings, Models tab, showing the local model and optional cloud models': 'UTUVO Type 設定「模型」分頁：本機模型與選配雲端模型',
    # native
    'Native, top to bottom': '原生 macOS app', 'Liquid Glass. Light and dark.': 'Liquid Glass 介面，深淺色都有。',
    'Swift, AppKit and SwiftUI. Built against the macOS 26 design language with a Liquid Glass popover, floating sidebar and a tiny overlay capsule — and a plain material fallback on macOS 14 and 15.': '用 Swift、AppKit 和 SwiftUI 寫的。介面照 macOS 26 的 Liquid Glass 做，menu bar 面板、浮動側欄和錄音時的小膠囊都是玻璃；macOS 14 和 15 會退回一般材質。',
    'Listening capsule with an orange waveform': '聆聽中的膠囊：橘色波形', 'Processing capsule with three lavender dots': '處理中的膠囊：三個薰衣草色點', 'Listening capsule in dark mode': '深色模式的聆聽膠囊',
    'The UTUVO Type popover in dark mode': '深色模式的 UTUVO Type 面板',
    # install
    'Three commands.': '三行指令。',
    'Or grab the signed, notarized build from Releases. Building from source takes about a minute plus a one-time 1.2 GB model download.': '也可以直接到 Releases 下載已簽名、已公證的版本。從原始碼建置大約一分鐘，另外要下載一次 1.2 GB 的模型。',
    '# Python venv + Qwen3-ASR model, one time': '# Python venv＋Qwen3-ASR 模型，一次性',
    '<span><b>Apple silicon</b> for the local engine</span><span><b>macOS 14+</b> · Liquid Glass on 26+</span><span><b>8 GB</b> memory for Fast · <b>16 GB</b> for the local editor</span><span><b>~1.5 GB</b> disk for the model</span><span><b>Intel Macs</b> can use cloud or built-in speech</span>':
        '<span>本機引擎需要 <b>Apple silicon</b></span><span><b>macOS 14+</b>・26+ 有 Liquid Glass</span><span>Fast 需 <b>8 GB</b> 記憶體・本機 editor 建議 <b>16 GB</b></span><span>模型約占 <b>1.5 GB</b></span><span><b>Intel Mac</b> 可走雲端或系統內建語音</span>',
    'The DMG is small: the speech model is not inside it. Settings → General → <b>Install Local Engine</b> downloads Qwen3-ASR 0.6B (about 1.2 GB, once) into your Application Support folder. Nothing is downloaded until you click.':
        'DMG 本身很小，語音模型不在裡面。開啟設定 → 一般 → <b>安裝本機引擎</b>，會把 Qwen3-ASR 0.6B（約 1.2 GB）下載到你的 Application Support 資料夾，只下載這一次，而且要你按了才會開始。',
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

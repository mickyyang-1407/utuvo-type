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
    'en': "UTUVO Type — free, open-source voice typing. A keyboard with an orb for iPhone, and a local-first menu bar app for Mac.",
    'zh': "UTUVO Type，免費開源的語音輸入：iPhone 上是一顆光球鍵盤，Mac 上是本機優先的選單列 app。",
}

ZH = {
    # nav
    '<a href="#iphone">iPhone</a><a href="#mac">Mac</a><a href="#privacy">Privacy</a>': '<a href="#iphone">iPhone</a><a href="#mac">Mac</a><a href="#privacy">隱私</a>',
    # hero
    'Voice typing for iPhone and Mac': 'iPhone 與 Mac 的語音輸入',
    'Speak.<br>It types.': '你說。<br>它打字。',
    'Tap the orb on the keyboard, say what you mean, and clean text lands at your cursor — in any app. On-device first, no account, open source.':
        '點一下鍵盤上的光球，把話說完，整理好的文字就出現在游標的位置——任何 app 都可以。裝置端優先，不用帳號，程式碼開源。',
    '>Download for Mac</a>': '>下載 Mac 版</a>',
    'View source': '看原始碼',
    '<b>iPhone</b><span class="status"><i></i>In App Store review — coming soon</span>': '<b>iPhone</b><span class="status"><i></i>App Store 審核中，即將上架</span>',
    '<b>Mac</b><span>Free download, signed and notarized</span>': '<b>Mac</b><span>免費下載，已簽章與公證</span>',
    'The UTUVO Type keyboard in Messages while dictating: the live transcript runs along the top, the orb glows in the middle': '在「訊息」裡用 UTUVO Type 鍵盤聽寫：上方跑即時字幕，中間是光球',
    # iPhone
    'A keyboard with an orb in it.': '一個有光球的鍵盤。',
    'Switch to UTUVO Type with the globe key, then talk. The orb moves with your voice; tap it again and the finished text is inserted once, where your cursor is.':
        '按地球鍵切到 UTUVO Type 就能開口說。光球會跟著你的聲音動；說完再點一下，整理好的文字只會插入一次，就在游標的位置。',
    'Holding the orb shows up to five languages in an arc above it': '長按光球，上方弧線排出最多五種語言',
    'Hold the orb to translate': '長按光球翻譯',
    'Slide to a language and let go. Speak Chinese, get English or Japanese — pick up to five languages.': '滑到語言放開。說中文，打出英文或日文——語言可以自己挑，最多五種。',
    'The app with a finished dictation and buttons for Say how to change it, Copy and Translate': '聽寫完成的畫面，下方有「說出要怎麼改」「複製」「翻譯」',
    'Say how to change it': '說出要怎麼改',
    'Select some text and say “make it more formal” or “add the time”. The rewrite replaces the selection — with Apple Intelligence on the device, or your own cloud key.':
        '選取一段文字，說「改成正式一點」或「加上時間」，改好的版本直接取代選取——在裝置上用 Apple Intelligence，或用你自己的雲端 key。',
    'The built-in Zhuyin keyboard with candidates along the top': '內建注音鍵盤，上方是候選字',
    'The built-in Pinyin keyboard typing Traditional Chinese': '內建拼音鍵盤打繁體字',
    'Fix a word without leaving': '打錯字，當場改',
    'EN, 繁 and 简 sit beside the orb. Correct a word with English, Zhuyin or Pinyin — Traditional or Simplified — then tap Voice to keep talking.':
        'EN、繁、简 就在光球旁邊。用英文、注音或拼音改一個字——繁體簡體都行——改完點「語音」繼續說。',
    'History grouped by day, with star and copy buttons on each dictation': '依日期分組的歷史紀錄，每筆都能加星號、複製',
    'Everything you said, on your phone': '說過的話，都留在手機上',
    'Each dictation is kept on the device — searchable, starrable, one tap to copy. A personal dictionary teaches it the names and jargon you use.':
        '每次聽寫都存在手機裡，可以搜尋、加星號、一鍵複製。個人字典讓它學會你常講的人名和專有名詞。',
    'The app home screen in Traditional Chinese': '繁體中文介面的主畫面',
    'The same screen in Simplified Chinese': '同一個畫面的簡體中文介面',
    'Traditional and Simplified Chinese': '繁體與簡體中文',
    'The app follows your iPhone’s language: Traditional Chinese with Taiwan wording, or Simplified Chinese with mainland terms. English dictation works too.':
        'app 跟著 iPhone 的語言走：繁體中文用台灣用語，簡體中文用大陸用語。也能用英文聽寫。',
    # Mac
    'A menu bar app for everything you write.': '一個選單列 app，寫什麼都能用。',
    'Transcription runs on your Mac with a local model. Cleanup is rules first, a model only when you ask.': '在你的 Mac 上用本機模型轉錄。整理先靠規則，要你開口才用模型。',
    'The UTUVO Type menu bar popover with four modes and a Start dictation button': 'UTUVO Type 的選單列面板：四種模式與開始聽寫按鈕',
    '<h3>Press the shortcut</h3><small>⌥Space by default, or hold it for push-to-talk. Any key you like.</small>': '<h3>按快捷鍵</h3><small>預設是 ⌥Space，按住不放就是 push-to-talk，快捷鍵可以自己改。</small>',
    "<h3>Say it</h3><small>A small capsule shows you're live. Esc cancels. Nothing is recorded until you start.</small>": '<h3>開口說</h3><small>螢幕上會出現一顆小膠囊表示正在錄音，按 Esc 取消。沒按快捷鍵的時候麥克風不會開。</small>',
    "<h3>It lands where your cursor is</h3><small>Punctuation, fillers, numbers and your own dictionary — cleaned up and pasted into the app you're in.</small>": '<h3>貼到游標所在的地方</h3><small>整理完標點、贅詞、數字和你字典裡的詞之後，直接貼進你正在用的 app。</small>',
    'Transcribe and normalize on-device. Instant, predictable, no LLM.': '本機轉錄加規則整理，最快，結果也最可預期。',
    'A small local editor tidies sentences. Still on your Mac.': '本機的小型 editor 幫你順句子，一樣不出這台 Mac。',
    'Select text, say what to change. The rewrite replaces the selection.': '先選一段文字，再用講的說要改什麼，改好的版本直接取代原本那段。',
    'Long-form notes with a larger model — local 27B or cloud, only when you choose it.': '長篇筆記交給比較大的模型，本機 27B 或雲端都可以，要你自己選才會用。',
    'UTUVO Type settings on the Mac, General tab': 'Mac 版 UTUVO Type 設定「一般」分頁',
    # privacy
    'No account. No tracking. Open source.': '不用帳號。不追蹤。程式碼開源。',
    'On-device recognition first; turn on “Only on-device” and audio never leaves the phone': '裝置端辨識優先；打開「只用裝置端辨識」，音訊就永遠不離開手機',
    'Rewriting and translation use Apple Intelligence on the device; a cloud key is optional and yours': '改寫與翻譯在裝置上用 Apple Intelligence；雲端 key 是選配，用你自己的',
    'The keyboard never records what you type with the other keys': '鍵盤不會記錄你用其他按鍵打的字',
    'Full Access is needed only so the keyboard can ask the app to record — iOS keeps the microphone away from keyboards': '需要「允許完整存取」只是因為 iOS 不讓鍵盤用麥克風，鍵盤要請 app 代為錄音',
    'The default engine runs locally: Qwen3-ASR 0.6B through MLX on Apple silicon': '預設引擎在本機跑：Apple silicon 上用 MLX 執行 Qwen3-ASR 0.6B',
    'Accessibility is used to read the focused field and paste back — never the whole screen': '輔助使用權限只用來讀目前的輸入欄位並貼回去，不會讀整個螢幕',
    'Cloud formatting is opt-in, with your own key in the Keychain': '雲端整理要你自己打開，key 存在鑰匙圈',
    'Routing rules, prompts and benchmarks are all in the repository': '路由規則、提示詞、benchmark 都在 repo 裡',
    'Read the full <a href="privacy/">privacy policy</a>.': '完整說明請看<a href="privacy/">隱私權政策</a>。',
    # get
    'Get it': '下載', 'Free on both.': '兩邊都免費。',
    'Version 0.2.0 is in App Store review. This page will link to it as soon as it’s live.': '0.2.0 版正在 App Store 審核，上架後這裡會放連結。',
    '<span><b>iOS 17+</b></span><span><b>iPhone</b> only for now</span><span>Keyboard needs <b>Full Access</b></span>': '<span><b>iOS 17+</b></span><span>目前只支援 <b>iPhone</b></span><span>鍵盤需要<b>完整存取</b></span>',
    'Signed and notarized. The speech model is a one-time 1.2 GB download from Settings, only when you click.': '已簽章與公證。語音模型要在設定裡按一下才會下載，約 1.2 GB，只下載一次。',
    '<span><b>macOS 14+</b></span><span><b>Apple silicon</b> for the local engine</span><span><b>8 GB</b> memory · <b>16 GB</b> for the local editor</span>': '<span><b>macOS 14+</b></span><span>本機引擎需要 <b>Apple silicon</b></span><span>記憶體 <b>8 GB</b>・本機 editor 建議 <b>16 GB</b></span>',
    'Build from source': '從原始碼編譯',
    '# Python venv + Qwen3-ASR model, one time': '# Python venv＋Qwen3-ASR 模型，只要一次',
    # footer
    'The UTUVO Type name and mark are not part of the license.': 'UTUVO Type 名稱與標誌不在授權範圍內。',
    'Made in Taipei': '台北製作', '>Support</a>': '>問題回報</a>', '<a href="privacy/">Privacy</a>': '<a href="privacy/">隱私權</a>',
}
# 標題裡的 Privacy／iPhone／Mac 小標：eyebrow 與 h3 用詞
ZH_EYEBROW = {'<div class="eyebrow">Privacy</div>': '<div class="eyebrow">隱私</div>', '<div class="eyebrow">Get it</div>': '<div class="eyebrow">下載</div>'}
ZH.pop('Get it')
ZH.update(ZH_EYEBROW)


def build(lang):
    s = tpl
    base = '' if lang == 'en' else '../'
    if lang == 'zh':
        for en, zh in ZH.items():
            if en not in s:
                sys.exit(f'zh: string not found in template: {en[:70]}')
            s = s.replace(en, zh)
        for old, new in (('.eyebrow{font-size:.78rem;font-weight:700;letter-spacing:.12em;text-transform:uppercase;', '.eyebrow{font-size:.82rem;font-weight:700;letter-spacing:.08em;'),
                         ('--font:-apple-system,', '--font:-apple-system,BlinkMacSystemFont,"PingFang TC","Noto Sans TC",')):
            if old not in s:
                sys.exit(f'zh: CSS hook not found: {old[:50]}')  # 模板改了 CSS，這裡要跟著改，不准靜靜失效
            s = s.replace(old, new)
        s = s.replace('<a href="./" data-lang="en">EN</a><a href="zh/" data-lang="zh">中文</a>',
                      '<a href="../" data-lang="en">EN</a><a href="./" data-lang="zh" aria-current="page">中文</a>')
    else:
        s = s.replace('<a href="./" data-lang="en">EN</a>', '<a href="./" data-lang="en" aria-current="page">EN</a>')
    s = s.replace('src="assets/', f'src="{base}assets/')
    s = s.replace('href="privacy/"', f'href="{base}privacy/"')
    s = s.replace('srcset="assets/', f'srcset="{base}assets/')
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

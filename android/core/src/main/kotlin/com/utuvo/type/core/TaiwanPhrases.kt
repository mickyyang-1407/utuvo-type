package com.utuvo.type.core

/**
 * 台灣用語詞級轉換（移植自 Swift `UTUVOTypeCore/TaiwanPhrases.swift`，詞表由該檔自動轉出，不手抄）。
 * 方向固定＝大陸用語 → 台灣用語，長詞優先；使用者字典在這之後套用，永遠能覆寫。
 * 詞表參考 OpenCC 的 TWPhrases（Apache-2.0），人工挑選並改寫。
 */
object TaiwanPhrases {
    val table: Map<String, String> = linkedMapOf(
        "軟件" to "軟體", "硬件" to "硬體", "信息" to "資訊", "數據庫" to "資料庫", "數據" to "資料",
        "網絡" to "網路", "互聯網" to "網際網路", "服務器" to "伺服器", "視頻" to "影片", "音頻" to "音訊",
        "鼠標" to "滑鼠", "內存" to "記憶體", "硬盤" to "硬碟", "光盤" to "光碟", "U盤" to "隨身碟",
        "打印機" to "印表機", "打印" to "列印", "屏幕" to "螢幕", "顯示屏" to "顯示器", "文件夾" to "資料夾",
        "源代碼" to "原始碼", "代碼" to "程式碼", "編程" to "程式設計", "程序員" to "工程師", "程序" to "程式",
        "操作系統" to "作業系統", "默認" to "預設", "設置" to "設定", "登錄" to "登入", "註銷" to "登出",
        "賬號" to "帳號", "賬戶" to "帳戶", "用戶" to "使用者", "客戶端" to "用戶端", "鏈接" to "連結",
        "搜索" to "搜尋", "分辨率" to "解析度", "字節" to "位元組", "比特" to "位元", "芯片" to "晶片",
        "算法" to "演算法", "人工智能" to "人工智慧", "智能手機" to "智慧型手機", "移動電話" to "行動電話", "短信" to "簡訊",
        "郵箱" to "信箱", "攝像頭" to "攝影機", "充電寶" to "行動電源", "調製解調器" to "數據機", "帶寬" to "頻寬",
        "雲計算" to "雲端運算", "虛擬機" to "虛擬機器", "插件" to "外掛", "卸載" to "解除安裝", "激活" to "啟用",
        "兼容" to "相容", "優化" to "最佳化", "調試" to "除錯", "崩潰" to "當機", "死機" to "當機",
        "截屏" to "截圖", "復制" to "複製", "粘貼" to "貼上", "剪切" to "剪下", "撤銷" to "復原",
        "保存" to "儲存", "另存為" to "另存新檔", "菜單" to "選單", "窗口" to "視窗", "標籤頁" to "分頁",
        "收藏夾" to "書籤", "主頁" to "首頁", "博客" to "部落格", "點贊" to "按讚", "視頻通話" to "視訊通話",
        "屏幕錄製" to "螢幕錄影", "圖標" to "圖示", "光標" to "游標", "進度條" to "進度列", "滾動條" to "捲軸",
        "滾動" to "捲動", "複選框" to "核取方塊", "下拉菜單" to "下拉選單", "文本框" to "文字方塊", "文本" to "文字",
        "字體" to "字型", "字號" to "字級", "回車" to "換行", "觸摸屏" to "觸控螢幕", "觸摸" to "觸控",
        "二維碼" to "QR Code", "條形碼" to "條碼", "支付" to "付款", "快遞" to "宅配", "外賣" to "外送",
        "出租車" to "計程車", "公交車" to "公車", "自行車" to "腳踏車", "摩托車" to "機車", "打車" to "叫車",
        "酒店" to "飯店", "賓館" to "旅館", "衛生間" to "洗手間", "早上好" to "早安", "晚上好" to "晚安",
        "質量" to "品質", "水平" to "水準", "渠道" to "通路", "項目" to "專案", "領導" to "主管",
        "工資" to "薪水", "簡歷" to "履歷", "概率" to "機率", "幾率" to "機率", "信號" to "訊號",
        "土豆" to "馬鈴薯", "西紅柿" to "番茄", "酸奶" to "優格", "方便麵" to "泡麵", "奶酪" to "起司",
        "三文魚" to "鮭魚", "金槍魚" to "鮪魚", "菠蘿" to "鳳梨", "獼猴桃" to "奇異果", "幼兒園" to "幼稚園",
        "本科" to "大學部", "研究生" to "研究所", "課件" to "教材",
    )

    /** 長詞優先（避免「數據庫」被「數據」先吃掉）；同長度照字典序，順序固定。 */
    private val ordered: List<Pair<String, String>> =
        table.entries.sortedWith(compareByDescending<Map.Entry<String, String>> { SwiftText.count(it.key) }.thenBy { it.key })
            .map { it.key to it.value }

    fun apply(text: String): String {
        if (text.isEmpty()) return text
        var output = text
        for ((mainland, taiwan) in ordered) {
            if (output.contains(mainland)) output = output.replace(mainland, taiwan)
        }
        return fixCommonMisspellings(fixOnlyAsMeasureWord(output))
    }

    /** 辨識器簡轉繁把「只」轉成量詞「隻」（同 Swift fixOnlyAsMeasureWord）；前面是數字／指示詞＝真的量詞不動。 */
    private val onlyPattern = Regex("(?<![一二兩三四五六七八九十幾這那每哪半整])隻(?=要|是|有|能|好|會|剩|想|不過|限)")

    /** 常見且不會是正確用法的同音錯字（同 Swift fixCommonMisspellings）。 */
    private val misspellingPattern = Regex("(?<![原起主病肇死])因該")

    internal fun fixCommonMisspellings(text: String): String {
        var out = text
        if (out.contains("因該")) out = misspellingPattern.replace(out, "應該")
        return out.replace("除值", "儲值")
    }

    internal fun fixOnlyAsMeasureWord(text: String): String {
        if (!text.contains("隻")) return text
        return onlyPattern.replace(text, "只").replace("不隻", "不只")
    }
}

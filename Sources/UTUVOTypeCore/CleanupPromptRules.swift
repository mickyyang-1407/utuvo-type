import Foundation

/// 整理提示詞裡會依設定切換的規則（iOS／Mac 共用；Android 在 SmartCleanup.kt 有同樣兩句）。
///
/// 2026-10-19 Typeless 對打：Typeless 會把「首先…接著…另外」講步驟／重點的長段落整理成 1. 2. 3.，
/// Micky 認為這是它最強的地方。原本的規則刻意禁止，改成「自動條列」設定（預設開）：開著時換成條列規則，
/// 關掉時維持只分段。真人錄音實測：流程／分項的長段落變成清單，純敘述的照樣只分段。
public enum CleanupPromptRules {
    public static let paragraphKeepRule = "- 長段落（用「首先、另外、對了、接著、總之」串起來的說明）不要改成清單：**這些轉折詞一個都不能刪**，只在轉折處分段（空一行）。"
    // v3（2026-10-19 桌面對打回饋）：清單後的總結不編號；逐項列舉東西要給例子才穩；敘述段落一定在轉折詞前空行。
    public static let paragraphListRule = "- 說話者在講步驟、流程或幾個重點（用「首先、接著、然後、另外、最後」或「第一、第二」串起來）時，整理成編號清單：引言放第一行並以冒號結尾（例「這張專輯的製作流程：」），每個步驟或重點一行（1. 2. 3.），每項保留說話者的原話、數字與專有名詞，只拿掉當連接用的轉折詞；結尾的總結句（「總之…」）另起一行保留，不編號。\n- 一口氣列舉三樣以上的東西，也改成編號清單、一項一行：「幫我準備四樣東西，播放器、耳機、線材，還有轉接頭」→「幫我準備四樣東西：」下面 1. 播放器 2. 耳機 3. 線材 4. 轉接頭。\n- 只是在敘述、不是在列步驟或重點的長段落，不改清單，但一定要在每個轉折詞（首先、另外、對了、接著、總之）前面空一行分段，轉折詞一個都不能刪。"

    /// `autoList` 開著時把「長段落只分段」換成條列規則；指示裡沒有那句就原樣回傳。
    public static func apply(_ instructions: String, autoList: Bool) -> String {
        autoList ? instructions.replacingOccurrences(of: paragraphKeepRule, with: paragraphListRule) : instructions
    }
}

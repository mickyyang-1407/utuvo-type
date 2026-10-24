package com.utuvo.type.core

import kotlin.test.assertEquals
import kotlin.test.Test

/** 同 Swift SentenceMoodTests.testFinishDropsDanglingComma。 */
class SentenceMoodDanglingCommaTest {
    @Test
    fun finishDropsDanglingComma() {
        assertEquals("幫我準備四樣東西，播放器、耳機、線材、還有轉接頭",
            SentenceMood.finish("幫我準備四樣東西，播放器、耳機、線材、還有轉接頭，"))
        assertEquals("取樣率用96k", SentenceMood.finish("取樣率用96k，"))
        assertEquals("轉寄給小雅跟小潘 ", SentenceMood.finish("轉寄給小雅跟小潘、 "))
        assertEquals("，", SentenceMood.finish("，"))
        assertEquals("Hello world,", SentenceMood.finish("Hello world,"))
        assertEquals("第一段，\n\n第二段，", SentenceMood.finish("第一段，\n\n第二段，"))
    }

    @Test
    fun smallFormPunctuationIsFoldedBeforeCorrections() {
        val n = Normalizer()
        // 「﹐」換成「，」之後，數量＋頓號列舉的清單規則才認得（2026-10-22 W2-6 ls03 → 編號清單，同 Swift）。
        val out = n.normalize("幫我準備四樣東西﹐播放器、耳機、線材、還有轉接頭﹐").cleaned
        assertEquals("幫我準備四樣東西：\n1. 播放器\n2. 耳機\n3. 線材\n4. 轉接頭", out)
        assertEquals(out, SentenceMood.finish(out))
        // 沒有數量的列舉不成清單：照舊看到一般逗號、句尾吊著的逗號由 finish 拿掉。
        val plain = n.normalize("我準備了東西﹐播放器、耳機、線材﹐").cleaned
        assertEquals("我準備了東西，播放器、耳機、線材，", plain)
        assertEquals("我準備了東西，播放器、耳機、線材", SentenceMood.finish(plain))
        assertEquals("好；你呢？", Normalizer.foldSmallFormPunctuation("好﹔你呢﹖"))
        assertEquals("沒有小型標點", Normalizer.foldSmallFormPunctuation("沒有小型標點"))
    }
}

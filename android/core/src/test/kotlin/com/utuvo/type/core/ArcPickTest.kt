package com.utuvo.type.core

import com.utuvo.type.core.ArcPick.Point
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * mobile-keyboard-2：長按光球的選語言規則。座標同 Android 鍵盤（單位 dp）：
 * 光球中心 (0,0)、畫出來的半徑 49（120dp 方框 × 0.82 ÷ 2）、弧半徑 86、五顆點從 -160° 到 -20°。
 * iOS 之後照同一組座標測（同一條規則）。
 */
class ArcPickTest {
    private val orb = Point(0f, 0f)
    private val orbRadius = 49f
    private val max = ArcPick.MAX_DISTANCE_DP
    private val dots = (0 until 5).map { i ->
        val rad = Math.toRadians(-160.0 + 140.0 * i / 4)
        Point((86 * Math.cos(rad)).toFloat(), (86 * Math.sin(rad)).toFloat())
    }

    private fun pick(x: Float, y: Float) = ArcPick.resolve(Point(x, y), dots, orb, orbRadius, max)

    @Test
    fun `手指在光球中心不選任何一顆`() {
        // 舊版 iOS 一開始就預選中間那顆、Android 長按也先亮中間那顆：按住不動放開會開始翻譯。
        assertNull(pick(0f, 0f))
    }

    @Test
    fun `手指在某一顆的中心就選那一顆`() {
        assertEquals(2, pick(dots[2].x, dots[2].y))
        assertEquals(0, pick(dots[0].x, dots[0].y))
        assertEquals(4, pick(dots[4].x, dots[4].y))
    }

    @Test
    fun `光球上方離最近一顆六十就是取消`() {
        // dot[2] 在 (0,-86)；往上再 60 → 離它 60，離其他顆更遠。
        assertNull(pick(0f, -146f))
    }

    @Test
    fun `光球半徑內的上緣不選`() {
        // (0,-48) 離 dot[2] 只有 38（舊規則只看 56 門檻會選到 2），但它在光球圓內 → 取消。
        assertNull(pick(0f, -48f))
    }

    @Test
    fun `光球外、離語言點夠近就選最近那一顆`() {
        // 光球邊外一點、朝 dot[2]：離 dot[2] 36 → 選 2。
        assertEquals(2, pick(0f, -50f))
        // 兩顆之間偏向 dot[3]：選 3。
        val between = Point((dots[2].x + dots[3].x * 3) / 4, (dots[2].y + dots[3].y * 3) / 4)
        assertEquals(3, ArcPick.resolve(between, dots, orb, orbRadius, max))
    }

    @Test
    fun `距離剛好等於門檻不算選到`() {
        assertNull(pick(dots[2].x, dots[2].y - max))
        assertEquals(2, pick(dots[2].x, dots[2].y - (max - 1f)))
    }

    @Test
    fun `沒有語言點時一律不選`() {
        assertNull(ArcPick.resolve(Point(0f, -86f), emptyList(), orb, orbRadius, max))
    }

    @Test
    fun `光球圓內的判斷含邊上`() {
        assertTrue(ArcPick.insideOrb(Point(0f, -49f), orb, orbRadius))
        assertFalse(ArcPick.insideOrb(Point(0f, -49.5f), orb, orbRadius))
    }

    @Test
    fun `不用按住的提示只在光球上放開、按夠久、沒選到時出現`() {
        assertTrue(ArcPick.showsHoldTip(picked = null, releasedOnOrb = true, heldMillis = 1_000))
        assertTrue(ArcPick.showsHoldTip(picked = null, releasedOnOrb = true, heldMillis = ArcPick.HOLD_TIP_MILLIS))
        // 按不夠久：一般取消
        assertFalse(ArcPick.showsHoldTip(picked = null, releasedOnOrb = true, heldMillis = 599))
        // 拖到空白處放開：維持一般的取消提示
        assertFalse(ArcPick.showsHoldTip(picked = null, releasedOnOrb = false, heldMillis = 1_000))
        // 選到語言：照常開始翻譯
        assertFalse(ArcPick.showsHoldTip(picked = 2, releasedOnOrb = false, heldMillis = 1_000))
    }
}

package com.utuvo.type.core

/**
 * 長按光球翻譯：手指放在哪裡算選到哪一顆語言點（純函式，JVM 測得到；mobile-keyboard-2）。
 *
 * 規則（兩個平台要一致，iOS 之後照同一組座標測）：
 *  - 手指在光球的圓內 → 沒選（＝放開就取消）。以前按住不動放開也會選到中間那顆，
 *    習慣「按住說話」的人講完一放開就變成開始一段翻譯錄音。
 *  - 離每一顆都超過 [maxDistance] → 沒選。
 *  - 其餘選最近的那一顆。
 *
 * 座標單位由呼叫端決定（Android 傳螢幕像素，[maxDistance] 要先換成像素）。
 */
object ArcPick {
    /** 離語言點多遠以內算選到（dp；Android 舊版 nearestDot 就是這個門檻）。弧半徑 86dp、六顆點時間距約 42dp，兩顆之間不會誤取消。 */
    const val MAX_DISTANCE_DP = 56f

    /** 按住超過這麼久、在光球上放開、又沒選到語言，才提示「不用按住」。 */
    const val HOLD_TIP_MILLIS = 600L

    data class Point(val x: Float, val y: Float)

    private fun distance(a: Point, b: Point): Float {
        val dx = (a.x - b.x).toDouble()
        val dy = (a.y - b.y).toDouble()
        return Math.hypot(dx, dy).toFloat()
    }

    /** 手指是不是落在光球的圓內（含邊上）。 */
    fun insideOrb(finger: Point, orbCenter: Point, orbRadius: Float): Boolean =
        distance(finger, orbCenter) <= orbRadius

    /**
     * 選到第幾顆；null＝沒選（在光球上、或離每一顆都太遠）。
     * 距離剛好等於 [maxDistance] 不算選到（同舊版 `dist < bestD`）。
     */
    fun resolve(finger: Point, dots: List<Point>, orbCenter: Point, orbRadius: Float, maxDistance: Float): Int? {
        if (insideOrb(finger, orbCenter, orbRadius)) return null
        var best: Int? = null
        var bestDistance = maxDistance
        dots.forEachIndexed { i, dot ->
            val d = distance(finger, dot)
            if (d < bestDistance) { bestDistance = d; best = i }
        }
        return best
    }

    /**
     * 要不要提示「不用按住：點一下開始說，說完再點一下」。
     * 只在**放開位置落在光球圓內**、按住夠久、又沒有選到語言時才提示；拖到空白處放開維持一般的取消。
     */
    fun showsHoldTip(picked: Int?, releasedOnOrb: Boolean, heldMillis: Long): Boolean =
        picked == null && releasedOnOrb && heldMillis >= HOLD_TIP_MILLIS
}

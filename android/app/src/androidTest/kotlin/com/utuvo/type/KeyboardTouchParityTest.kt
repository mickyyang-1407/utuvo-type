package com.utuvo.type

import android.content.Context
import android.os.SystemClock
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.TextView
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * A4 鍵盤手勢對齊 iPhone（正本：`ios/Keyboard/TypingKeyboardView.swift`、`ios/Keyboard/KeyboardViewController.swift`）。
 * 走實際的 [KeyboardView] 接線，用 dispatchTouchEvent 送觸控序列。
 */
@RunWith(AndroidJUnit4::class)
class KeyboardTouchParityTest {

    private val app: Context = InstrumentationRegistry.getInstrumentation().targetContext
    private val inst get() = InstrumentationRegistry.getInstrumentation()

    /** 記錄鍵盤打出來的每一個動作，收回時才知道有沒有真的還原。 */
    private class Recorder : KeyboardView.Listener {
        // 長按連刪是主執行緒的 Handler 在加，測試執行緒同時在讀 → 要有同步。
        val events: MutableList<String> = java.util.Collections.synchronizedList(ArrayList())
        val surfaces: MutableList<KeyboardView.Surface> = java.util.Collections.synchronizedList(ArrayList())
        override fun onOrbTap() { events += "orb" }
        override fun onTranslatePick(target: Translation.Target) {}
        override fun onTranslateArm() {}
        override fun onTranslateCancel() {}
        override fun onSurfaceChanged(surface: KeyboardView.Surface) { surfaces += surface }
        override fun onCompose(key: Char) { events += "compose:$key" }
        override fun onInsert(text: String) { events += "insert:$text" }
        override fun onDelete() { events += "delete" }
        override fun onSpace() { events += "space" }
        override fun onEnter() { events += "enter" }
        override fun onPickCandidate(index: Int) {}
        override fun onDictationLanguage(language: DictationLanguage) { events += "lang:${language.code}" }
        override fun onToggleCandidatePanel() { events += "togglePanel" }
        override fun onToggleHantInput() {}
        override fun onSwitchKeyboard() {}
        override fun onUndoInsert(text: String) { events += "undoInsert:$text" }
        override fun onUndoCompose() { events += "undoCompose" }
        override fun onUndoDelete() { events += "undoDelete" }
        override fun onUndoSpace() { events += "undoSpace" }
    }

    private lateinit var kb: KeyboardView
    private lateinit var rec: Recorder

    @Before fun setUp() {
        rec = Recorder()
        inst.runOnMainSync {
            kb = KeyboardView(app, rec)
            kb.setEnterLabel("return")
            val parent = FrameLayout(app)
            parent.addView(kb, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
            parent.measure(
                View.MeasureSpec.makeMeasureSpec(1080, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(1000, View.MeasureSpec.EXACTLY)
            )
            parent.layout(0, 0, 1080, 1000)
        }
    }

    private fun show(surface: KeyboardView.Surface, pinyin: Boolean = false) = inst.runOnMainSync {
        kb.show(surface, pinyin)
        relayout()
    }

    private fun relayout() {
        val parent = kb.parent as ViewGroup
        parent.measure(
            View.MeasureSpec.makeMeasureSpec(1080, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(1000, View.MeasureSpec.EXACTLY)
        )
        parent.layout(0, 0, 1080, 1000)
    }

    private fun key(label: String): TextView? = findByText(kb, label)

    private fun keyOrFail(label: String): TextView =
        key(label) ?: error("鍵盤上找不到鍵：$label")

    // ── 1. 按下就出字，手指滑開就收回 ──

    @Test fun letterKey_insertsOnDown_andSlideOffUndoes() {
        show(KeyboardView.Surface.EN)
        inst.runOnMainSync {
            val q = keyOrFail("Q")
            tap(q)
            assertEquals("按下的當下就要出字", listOf("insert:Q"), rec.events)
            rec.events.clear()
            // 滑開超過 20dp（同 iOS KeyButton 的 20pt）
            send(q, MotionEvent.ACTION_MOVE, q.width / 2f + 1000f, q.height / 2f)
            send(q, MotionEvent.ACTION_UP, q.width / 2f + 1000f, q.height / 2f)
            assertEquals("滑開要把剛才那個字收回來", listOf("undoInsert:Q"), rec.events)
        }
    }

    @Test fun letterKey_smallMove_isNotAnUndo() {
        show(KeyboardView.Surface.EN)
        inst.runOnMainSync {
            val q = keyOrFail("Q")
            tap(q)
            rec.events.clear()
            // 位移小於 20dp（在密度 1 的機器上 5px），不算滑開
            send(q, MotionEvent.ACTION_MOVE, q.width / 2f + 5f, q.height / 2f)
            send(q, MotionEvent.ACTION_UP, q.width / 2f + 5f, q.height / 2f)
            assertTrue("小幅移動不是收回：${rec.events}", rec.events.isEmpty())
        }
    }

    @Test fun composeKey_slideOffUndoesOneSyllable() {
        show(KeyboardView.Surface.HANT)   // 注音
        inst.runOnMainSync {
            val b = keyOrFail("ㄅ")
            tap(b)
            assertEquals(listOf("compose:ㄅ"), rec.events)
            rec.events.clear()
            send(b, MotionEvent.ACTION_MOVE, b.width / 2f + 1000f, b.height / 2f)
            send(b, MotionEvent.ACTION_UP, b.width / 2f + 1000f, b.height / 2f)
            assertEquals("組字鍵滑開要退回引擎", listOf("undoCompose"), rec.events)
        }
    }

    @Test fun spaceKey_slideOffUndoes() {
        show(KeyboardView.Surface.EN)
        inst.runOnMainSync {
            val space = keyOrFail("space")
            tap(space)
            assertEquals(listOf("space"), rec.events)
            rec.events.clear()
            send(space, MotionEvent.ACTION_MOVE, space.width / 2f + 1000f, space.height / 2f)
            send(space, MotionEvent.ACTION_UP, space.width / 2f + 1000f, space.height / 2f)
            assertEquals("空白滑開要收回（中文組字送出時要連組字一起還原）", listOf("undoSpace"), rec.events)
        }
    }

    @Test fun deleteKey_slideOffPutsTheCharacterBack() {
        show(KeyboardView.Surface.EN)
        inst.runOnMainSync {
            val del = findByDesc(kb, app.getString(R.string.key_delete))
            assertNotNull("找不到刪除鍵", del)
            tap(del!!)
            assertEquals("刪除也是按下就刪", listOf("delete"), rec.events)
            rec.events.clear()
            send(del, MotionEvent.ACTION_MOVE, del.width / 2f + 1000f, del.height / 2f)
            send(del, MotionEvent.ACTION_UP, del.width / 2f + 1000f, del.height / 2f)
            assertEquals("滑開＝其實要切換鍵盤：把剛刪掉的字補回去", listOf("undoDelete"), rec.events)
        }
    }

    @Test fun deleteKey_cancelAlsoUndoes() {
        show(KeyboardView.Surface.EN)
        inst.runOnMainSync {
            val del = findByDesc(kb, app.getString(R.string.key_delete))!!
            tap(del)
            rec.events.clear()
            send(del, MotionEvent.ACTION_CANCEL, del.width / 2f, del.height / 2f)
            assertEquals("觸控被取消也要收回", listOf("undoDelete"), rec.events)
        }
    }

    // ── 2. 長按刪除連續刪 ──

    @Test fun deleteKey_longPressRepeats() {
        show(KeyboardView.Surface.EN)
        val del = findByDesc(kb, app.getString(R.string.key_delete))!!
        inst.runOnMainSync { send(del, MotionEvent.ACTION_DOWN, del.width / 2f, del.height / 2f) }
        assertEquals("按下先刪一次", 1, rec.events.size)
        SystemClock.sleep(700)                       // 主執行緒在這段時間會跑 repeat
        val afterHold = rec.events.size
        inst.runOnMainSync { send(del, MotionEvent.ACTION_UP, del.width / 2f, del.height / 2f) }
        assertTrue("按住要連續刪：按完只有 $afterHold 次", afterHold > 1)
        SystemClock.sleep(400)
        assertEquals("放開之後不能還在刪", afterHold, rec.events.size)
    }

    // ── 3. 英文大小寫 ──

    @Test fun shift_doubleTapLocks() {
        show(KeyboardView.Surface.EN)
        inst.runOnMainSync {
            val shift = keyOrFail("⇧")
            tap(shift)                                 // 第一次：ONCE → OFF
            assertNotNull("關掉之後字母是小寫", key("q"))
            tap(keyOrFail("⇧"))                        // 0.3 秒內第二次 → 鎖定
            assertNotNull("鎖定＝字母一直大寫", key("Q"))
            assertNotNull("鎖定的圖示是 ⇪", key("⇪"))
        }
    }

    @Test fun autoCapitalization_followsTheTextBeforeTheCursor() {
        show(KeyboardView.Surface.EN)
        inst.runOnMainSync {
            kb.updateAutoCapitalization("")             // 開頭
            assertNotNull("游標前是空的 → 大寫", key("Q"))
            kb.updateAutoCapitalization("hello. ")      // 句號＋空白
            assertNotNull("句末標點後 → 大寫", key("Q"))
            kb.updateAutoCapitalization("hello ")       // 只是空白
            assertNotNull("一般空白後 → 小寫", key("q"))
            kb.updateAutoCapitalization("hello")        // 句中
            assertNotNull("句中 → 小寫", key("q"))
            kb.updateAutoCapitalization("hi.\n")        // 換行後
            assertNotNull("換行後 → 大寫", key("Q"))
        }
    }

    @Test fun autoCapitalization_doesNotTouchLockedShift() {
        show(KeyboardView.Surface.EN)
        inst.runOnMainSync {
            tap(keyOrFail("⇧")); tap(keyOrFail("⇧"))    // 鎖定
            kb.updateAutoCapitalization("hello ")
            assertNotNull("鎖定中的 Shift 不被自動大寫改掉", key("Q"))
        }
    }

    @Test fun autoCapitalization_ignoredOnChineseSurfaces() {
        show(KeyboardView.Surface.HANT)
        inst.runOnMainSync {
            kb.updateAutoCapitalization("")
            assertNull("中文鍵盤沒有大小寫", key("Q"))
        }
    }

    // ── 4. 鍵盤上左右滑切換版面 ──

    @Test fun horizontalSwipe_switchesSurface() {
        show(KeyboardView.Surface.EN)
        inst.runOnMainSync {
            val q = keyOrFail("Q")
            // 先打一下，滑開時不能留下誤打的字
            tap(q)
            rec.events.clear()
            send(q, MotionEvent.ACTION_MOVE, q.width / 2f - 400f, q.height / 2f)   // 往左滑
            assertEquals("往左滑 → 下一個版面", listOf(KeyboardView.Surface.HANT), rec.surfaces)
            assertTrue("滑開的按鍵要收回：${rec.events}", rec.events.contains("undoInsert:Q"))
        }
    }

    @Test fun verticalOrShortMove_doesNotSwitchSurface() {
        show(KeyboardView.Surface.EN)
        inst.runOnMainSync {
            val q = keyOrFail("Q")
            send(q, MotionEvent.ACTION_DOWN, q.width / 2f, q.height / 2f)
            send(q, MotionEvent.ACTION_MOVE, q.width / 2f - 30f, q.height / 2f + 400f)  // 位移不夠
            send(q, MotionEvent.ACTION_UP, q.width / 2f - 30f, q.height / 2f + 400f)
            assertTrue("小幅移動不能切換版面：${rec.surfaces}", rec.surfaces.isEmpty())
        }
    }

    // ── 5. 注音版面比拼音／英文高 ──

    @Test fun zhuyinSurface_isTallerThanEnglish() {
        show(KeyboardView.Surface.EN)
        var enTotal = 0
        inst.runOnMainSync { enTotal = kb.typingRowHeights().sum() }
        show(KeyboardView.Surface.HANT)                 // 注音
        var zhuyinTotal = 0
        inst.runOnMainSync { zhuyinTotal = kb.typingRowHeights().sum() }
        assertTrue("注音（$zhuyinTotal）要比英文（$enTotal）高", zhuyinTotal > enTotal)
        // 同 iOS 的比例：注音 296pt / 英文 262pt ＝ 1.13
        val ratio = zhuyinTotal.toFloat() / enTotal.toFloat()
        assertTrue("注音/英文高度比 $ratio 應該接近 iOS 的 1.13", ratio in 1.05f..1.25f)
        show(KeyboardView.Surface.HANS)                 // 拼音
        var pinyinTotal = 0
        inst.runOnMainSync { pinyinTotal = kb.typingRowHeights().sum() }
        assertEquals("拼音跟英文一樣高", enTotal, pinyinTotal)
    }

    // ── 6. 空白鍵標籤 ──

    @Test fun spaceKeyLabels_matchEachSurface() {
        show(KeyboardView.Surface.EN)
        assertNotNull("英文空白鍵是 space", key("space"))
        show(KeyboardView.Surface.HANT)                 // 注音
        assertNotNull("注音空白鍵是「空白」", key(app.getString(R.string.key_space)))
        show(KeyboardView.Surface.HANT, pinyin = true) // 繁體拼音
        assertNotNull("拼音空白鍵是「空格」", key(app.getString(R.string.key_space_pinyin)))
        show(KeyboardView.Surface.HANS)
        assertNotNull("简體拼音空白鍵也是「空格」", key(app.getString(R.string.key_space_pinyin)))
    }

    // ── 觸控送出 ──

    private fun send(v: View, action: Int, x: Float, y: Float) {
        val t = SystemClock.uptimeMillis()
        v.dispatchTouchEvent(MotionEvent.obtain(t, t, action, x, y, 0))
    }

    private fun tap(v: View) {
        val cx = v.width / 2f
        val cy = v.height / 2f
        send(v, MotionEvent.ACTION_DOWN, cx, cy)
        send(v, MotionEvent.ACTION_UP, cx, cy)
    }

    private fun findByText(root: View, text: String): TextView? {
        if (root.visibility != View.VISIBLE) return null      // 別找到別的版面上藏起來的鍵
        if (root is ViewGroup) for (i in 0 until root.childCount) findByText(root.getChildAt(i), text)?.let { return it }
        if (root is TextView && root.text?.toString() == text) return root
        return null
    }

    private fun findByDesc(root: View, desc: String): View? {
        if (root.visibility != View.VISIBLE) return null
        if (root is ViewGroup) for (i in 0 until root.childCount) findByDesc(root.getChildAt(i), desc)?.let { return it }
        if (root.contentDescription?.toString() == desc) return root
        return null
    }
}

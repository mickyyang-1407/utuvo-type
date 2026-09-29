package com.utuvo.type

import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.TextView
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/** 手感：按下去（ACTION_DOWN）就回饋，而且點擊行為不能被吃掉。 */
@RunWith(AndroidJUnit4::class)
class KeyFeedbackTest {
    private val app = InstrumentationRegistry.getInstrumentation().targetContext
    private lateinit var snapshot: PrefsSnapshot

    @Before fun save() { snapshot = PrefsSnapshot(app, "keyboard") }
    @After fun restore() = snapshot.restore()

    @Test fun defaultsOnAndTogglePersists() {
        app.getSharedPreferences("keyboard", 0).edit().clear().commit()
        assertTrue(KeyFeedback.hapticEnabled(app))
        assertTrue(KeyFeedback.soundEnabled(app))
        KeyFeedback.setHapticEnabled(app, false)
        assertFalse(KeyFeedback.hapticEnabled(app))
    }

    @Test fun feedbackFiresOnDownAndClickStillWorks() {
        val fired = ArrayList<Int>()
        val clicks = ArrayList<Int>()
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            val key = object : TextView(app) {
                override fun performHapticFeedback(feedbackConstant: Int, flags: Int): Boolean {
                    fired += feedbackConstant
                    return true
                }
            }
            KeyFeedback.attach(key)
            key.setOnClickListener { clicks += 1 }
            fun send(action: Int) {
                val t = android.os.SystemClock.uptimeMillis()
                key.dispatchTouchEvent(MotionEvent.obtain(t, t, action, 1f, 1f, 0))
            }
            send(MotionEvent.ACTION_DOWN)
            assertEquals("按下去的當下就要回饋", 1, fired.size)
            send(MotionEvent.ACTION_UP)
            key.performClick()
            assertEquals("OnTouchListener 不能吃掉點擊", 1, clicks.size)
            assertEquals("放開不再重複震一次", 1, fired.size)
        }
    }

    /** 打字鍵：按下就做事，而且同一次按壓不會做兩次（OnClickListener 是給 TalkBack 用的）。 */
    @Test fun bindKeyActsOnDownExactlyOnce() {
        var actions = 0
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            val key = TextView(app)
            KeyFeedback.bindKey(key) { actions += 1 }
            fun send(action: Int) {
                val t = android.os.SystemClock.uptimeMillis()
                key.dispatchTouchEvent(MotionEvent.obtain(t, t, action, 1f, 1f, 0))
            }
            send(MotionEvent.ACTION_DOWN)
            assertEquals("按下就要出字", 1, actions)
            send(MotionEvent.ACTION_UP)
            key.performClick()
            assertEquals("同一次按壓不能出兩個字", 1, actions)
            key.performClick()   // TalkBack：沒有觸控事件的點擊照樣要動作
            assertEquals(2, actions)
        }
    }

    @Test fun offMeansSilent() {
        KeyFeedback.setHapticEnabled(app, false)
        KeyFeedback.setSoundEnabled(app, false)
        val fired = ArrayList<Int>()
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            val key = object : View(app) {
                override fun performHapticFeedback(feedbackConstant: Int, flags: Int): Boolean { fired += feedbackConstant; return true }
            }
            KeyFeedback.onDown(key)
        }
        assertTrue("關掉就不該震：$fired", fired.isEmpty())
    }

    /**
     * Return／Send／Search 等「放開才做事」的鍵（helper 等級）：
     *  - DOWN 只回饋、不做事
     *  - UP 還在按鍵範圍內 → 做事
     *  - UP 在範圍外（沒有前導 MOVE） → 不做事
     *  - ACTION_CANCEL → 不做事
     *  - 滑出後 UP → 不做事
     *  - 正常重按：每次 UP 各做事一次
     *  - performClick 獨立呼叫照樣做事（TalkBack 入口）
     *  - CANCEL 之後立刻 performClick 也要做事（CANCEL 不能污染後續 a11y click）
     */
    @Test fun bindReleaseKeyFiresOnlyOnUpAndSkipsCancel() {
        var actions = 0
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            val key = TextView(app).apply {
                measure(
                    View.MeasureSpec.makeMeasureSpec(100, View.MeasureSpec.EXACTLY),
                    View.MeasureSpec.makeMeasureSpec(100, View.MeasureSpec.EXACTLY)
                )
                layout(0, 0, 100, 100)
            }
            KeyFeedback.bindReleaseKey(key) { actions += 1 }
            val cx = key.width / 2f
            val cy = key.height / 2f
            fun send(action: Int, x: Float = cx, y: Float = cy) {
                val t = android.os.SystemClock.uptimeMillis()
                key.dispatchTouchEvent(MotionEvent.obtain(t, t, action, x, y, 0))
            }
            // 1) DOWN → 0 次
            send(MotionEvent.ACTION_DOWN)
            assertEquals("按下不能做事", 0, actions)
            // 2) UP 還在範圍內 → 1 次
            send(MotionEvent.ACTION_UP)
            assertEquals("放開才能做事", 1, actions)
            // 3) DOWN → CANCEL → 仍 1 次
            send(MotionEvent.ACTION_DOWN)
            send(MotionEvent.ACTION_CANCEL)
            assertEquals("cancel 不能做事", 1, actions)
            // 4) DOWN → 滑出 → UP 不能送出
            send(MotionEvent.ACTION_DOWN)
            send(MotionEvent.ACTION_MOVE, x = -1000f, y = -1000f)
            send(MotionEvent.ACTION_UP, x = -1000f, y = -1000f)
            assertEquals("滑出去不能做事", 1, actions)
            // 5) 沒 MOVE 直接 UP 在範圍外 → 不能做事
            send(MotionEvent.ACTION_DOWN)
            send(MotionEvent.ACTION_UP, x = 9999f, y = 9999f)
            assertEquals("UP 在範圍外不能做事", 1, actions)
            // 6) 正常重按 → 每次 UP 各一次
            send(MotionEvent.ACTION_DOWN)
            send(MotionEvent.ACTION_UP)
            assertEquals("正常按一下", 2, actions)
            send(MotionEvent.ACTION_DOWN)
            send(MotionEvent.ACTION_UP)
            assertEquals("連按兩下", 3, actions)
            // 7) performClick 照做（TalkBack）
            key.performClick()
            assertEquals("TalkBack performClick 也要做事", 4, actions)
            // 8) CANCEL 後立即 performClick 也要做事（CANCEL 不能污染 a11y click）
            send(MotionEvent.ACTION_DOWN)
            send(MotionEvent.ACTION_CANCEL)
            assertEquals("CANCEL 後還沒做事", 4, actions)
            key.performClick()
            assertEquals("CANCEL 後 performClick 也要做事", 5, actions)
        }
    }

    /**
     * 觸覺只震一次：DOWN 震一次，UP 雖然走 performClick 但不能再震；
     * 獨立 performClick（TalkBack）才會再震一次並做事。確保旗標只活在同步
     * performClick 呼叫裡，不會殘留污染取消後操作。
     */
    @Test fun bindReleaseKeyHapticOnlyOnDown_touchAndAccessibility() {
        val fired = ArrayList<Int>()
        var actions = 0
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            val key = object : TextView(app) {
                override fun performHapticFeedback(feedbackConstant: Int, flags: Int): Boolean {
                    fired += feedbackConstant
                    return true
                }
                override fun playSoundEffect(soundConstant: Int) {
                    // 關掉系統音效避免噪音；只看 haptic 計數
                }
            }.apply {
                measure(
                    View.MeasureSpec.makeMeasureSpec(100, View.MeasureSpec.EXACTLY),
                    View.MeasureSpec.makeMeasureSpec(100, View.MeasureSpec.EXACTLY)
                )
                layout(0, 0, 100, 100)
            }
            KeyFeedback.bindReleaseKey(key) { actions += 1 }
            val cx = key.width / 2f
            val cy = key.height / 2f
            fun send(action: Int, x: Float = cx, y: Float = cy) {
                val t = android.os.SystemClock.uptimeMillis()
                key.dispatchTouchEvent(MotionEvent.obtain(t, t, action, x, y, 0))
            }

            // DOWN → 震一次、不做事
            send(MotionEvent.ACTION_DOWN)
            assertEquals("DOWN 應該只震一次", 1, fired.size)
            assertEquals("DOWN 不該做事", 0, actions)

            // UP 在範圍內 → 不再震（UP 觸發的 performClick 應抑制 haptic），做事 1 次
            send(MotionEvent.ACTION_UP)
            assertEquals("UP 不能再震", 1, fired.size)
            assertEquals("UP 應該做事", 1, actions)

            // CANCEL → 不震、不做事
            send(MotionEvent.ACTION_DOWN)
            assertEquals("第二次 DOWN 震第二次", 2, fired.size)
            send(MotionEvent.ACTION_CANCEL)
            assertEquals("CANCEL 不該再震", 2, fired.size)

            // 獨立 performClick（TalkBack）→ 震、做事；haptic 旗標不殘留
            key.performClick()
            assertEquals("獨立 performClick 應該震", 3, fired.size)
            assertEquals("獨立 performClick 應該做事", 2, actions)

            // 再來一輪觸控 DOWN→UP，確認 CANCEL 沒污染後續
            send(MotionEvent.ACTION_DOWN)
            assertEquals("CANCEL 後再 DOWN 還是要震", 4, fired.size)
            send(MotionEvent.ACTION_UP)
            assertEquals("CANCEL 後 UP 不該再震", 4, fired.size)
            assertEquals("CANCEL 後 UP 應該做事", 3, actions)
        }
    }

    /**
     * 走實際 KeyboardView：找出 Return，模擬完整觸控序列，
     * 確認 listener.onEnter 在 DOWN 不被呼叫、UP 才被呼叫。
     * 這條 path 才覆蓋 KeyboardView 的實際接線（不是只測 helper）。
     * 座標全部用 view 本地座標（width/2、height/2）直接 dispatchTouchEvent。
     */
    @Test fun keyboardViewReturnKey_firesOnUp_realKeyboardViewPath() {
        val enters = ArrayList<Int>()
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            val kb = KeyboardView(app, object : KeyboardView.Listener {
                override fun onOrbTap() {}
                override fun onTranslatePick(target: Translation.Target) {}
                override fun onTranslateArm() {}
                override fun onTranslateCancel() {}
                override fun onSurfaceChanged(surface: KeyboardView.Surface) {}
                override fun onCompose(key: Char) {}
                override fun onInsert(text: String) {}
                override fun onDelete() {}
                override fun onSpace() {}
                override fun onEnter() { enters += enters.size + 1 }
                override fun onPickCandidate(index: Int) {}
                override fun onDictationLanguage(language: DictationLanguage) {}
                override fun onToggleCandidatePanel() {}
                override fun onToggleHantInput() {}
                override fun onSwitchKeyboard() {}
                override fun onUndoInsert(text: String) {}
                override fun onUndoCompose() {}
                override fun onUndoDelete() {}
                override fun onUndoSpace() {}
            })
            kb.setEnterLabel("return")
            kb.show(KeyboardView.Surface.EN, hantUsesPinyin = false)

            val parent = FrameLayout(app)
            parent.addView(kb, FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
            ))
            parent.measure(
                View.MeasureSpec.makeMeasureSpec(800, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(600, View.MeasureSpec.EXACTLY)
            )
            parent.layout(0, 0, 800, 600)

            val ret = findByContentDesc(kb, "return")
            assertNotNull("找不到 Return 鍵", ret)
            ret!!
            assertTrue("Return 鍵要有大小才能測 bounds", ret.width > 0 && ret.height > 0)

            val cx = ret.width / 2f
            val cy = ret.height / 2f
            fun send(action: Int, x: Float = cx, y: Float = cy) {
                val t = android.os.SystemClock.uptimeMillis()
                ret.dispatchTouchEvent(MotionEvent.obtain(t, t, action, x, y, 0))
            }

            // DOWN 不送出
            send(MotionEvent.ACTION_DOWN)
            assertEquals("Return DOWN 不該送出 enter", 0, enters.size)
            // UP 送出
            send(MotionEvent.ACTION_UP)
            assertEquals("Return UP 才送出 enter", 1, enters.size)
            // DOWN→CANCEL 不送出
            send(MotionEvent.ACTION_DOWN)
            send(MotionEvent.ACTION_CANCEL)
            assertEquals("Return CANCEL 不該送出", 1, enters.size)
            // DOWN→滑出→UP 不送出
            send(MotionEvent.ACTION_DOWN)
            send(MotionEvent.ACTION_MOVE, x = -1000f, y = -1000f)
            send(MotionEvent.ACTION_UP, x = -1000f, y = -1000f)
            assertEquals("Return 滑出去不該送出", 1, enters.size)
            // DOWN→UP 在範圍外 不送出
            send(MotionEvent.ACTION_DOWN)
            send(MotionEvent.ACTION_UP, x = 9999f, y = 9999f)
            assertEquals("Return UP 在範圍外不該送出", 1, enters.size)
            // 正常再按一次
            send(MotionEvent.ACTION_DOWN)
            send(MotionEvent.ACTION_UP)
            assertEquals("Return 正常重按一次", 2, enters.size)
            // performClick 也要送出
            ret.performClick()
            assertEquals("Return performClick 也要送出", 3, enters.size)
            // CANCEL 之後 performClick 也要送出
            send(MotionEvent.ACTION_DOWN)
            send(MotionEvent.ACTION_CANCEL)
            assertEquals("Return CANCEL 後還沒送出", 3, enters.size)
            ret.performClick()
            assertEquals("Return CANCEL 後 performClick 也要送出", 4, enters.size)
        }
    }

    private fun findByContentDesc(root: View, desc: String): View? {
        if (root is ViewGroup) for (i in 0 until root.childCount) {
            findByContentDesc(root.getChildAt(i), desc)?.let { return it }
        }
        if (root is TextView && root.contentDescription?.toString() == desc) return root
        return null
    }
}

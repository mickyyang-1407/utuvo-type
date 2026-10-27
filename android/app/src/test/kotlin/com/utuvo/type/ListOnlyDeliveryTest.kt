package com.utuvo.type

import org.junit.Test
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue

class ListOnlyDeliveryTest {
    @Test fun layoutHonorsCleanupAndListOptOuts() {
        val source = "明天要錄音第一個我們要帶耳機，二、普價、三、總普、四、節拍器、五、還有踏板"
        val expected = "明天要錄音：\n1. 我們要帶耳機\n2. 普價\n3. 總普\n4. 節拍器\n5. 還有踏板"
        assertEquals(expected, SmartCleanup.listForDelivery(source, true, true))
        assertEquals(source, SmartCleanup.listForDelivery(source, false, true))
        assertEquals(source, SmartCleanup.listForDelivery(source, true, false))
        assertEquals("一般句子。", SmartCleanup.listForDelivery("一般句子。", true, true))
    }
    @Test fun searchFieldsKeepTheirExistingSingleLineRule() {
        val list = SmartCleanup.listForDelivery("帶 1.耳機 2.腳架", true, true)
        assertTrue(list.contains('\n'))
        assertEquals("帶：1. 耳機 2. 腳架", com.utuvo.type.core.OutputShape.singleLine(list))
    }
}

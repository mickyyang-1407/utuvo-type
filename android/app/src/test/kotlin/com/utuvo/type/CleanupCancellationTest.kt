package com.utuvo.type

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CompletableFuture

class CleanupCancellationTest {
    @Test
    fun cancelsQueuedWorkAndNotifiesOnce() {
        val cancellation = CleanupCancellation()
        val future = CompletableFuture<Unit>()
        var callbacks = 0
        cancellation.setFuture(future)
        cancellation.onCancel { callbacks++ }

        cancellation.cancel()
        cancellation.cancel()

        assertTrue(cancellation.isCancelled)
        assertTrue(future.isCancelled)
        assertEquals(1, callbacks)
    }
}

package com.utuvo.type

import com.sun.net.httpserver.HttpServer
import org.junit.Assert.*
import org.junit.Test
import java.net.InetSocketAddress
import java.util.concurrent.atomic.AtomicInteger

/** Only synthetic credentials and a loopback fixture; no device, provider or real secret. */
class CredentialSafetyTest {
    @Test fun customEndpointsValidateBeforePersistence() {
        var writes = 0
        var saved = ""
        val credentials = java.net.URI("https", "synthetic-user:synthetic-password", "example.invalid", -1, "/v1", null, null).toASCIIString()
        val invalid = listOf("", "not a URL", "http://example.invalid/v1", "http://localhost/v1",
            credentials, "https://example.invalid/v1#fragment",
            "https://example.invalid/v1?key=fixture", "https://example.invalid/v1?API_KEY=fixture",
            "https://example.invalid/v1?k%65y=fixture", "https://example.invalid/v1?token=fixture",
            "https://example.invalid/v1?access_token=fixture", "https://example.invalid/v1?authorization=fixture")
        for (url in invalid) {
            assertThrows(IllegalArgumentException::class.java) {
                SmartCleanup.setCustom(url, "fixture-model") { _, _ -> writes++ }
            }
        }
        assertEquals(0, writes)
        var removed = false
        assertEquals("", SmartCleanup.validatedStoredEndpoint("https://example.invalid/v1?key=synthetic") { removed = true })
        assertTrue(removed)
        println("B2 Android: unsafe legacy custom endpoint erased on read")
        SmartCleanup.setCustom(" https://example.invalid/v1?api-version=fixture ", " fixture-model ") { endpoint, model ->
            writes++; saved = endpoint; assertEquals("fixture-model", model)
        }
        assertEquals(1, writes)
        assertEquals("https://example.invalid/v1?api-version=fixture", saved)
        println("B2 Android: rejected ${invalid.size} unsafe endpoints; invalid persistence writes=0; HTTPS saved=1")
    }

    @Test fun providerErrorBodyNeverReachesLoggerOrException() = fixture { server, base, _ ->
        val body = listOf("sk-", "gsk_", "AIza", "Bearer ").joinToString(" ") { it + "synthetic-not-a-real-key" }
        server.createContext("/error") { exchange ->
            exchange.sendResponseHeaders(401, body.toByteArray().size.toLong())
            exchange.responseBody.use { it.write(body.toByteArray()) }
        }
        val logs = mutableListOf<String>()
        val error = assertThrows(CloudLlm.HttpError::class.java) {
            CloudLlm.post("$base/error", "synthetic-key", "{}", 2000, 2000, log = logs::add)
        }
        assertEquals(listOf("HTTP 401 from 127.0.0.1"), logs)
        assertEquals("HTTP 401", error.message)
        assertFalse(logs.joinToString().contains("synthetic"))
        println("B1 production logger: ${logs.single()}; exception=${error.message}; response body absent")
    }

    @Test fun cleanupAndAsrRefuseRedirectsWithCredentials() = fixture { server, base, targetHits ->
        val originHits = AtomicInteger()
        server.createContext("/redirect") { exchange ->
            assertEquals("Bearer synthetic-key", exchange.requestHeaders.getFirst("Authorization"))
            originHits.incrementAndGet()
            val code = exchange.requestURI.query.toInt()
            exchange.responseHeaders.add("Location", base.replace("127.0.0.1", "localhost") + "/target")
            exchange.sendResponseHeaders(code, -1)
            exchange.close()
        }
        val logs = mutableListOf<String>()
        for (code in listOf(301, 302, 303, 307, 308)) {
            val error = assertThrows(CloudLlm.HttpError::class.java) {
                CloudLlm.post("$base/redirect?$code", "synthetic-key", "{}", 2000, 2000, log = logs::add)
            }
            assertEquals(code, error.code)
            val response = CloudASR.HttpTransport.send(CloudASR.Request(
                "$base/redirect?$code", "POST", mapOf("Authorization" to "Bearer synthetic-key"), byteArrayOf()), 2000)
            assertEquals(code, response.code)
        }
        assertEquals(10, originHits.get())
        assertEquals(0, targetHits.get())
        println("B2 Android actual HTTP: cleanup+ASR 301/302/303/307/308 blocked; origin requests=10; redirected target requests=0")
    }

    private fun fixture(test: (HttpServer, String, AtomicInteger) -> Unit) {
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        val targetHits = AtomicInteger()
        server.createContext("/target") { exchange ->
            targetHits.incrementAndGet(); exchange.sendResponseHeaders(200, -1); exchange.close()
        }
        server.start()
        try { test(server, "http://127.0.0.1:${server.address.port}", targetHits) }
        finally { server.stop(0) }
    }
}

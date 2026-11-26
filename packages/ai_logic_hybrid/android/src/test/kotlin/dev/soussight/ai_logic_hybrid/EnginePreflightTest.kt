package dev.soussight.ai_logic_hybrid

import android.graphics.Bitmap
import com.google.firebase.ai.FirebaseAI
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlinx.coroutines.runBlocking

/**
 * FirebaseHybridEngine checks every input before its first SDK call: rules, schema, image size
 * and a full decode. The SDK entry point here throws, so reaching it means validation passed.
 */
internal class EnginePreflightTest {
    private class SdkReached : RuntimeException("SDK reached")

    private val sdkCalls = AtomicInteger()
    private val sdk: () -> FirebaseAI = {
        sdkCalls.incrementAndGet()
        throw SdkReached()
    }

    /** A Bitmap without Android: the codec only hands it to the prompt builder. */
    private val bitmap: Bitmap = run {
        val unsafe = Class.forName("sun.misc.Unsafe").getDeclaredField("theUnsafe")
            .apply { isAccessible = true }.get(null)
        unsafe.javaClass.getMethod("allocateInstance", Class::class.java).invoke(unsafe, Bitmap::class.java) as Bitmap
    }

    private val decodes = AtomicInteger()

    /** First byte picks the image: 1 = 769x1, 2 = header unreadable, 3 = pixels do not decode, else ok. */
    private val codec = object : ImageCodec {
        override fun bounds(bytes: ByteArray) = when (bytes[0]) {
            1.toByte() -> 769 to 1
            2.toByte() -> null
            else -> 1 to 1
        }

        override fun decode(bytes: ByteArray): Bitmap? {
            decodes.incrementAndGet()
            return if (bytes[0] == 3.toByte()) null else bitmap
        }
    }

    private val config = HybridConfig("m", AndroidModelOption.STABLE, listOf("en"))

    private fun request(
        mode: HybridMode,
        image: Byte? = null,
        schema: Map<String, Any?>? = null,
    ) = GenerateRequest(
        requestId = "r1",
        mode = mode,
        feature = "f",
        systemInstruction = null,
        parts = listOfNotNull(
            HybridPart.Text("what is this?"),
            image?.let { HybridPart.InlineData(byteArrayOf(it), "image/jpeg") },
        ),
        jsonSchema = schema,
        maxOutputTokens = 16,
        timeoutMs = 1_000,
    )

    private fun generate(r: GenerateRequest) = runBlocking { FirebaseHybridEngine(codec, sdk).generate(config, r) }

    @Test
    fun badImagesFailBeforeTheSdk() {
        for (mode in HybridMode.entries) {
            for (tag in listOf<Byte>(1, 2)) {
                val e = assertFailsWith<HybridError> { generate(request(mode, image = tag)) }
                assertEquals(HybridErrorCode.UNSUPPORTED_INPUT, e.code, "$mode image $tag")
            }
        }
        // Readable header, undecodable pixels: rejected wherever the image may be decoded locally.
        for (mode in HybridMode.entries - HybridMode.ONLY_IN_CLOUD) {
            val e = assertFailsWith<HybridError> { generate(request(mode, image = 3)) }
            assertEquals(HybridErrorCode.UNSUPPORTED_INPUT, e.code, "$mode")
        }
        assertEquals(0, sdkCalls.get())
    }

    @Test
    fun anUnsupportedSchemaFailsBeforeTheSdk() {
        val e = assertFailsWith<HybridError> {
            generate(request(HybridMode.PREFER_ON_DEVICE, schema = mapOf("type" to "bogus")))
        }
        assertEquals(HybridErrorCode.UNSUPPORTED_INPUT, e.code)
        assertEquals(0, sdkCalls.get())
    }

    @Test
    fun aValidImageIsDecodedOnceThenTheSdkIsCalled() {
        assertFailsWith<SdkReached> { generate(request(HybridMode.ONLY_ON_DEVICE, image = 9)) }
        assertEquals(1, decodes.get(), "decoded once and reused")
        // Cloud-only sends the original bytes: no decode needed.
        assertFailsWith<SdkReached> { generate(request(HybridMode.ONLY_IN_CLOUD, image = 3)) }
        assertEquals(1, decodes.get())
        assertEquals(2, sdkCalls.get())
    }

    @Test
    fun aStalledModelBuildDoesNotBlockAnotherLookup() {
        // The first build stalls (as a slow SDK factory might); later builds fail fast because
        // there is no FirebaseApp. The second lookup must not wait for the first one's lock.
        val first = java.util.concurrent.CountDownLatch(1)
        val entered = java.util.concurrent.CountDownLatch(1)
        val builds = AtomicInteger()
        val engine = FirebaseHybridEngine(codec) {
            if (builds.getAndIncrement() == 0) {
                entered.countDown()
                first.await()
            }
            throw IllegalStateException("no FirebaseApp")
        }
        val stalled = Thread { runCatching { runBlocking { engine.availability(config, false) } } }.apply { start() }
        try {
            assertEquals(true, entered.await(5, java.util.concurrent.TimeUnit.SECONDS))
            val other = config.copy(androidModel = AndroidModelOption.PREVIEW)
            val start = System.nanoTime()
            val e = assertFailsWith<HybridError> { runBlocking { engine.availability(other, false) } }
            assertEquals(HybridErrorCode.UNAVAILABLE, e.code)
            assertEquals(true, (System.nanoTime() - start) / 1_000_000 < 1_000, "not blocked by the stalled build")
        } finally {
            first.countDown()
            stalled.join(5_000)
        }
    }
}

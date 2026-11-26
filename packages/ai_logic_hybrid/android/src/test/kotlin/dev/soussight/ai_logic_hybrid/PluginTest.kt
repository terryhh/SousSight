package dev.soussight.ai_logic_hybrid

import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.util.concurrent.ConcurrentHashMap
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout

/** The plugin boundary on the JVM: channels on a fake messenger, no Flutter engine, no SDK. */
internal class PluginTest {
    private class FakeMessenger : BinaryMessenger {
        val handlers = ConcurrentHashMap<String, Any>()

        override fun send(channel: String, message: ByteBuffer?) = Unit
        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) = Unit
        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {
            if (handler == null) handlers.remove(channel) else handlers[channel] = handler
        }
    }

    private class FakeResult : MethodChannel.Result {
        val answer = CompletableDeferred<Pair<String, Any?>>()
        override fun success(result: Any?) { answer.complete("success" to result) }
        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
            answer.complete(errorCode to errorMessage)
        }
        override fun notImplemented() { answer.complete("notImplemented" to null) }
        fun await() = runBlocking { withTimeout(5_000) { answer.await() } }
    }

    /** Reports the observed model name the SDK would. */
    private class StubEngine : HybridEngine {
        override suspend fun availability(config: HybridConfig, withImage: Boolean) =
            AvailabilityResult(OnDeviceStatus.AVAILABLE, modelLabel = "nano-v3")
        override fun prepare(config: HybridConfig, withImage: Boolean): Flow<Double?> = flowOf(1.0)
        override suspend fun generate(config: HybridConfig, request: GenerateRequest): GenerateResult =
            awaitCancellation()
    }

    private fun attached(messenger: FakeMessenger = FakeMessenger()): AiLogicHybridPlugin =
        AiLogicHybridPlugin { StubEngine() }.also { it.attach(messenger, Dispatchers.Default) }

    private fun AiLogicHybridPlugin.call(method: String, args: Any? = null): Pair<String, Any?> {
        val result = FakeResult()
        onMethodCall(MethodCall(method, args), result)
        return result.await()
    }

    private fun local(caps: Any?): Map<*, *> = ((caps as Map<*, *>)["local"] as Map<*, *>)

    private val generateArgs = mapOf(
        "requestId" to "r1", "mode" to "onlyOnDevice", "feature" to "f",
        "parts" to listOf(mapOf("type" to "text", "text" to "hi")),
        "maxOutputTokens" to 8, "timeoutMs" to 1_000,
    )

    @Test
    fun attachRegistersBothChannelsAndDetachRemovesThem() {
        val messenger = FakeMessenger()
        val plugin = attached(messenger)
        assertEquals(setOf(Protocol.METHOD_CHANNEL, Protocol.PREPARE_CHANNEL), messenger.handlers.keys)
        assertNotNull(plugin.currentEngine)
        plugin.detach()
        assertTrue(messenger.handlers.isEmpty())
        assertNull(plugin.currentEngine)
    }

    @Test
    fun capabilitiesAndAvailabilityReportTheConfiguredOption() {
        val plugin = attached()
        assertNull(local(plugin.call("capabilities").second)["modelOption"], "not configured yet")
        assertEquals(
            "success" to mapOf("status" to "unavailable", "reason" to Reasons.NOT_CONFIGURED, "modelLabel" to null, "modelOption" to null),
            plugin.call("availability"),
        )
        plugin.call("configure", mapOf("cloudModel" to "m"))
        assertEquals("stable", local(plugin.call("capabilities").second)["modelOption"], "stable by default")
        assertEquals(
            "success" to mapOf("status" to "available", "reason" to null, "modelLabel" to "nano-v3", "modelOption" to "stable"),
            plugin.call("availability", mapOf("withImage" to true)),
        )
        plugin.call("configure", mapOf("cloudModel" to "m", "androidModel" to "preview"))
        assertEquals("preview", local(plugin.call("capabilities").second)["modelOption"], "explicit opt-in")
        assertEquals("preview", (plugin.call("availability").second as Map<*, *>)["modelOption"])
    }

    @Test
    fun configureErrorsAndUnknownMethods() {
        val plugin = attached()
        assertEquals(HybridErrorCode.FAILED.wire, plugin.call("configure", mapOf("androidModel" to "stable")).first)
        assertEquals("notImplemented", plugin.call("nope").first)
        assertEquals("success" to null, plugin.call("cancel", mapOf("requestId" to "r1")))
    }

    @Test
    fun unattachedGenerateIsUnavailable() {
        val plugin = AiLogicHybridPlugin { StubEngine() }
        val (code, message) = plugin.call("generate", generateArgs)
        assertEquals(HybridErrorCode.UNAVAILABLE.wire, code)
        assertEquals(Reasons.BRIDGE_UNAVAILABLE, message)
    }

    @Test
    fun thePublicConstructorUsesTheFirebaseEngine() {
        val plugin = AiLogicHybridPlugin().also { it.attach(FakeMessenger(), Dispatchers.Default) }
        assertIs<FirebaseHybridEngine>(plugin.currentEngine)
        plugin.detach()
    }

    @Test
    fun detachForgetsTheConfigurationSoAReattachMustConfigureAgain() {
        val plugin = attached()
        plugin.call("configure", mapOf("cloudModel" to "m"))
        plugin.detach()
        plugin.attach(FakeMessenger(), Dispatchers.Default)
        val (code, message) = plugin.call("generate", generateArgs)
        assertEquals(HybridErrorCode.UNAVAILABLE.wire, code)
        assertEquals(Reasons.NOT_CONFIGURED, message)
        assertNull(local(plugin.call("capabilities").second)["modelOption"])
        plugin.detach()
    }
}

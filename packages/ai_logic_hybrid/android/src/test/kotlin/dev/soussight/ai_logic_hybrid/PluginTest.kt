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

    /** Answers availability for whatever option it is asked about; counts preview checks. */
    private class StubEngine(val previewStatus: OnDeviceStatus = OnDeviceStatus.AVAILABLE) : HybridEngine {
        val previewChecks = java.util.concurrent.atomic.AtomicInteger()
        override suspend fun availability(config: HybridConfig, withImage: Boolean): AvailabilityResult {
            if (config.androidModel == AndroidModelOption.PREVIEW) {
                previewChecks.incrementAndGet()
                return AvailabilityResult(previewStatus, modelLabel = "nano-v4-full")
            }
            return AvailabilityResult(OnDeviceStatus.AVAILABLE, modelLabel = "nano-v3")
        }
        override fun prepare(config: HybridConfig, withImage: Boolean): Flow<Double?> = flowOf(1.0)
        override suspend fun generate(config: HybridConfig, request: GenerateRequest): GenerateResult =
            awaitCancellation()
    }

    private fun attached(
        messenger: FakeMessenger = FakeMessenger(),
        engine: StubEngine = StubEngine(),
        device: Pair<String, String> = "Google" to "Pixel 9",
    ): AiLogicHybridPlugin =
        AiLogicHybridPlugin({ engine }, DeviceListChooser(device.first, device.second))
            .also { it.attach(messenger, Dispatchers.Default) }

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
            "success" to mapOf(
                "status" to "unavailable", "reason" to Reasons.NOT_CONFIGURED, "modelLabel" to null,
                "modelOption" to null, "modelChoice" to null,
            ),
            plugin.call("availability"),
        )
        // Default deviceList on a Pixel 9 (off the Nano 4 list): stable, with the reason.
        plugin.call("configure", mapOf("cloudModel" to "m"))
        val offList = "not on the Gemini Nano 4 device list (Google Pixel 9) → stable"
        assertEquals("stable", local(plugin.call("capabilities").second)["modelOption"])
        assertEquals(offList, local(plugin.call("capabilities").second)["modelChoice"])
        assertEquals(
            "success" to mapOf(
                "status" to "available", "reason" to null, "modelLabel" to "nano-v3",
                "modelOption" to "stable", "modelChoice" to offList,
            ),
            plugin.call("availability", mapOf("withImage" to true)),
        )
        // ANDROID_MODEL=preview overrides.
        plugin.call("configure", mapOf("cloudModel" to "m", "androidModel" to "preview"))
        assertEquals("preview", local(plugin.call("capabilities").second)["modelOption"], "explicit opt-in")
        val a = plugin.call("availability").second as Map<*, *>
        assertEquals("preview", a["modelOption"])
        assertEquals("set explicitly → preview", a["modelChoice"])
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
        val plugin = AiLogicHybridPlugin({ StubEngine() }, DeviceListChooser("Google", "Pixel 10"))
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

    @Test
    fun aListedPixelWithPreviewReadyUsesPreviewDecidedOnce() {
        val engine = StubEngine(OnDeviceStatus.AVAILABLE)
        val plugin = attached(engine = engine, device = "Google" to "Pixel 10 Pro")
        plugin.call("configure", mapOf("cloudModel" to "m"))
        assertEquals("preview", local(plugin.call("capabilities").second)["modelOption"])
        assertEquals("device list: Pixel 10 Pro → preview", local(plugin.call("capabilities").second)["modelChoice"])
        assertEquals("nano-v4-full", (plugin.call("availability").second as Map<*, *>)["modelLabel"])
        plugin.call("configure", mapOf("cloudModel" to "m2"))
        // One check at configure and one availability read; the second configure reuses the decision.
        assertEquals(2, engine.previewChecks.get())
    }

    @Test
    fun aListedPixelWithoutPreviewUsesStable() {
        val plugin = attached(engine = StubEngine(OnDeviceStatus.DOWNLOADABLE), device = "Google" to "Pixel 10")
        plugin.call("configure", mapOf("cloudModel" to "m"))
        val caps = local(plugin.call("capabilities").second)
        assertEquals("stable", caps["modelOption"])
        assertEquals("device list: Pixel 10, but preview is downloadable → stable", caps["modelChoice"])
    }

    @Test
    fun stableOverrideSkipsTheDeviceCheck() {
        val engine = StubEngine(OnDeviceStatus.AVAILABLE)
        val plugin = attached(engine = engine, device = "Google" to "Pixel 10")
        plugin.call("configure", mapOf("cloudModel" to "m", "androidModel" to "stable"))
        assertEquals("stable", local(plugin.call("capabilities").second)["modelOption"])
        assertEquals("set explicitly → stable", local(plugin.call("capabilities").second)["modelChoice"])
        assertEquals(0, engine.previewChecks.get())
    }

    @Test
    fun configureBeforeAttachUsesStable() {
        val plugin = AiLogicHybridPlugin({ StubEngine() }, DeviceListChooser("Google", "Pixel 10"))
        assertEquals("success" to null, plugin.call("configure", mapOf("cloudModel" to "m")))
        assertEquals("no bridge → stable", local(plugin.call("capabilities").second)["modelChoice"])
    }

    @Test
    fun aLaterConfigureWinsOverAPendingDecision() {
        val gate = CompletableDeferred<Unit>()
        val slow = object : HybridEngine by StubEngine() {
            override suspend fun availability(config: HybridConfig, withImage: Boolean): AvailabilityResult {
                if (config.androidModel == AndroidModelOption.PREVIEW) gate.await()
                return AvailabilityResult(OnDeviceStatus.AVAILABLE)
            }
        }
        val plugin = AiLogicHybridPlugin({ slow }, DeviceListChooser("Google", "Pixel 10"))
            .also { it.attach(FakeMessenger(), Dispatchers.Default) }
        val first = FakeResult()
        plugin.onMethodCall(MethodCall("configure", mapOf("cloudModel" to "m")), first)
        plugin.call("configure", mapOf("cloudModel" to "m", "androidModel" to "stable"))
        gate.complete(Unit)
        first.await()
        assertEquals("stable", local(plugin.call("capabilities").second)["modelOption"])
        plugin.detach()
    }
}

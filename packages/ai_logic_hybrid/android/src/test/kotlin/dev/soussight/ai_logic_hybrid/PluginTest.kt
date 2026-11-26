package dev.soussight.ai_logic_hybrid

import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.isActive
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout

/** The plugin boundary on the JVM: channels on a fake messenger, no Flutter engine, no SDK. */
internal class PluginTest {
    private val scopes = CopyOnWriteArrayList<CoroutineScope>()

    @AfterTest
    fun tearDown() = scopes.forEach { it.cancel() }

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

    /** Reports a fixed option for auto and records the scope it was given. */
    private class StubEngine(val chosen: AndroidModelOption?) : HybridEngine {
        override suspend fun availability(config: HybridConfig, withImage: Boolean) =
            AvailabilityResult(OnDeviceStatus.AVAILABLE, modelLabel = "nano-v3", modelOption = chosen)
        override fun prepare(config: HybridConfig, withImage: Boolean): Flow<Double?> = flowOf(1.0)
        override suspend fun generate(config: HybridConfig, request: GenerateRequest): GenerateResult =
            awaitCancellation()
        override fun modelOption(config: HybridConfig): AndroidModelOption? =
            if (config.androidModel == AndroidModelOption.AUTO) chosen else config.androidModel
    }

    private fun attached(
        engine: (Boolean, CoroutineScope) -> HybridEngine,
        debuggable: Boolean = false,
        messenger: FakeMessenger = FakeMessenger(),
    ): AiLogicHybridPlugin = AiLogicHybridPlugin { d, scope ->
        scopes += scope
        engine(d, scope)
    }.also { it.attach(messenger, debuggable, Dispatchers.Default) }

    private fun AiLogicHybridPlugin.call(method: String, args: Any? = null): Pair<String, Any?> {
        val result = FakeResult()
        onMethodCall(MethodCall(method, args), result)
        return result.await()
    }

    private fun local(caps: Any?): Map<*, *> = ((caps as Map<*, *>)["local"] as Map<*, *>)

    @Test
    fun attachRegistersBothChannelsAndDetachRemovesThem() {
        val messenger = FakeMessenger()
        val plugin = attached({ _, _ -> StubEngine(null) }, messenger = messenger)
        assertEquals(setOf(Protocol.METHOD_CHANNEL, Protocol.PREPARE_CHANNEL), messenger.handlers.keys)
        assertNotNull(plugin.currentEngine)
        plugin.detach()
        assertTrue(messenger.handlers.isEmpty())
        assertNull(plugin.currentEngine)
    }

    @Test
    fun theEngineGetsTheDebugFlagAndThePluginLifetime() {
        var seen: Pair<Boolean, CoroutineScope>? = null
        val plugin = attached({ d, scope -> seen = d to scope; StubEngine(null) }, debuggable = true)
        val (debuggable, scope) = assertNotNull(seen)
        assertTrue(debuggable)
        assertTrue(scope.isActive)
        plugin.detach()
        assertFalse(scope.isActive, "detach cancels the engine's background work")
    }

    @Test
    fun detachStopsAnAutoCheckInProgress() = runBlocking {
        val lookup = CompletableDeferred<Unit>()
        val generated = CopyOnWriteArrayList<AndroidModelOption>()
        val inner = object : HybridEngine {
            override suspend fun availability(config: HybridConfig, withImage: Boolean): AvailabilityResult {
                lookup.complete(Unit)
                awaitCancellation()
            }
            override fun prepare(config: HybridConfig, withImage: Boolean): Flow<Double?> = flowOf(1.0)
            override suspend fun generate(config: HybridConfig, request: GenerateRequest): GenerateResult {
                generated += config.androidModel
                return GenerateResult("OK", InferenceSourceWire.ON_DEVICE, "x")
            }
        }
        val plugin = attached({ _, scope -> AutoModelEngine(inner, scope) })
        plugin.call("configure", mapOf("cloudModel" to "m"))
        val result = FakeResult()
        plugin.onMethodCall(MethodCall("availability", mapOf("withImage" to false)), result)
        withTimeout(5_000) { lookup.await() }
        plugin.detach()
        kotlinx.coroutines.delay(100)
        assertTrue(generated.isEmpty())
        assertFalse(result.answer.isCompleted, "a detached plugin answers nothing more")
    }

    @Test
    fun capabilitiesReportTheOptionInUse() {
        val plugin = attached({ _, _ -> StubEngine(AndroidModelOption.STABLE) })
        // Not configured yet: no option.
        assertNull(local(plugin.call("capabilities").second)["modelOption"])
        plugin.call("configure", mapOf("cloudModel" to "m"))
        assertEquals("stable", local(plugin.call("capabilities").second)["modelOption"])
        plugin.call("configure", mapOf("cloudModel" to "m", "androidModel" to "preview"))
        assertEquals("preview", local(plugin.call("capabilities").second)["modelOption"])
    }

    @Test
    fun capabilitiesBeforeAutoHasChosenSayNothing() {
        val plugin = attached({ _, _ -> StubEngine(null) })
        plugin.call("configure", mapOf("cloudModel" to "m"))
        assertNull(local(plugin.call("capabilities").second)["modelOption"])
        assertNull(local(AiLogicHybridPlugin.capabilities(null, null))["modelOption"])
    }

    @Test
    fun availabilityCarriesTheChosenOption() {
        val plugin = attached({ _, _ -> StubEngine(AndroidModelOption.STABLE) })
        assertEquals(
            "success" to mapOf("status" to "unavailable", "reason" to Reasons.NOT_CONFIGURED, "modelLabel" to null, "modelOption" to null),
            plugin.call("availability"),
        )
        plugin.call("configure", mapOf("cloudModel" to "m"))
        assertEquals(
            "success" to mapOf("status" to "available", "reason" to null, "modelLabel" to "nano-v3", "modelOption" to "stable"),
            plugin.call("availability", mapOf("withImage" to true)),
        )
    }

    @Test
    fun configureErrorsAndUnknownMethods() {
        val plugin = attached({ _, _ -> StubEngine(null) })
        assertEquals(HybridErrorCode.FAILED.wire, plugin.call("configure", mapOf("androidModel" to "auto")).first)
        assertEquals("notImplemented", plugin.call("nope").first)
        assertEquals("success" to null, plugin.call("cancel", mapOf("requestId" to "r1")))
    }

    @Test
    fun unattachedGenerateIsUnavailable() {
        val plugin = AiLogicHybridPlugin { _, _ -> StubEngine(null) }
        val (code, message) = plugin.call("generate", mapOf("requestId" to "r1"))
        assertEquals(HybridErrorCode.UNAVAILABLE.wire, code)
        assertEquals(Reasons.BRIDGE_UNAVAILABLE, message)
    }

    @Test
    fun theDefaultEngineIsAutoOverFirebaseWithDebugVerification() {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default).also { scopes += it }
        val debug = AiLogicHybridPlugin.defaultEngine(true, scope, log = {})
        assertIs<AutoModelEngine>(debug)
        assertTrue(debug.verifyChoice)
        val release = assertIs<AutoModelEngine>(AiLogicHybridPlugin.defaultEngine(false, scope, log = {}))
        assertFalse(release.verifyChoice)
        // The public constructor wires the same factory.
        val plugin = AiLogicHybridPlugin().also { it.attach(FakeMessenger(), false, Dispatchers.Default) }
        assertIs<AutoModelEngine>(plugin.currentEngine)
        plugin.detach()
        assertSame(null, plugin.currentEngine)
    }

    @Test
    fun anEngineWithoutAutoReportsOnlyConcreteOptions() {
        val plain = object : HybridEngine {
            override suspend fun availability(config: HybridConfig, withImage: Boolean) =
                AvailabilityResult(OnDeviceStatus.UNAVAILABLE)
            override fun prepare(config: HybridConfig, withImage: Boolean): Flow<Double?> = flowOf(1.0)
            override suspend fun generate(config: HybridConfig, request: GenerateRequest): GenerateResult =
                awaitCancellation()
        }
        val config = HybridConfig("m", AndroidModelOption.AUTO, listOf("en"))
        assertNull(plain.modelOption(config), "auto is never reported as a model")
        assertEquals(AndroidModelOption.PREVIEW_FAST, plain.modelOption(config.copy(androidModel = AndroidModelOption.PREVIEW_FAST)))
        // The default validation is the decode-free input rules.
        fun req(vararg parts: HybridPart) = GenerateRequest("r", HybridMode.ONLY_ON_DEVICE, "f", null, parts.toList(), null, 8, 1_000)
        plain.validate(req(HybridPart.Text("hi")))
        val audio = kotlin.test.assertFailsWith<HybridError> { plain.validate(req(HybridPart.InlineData(ByteArray(1), "audio/wav"))) }
        assertEquals(HybridErrorCode.UNSUPPORTED_INPUT, audio.code)
    }
}

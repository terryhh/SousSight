package dev.soussight.ai_logic_hybrid

import com.google.firebase.ai.type.FirebaseAIOnDeviceNotAvailableException
import com.google.firebase.ai.type.PublicPreviewAPI
import com.google.mlkit.genai.common.GenAiException
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import com.google.firebase.ai.ondevice.interop.FirebaseAIOnDeviceNotAvailableException as InteropNotAvailable

@OptIn(PublicPreviewAPI::class)
internal class AutoModelEngineTest {
    private val auto = HybridConfig("cloud-model", AndroidModelOption.AUTO, listOf("en"))

    /** Stands in for the plugin's scope: the engine's lifetime. */
    private val lifetime = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    @AfterTest
    fun tearDown() = lifetime.cancel()

    /** What firebase-ai 18.2.0 throws when ML Kit reports NOT_AVAILABLE (8). */
    private fun code8(): Throwable = FirebaseAIOnDeviceNotAvailableException(
        InteropNotAvailable(
            "AICore failed: 606-FEATURE_NOT_FOUND",
            GenAiException("not available", null, GenAiException.ErrorCode.NOT_AVAILABLE),
        ),
    )

    private data class Call(val option: AndroidModelOption, val request: GenerateRequest)

    /** Per-option behaviour; records every call. No SDK, no network. */
    private class FakeEngine(
        val status: (AndroidModelOption) -> AvailabilityResult = {
            AvailabilityResult(OnDeviceStatus.AVAILABLE, modelLabel = label(it))
        },
        val onGenerate: suspend (AndroidModelOption, GenerateRequest) -> GenerateResult = { option, _ ->
            GenerateResult("OK", InferenceSourceWire.ON_DEVICE, label(option))
        },
        /** Runs when a download starts; tests use it to finish the "download". */
        val onPrepare: (AndroidModelOption) -> Unit = {},
    ) : HybridEngine {
        val availabilityCalls = CopyOnWriteArrayList<AndroidModelOption>()
        val generateCalls = CopyOnWriteArrayList<Call>()
        val prepareCalls = CopyOnWriteArrayList<AndroidModelOption>()

        override suspend fun availability(config: HybridConfig, withImage: Boolean): AvailabilityResult {
            assertTrue(config.androidModel != AndroidModelOption.AUTO, "auto reached the engine")
            availabilityCalls += config.androidModel
            return status(config.androidModel)
        }

        override fun prepare(config: HybridConfig, withImage: Boolean): Flow<Double?> {
            assertTrue(config.androidModel != AndroidModelOption.AUTO, "auto reached the engine")
            prepareCalls += config.androidModel
            onPrepare(config.androidModel)
            return flowOf(0.5, 1.0)
        }

        override suspend fun generate(config: HybridConfig, request: GenerateRequest): GenerateResult {
            assertTrue(config.androidModel != AndroidModelOption.AUTO, "auto reached the engine")
            generateCalls += Call(config.androidModel, request)
            return onGenerate(config.androidModel, request)
        }

        val probes get() = generateCalls.filter { it.request.requestId == AutoModelEngine.PROBE_REQUEST_ID }
        val work get() = generateCalls.filter { it.request.requestId != AutoModelEngine.PROBE_REQUEST_ID }

        companion object {
            fun label(option: AndroidModelOption) = when (option) {
                AndroidModelOption.PREVIEW -> "nano-v4-full"
                AndroidModelOption.STABLE -> "nano-v3"
                else -> option.wire
            }
        }
    }

    /** Preview reports available but every generate on it fails with code 8 (the Pixel 9). */
    private fun pixel9() = FakeEngine(onGenerate = { option, _ ->
        if (option == AndroidModelOption.PREVIEW) throw code8()
        GenerateResult("OK", InferenceSourceWire.ON_DEVICE, FakeEngine.label(option))
    })

    /** Preview passes the startup probe, then fails like the Pixel 9 (and the SDK swallows it). */
    private fun breaksAfterStartup(probeWorks: AtomicBoolean) = FakeEngine(onGenerate = { option, req ->
        val probe = req.requestId == AutoModelEngine.PROBE_REQUEST_ID
        when {
            option != AndroidModelOption.PREVIEW ->
                GenerateResult("local", InferenceSourceWire.ON_DEVICE, FakeEngine.label(option))
            probe && probeWorks.get() -> GenerateResult("OK", InferenceSourceWire.ON_DEVICE, "nano-v4-full")
            probe -> throw code8()
            req.mode == HybridMode.PREFER_ON_DEVICE -> GenerateResult("cloud", InferenceSourceWire.CLOUD, "gemini-x")
            else -> throw code8()
        }
    })

    private fun request(mode: HybridMode = HybridMode.ONLY_ON_DEVICE, id: String = "r1") = GenerateRequest(
        requestId = id,
        mode = mode,
        feature = "coach_lite",
        systemInstruction = null,
        parts = listOf(HybridPart.Text("How long do I rest the dough?")),
        jsonSchema = null,
        maxOutputTokens = 64,
        timeoutMs = 5_000,
    )

    private fun engine(
        inner: HybridEngine,
        log: MutableList<String> = CopyOnWriteArrayList(),
        selectionTimeoutMs: Long = 2_000,
        verify: Boolean = false,
        scope: CoroutineScope = lifetime,
    ) = AutoModelEngine(
        inner,
        scope,
        selectionTimeoutMs = selectionTimeoutMs,
        verifyChoice = verify,
        log = { log += it },
    )

    /** Configures (which waits for the selection) and returns the engine. */
    private suspend fun AutoModelEngine.selected(): AutoModelEngine {
        withTimeout(5_000) { configured(auto) }
        return this
    }

    // --- Startup selection ---

    @Test
    fun configureWaitsForTheSelection() = runBlocking<Unit> {
        val gate = CompletableDeferred<Unit>()
        val inner = FakeEngine(status = {
            if (it == AndroidModelOption.PREVIEW) runBlocking { gate.await() }
            AvailabilityResult(OnDeviceStatus.AVAILABLE, modelLabel = FakeEngine.label(it))
        })
        val e = engine(inner)
        val configuring = async(Dispatchers.Default) { e.configured(auto) }
        delay(100)
        assertTrue(configuring.isActive, "configure is not answered before the selection")
        // A request meanwhile does not wait: it runs on stable.
        assertEquals("nano-v3", withTimeout(1_000) { e.generate(auto, request()) }.modelLabel)

        gate.complete(Unit)
        withTimeout(5_000) { configuring.await() }
        assertEquals(AndroidModelOption.PREVIEW, e.decision)
        // Later configures share the finished selection.
        withTimeout(1_000) { e.configured(auto) }
        assertEquals(1, inner.probes.size)
    }

    @Test
    fun anAlreadyAvailablePreviewThatAnswersIsSelected() = runBlocking<Unit> {
        val inner = FakeEngine()
        val log = CopyOnWriteArrayList<String>()
        val e = engine(inner, log).selected()

        assertEquals(AndroidModelOption.PREVIEW, e.decision)
        assertEquals(AndroidModelOption.PREVIEW, e.modelOption(auto))
        val probe = inner.probes.single()
        assertEquals(AndroidModelOption.PREVIEW, probe.option)
        assertEquals(HybridMode.ONLY_ON_DEVICE, probe.request.mode)
        assertEquals(AutoModelEngine.PROBE_MAX_TOKENS, probe.request.maxOutputTokens)
        assertEquals(listOf(HybridPart.Text(AutoModelEngine.PROBE_PROMPT)), probe.request.parts)
        assertTrue(log.any { "source=onDevice" in it && "model=nano-v4-full" in it && "latencyMs=" in it }, "$log")
        val a = e.availability(auto, false)
        assertEquals(AndroidModelOption.PREVIEW, a.modelOption)
        assertEquals("nano-v4-full", a.modelLabel)
        assertEquals(listOf(1.0), e.prepare(auto, false).toList())
        assertTrue(inner.prepareCalls.isEmpty(), "a ready preview needs no setup")
    }

    @Test
    fun aPreviewThatFailsTheProbeLeavesStable() = runBlocking<Unit> {
        val inner = pixel9()
        val log = CopyOnWriteArrayList<String>()
        val e = engine(inner, log).selected()

        assertEquals(AndroidModelOption.STABLE, e.decision)
        assertTrue(log.any { "cannot answer" in it && "NOT_AVAILABLE" in it }, "$log")
        assertTrue(log.none { AutoModelEngine.PROBE_PROMPT in it })
        val a = e.availability(auto, true)
        assertEquals(AndroidModelOption.STABLE, a.modelOption)
        assertEquals("nano-v3", a.modelLabel)
        assertEquals("nano-v3", e.generate(auto, request()).modelLabel)
    }

    @Test
    fun aPreviewNotAlreadyAvailableIsNeverProbedDownloadedOrPromoted() = runBlocking<Unit> {
        for (status in listOf(OnDeviceStatus.DOWNLOADABLE, OnDeviceStatus.DOWNLOADING, OnDeviceStatus.UNAVAILABLE)) {
            val preview = AtomicReference(status)
            val inner = FakeEngine(status = {
                if (it == AndroidModelOption.PREVIEW) AvailabilityResult(preview.get())
                else AvailabilityResult(OnDeviceStatus.DOWNLOADABLE, Reasons.MODEL_NOT_READY)
            })
            val e = engine(inner).selected()
            assertEquals(AndroidModelOption.STABLE, e.decision, "$status")
            val a = e.availability(auto, false)
            assertEquals(OnDeviceStatus.DOWNLOADABLE, a.status)
            assertEquals(AndroidModelOption.STABLE, a.modelOption)
            assertEquals(listOf(0.5, 1.0), e.prepare(auto, false).toList())
            preview.set(OnDeviceStatus.AVAILABLE)
            e.availability(auto, false)
            e.prepare(auto, false).toList()
            e.configured(auto)
            assertTrue(inner.probes.isEmpty(), "$status")
            assertEquals(AndroidModelOption.STABLE, e.decision)
            assertEquals(listOf(AndroidModelOption.STABLE, AndroidModelOption.STABLE), inner.prepareCalls)
        }
    }

    @Test
    fun theProbeMustReturnTextFromTheDevice() = runBlocking<Unit> {
        val answers = listOf(
            GenerateResult("", InferenceSourceWire.ON_DEVICE, "nano-v4-full"),
            GenerateResult("  \n", InferenceSourceWire.ON_DEVICE, "nano-v4-full"),
            GenerateResult("OK", InferenceSourceWire.CLOUD, "gemini-x"),
        )
        for (answer in answers) {
            val inner = FakeEngine(onGenerate = { _, _ -> answer })
            assertEquals(AndroidModelOption.STABLE, engine(inner).selected().decision, "$answer")
        }
    }

    @Test
    fun aSelectionThatHangsEndsAtFiveSecondsAsStable() = runBlocking<Unit> {
        assertEquals(5_000L, AutoModelEngine.SELECTION_TIMEOUT_MS)
        val release = CompletableDeferred<Unit>()
        val inner = FakeEngine(onGenerate = { option, _ ->
            // A probe that ignores cancellation, then would have answered.
            withContext(NonCancellable) { release.await() }
            GenerateResult("OK", InferenceSourceWire.ON_DEVICE, FakeEngine.label(option))
        })
        val log = CopyOnWriteArrayList<String>()
        val e = engine(inner, log, selectionTimeoutMs = 100)
        val start = System.nanoTime()
        e.selected()
        assertTrue((System.nanoTime() - start) / 1_000_000 < 2_000)
        assertTrue(log.any { "no selection within 100 ms" in it }, "$log")
        release.complete(Unit)
        delay(100)
        assertEquals(AndroidModelOption.STABLE, e.decision, "a late preview answer is discarded")
    }

    @Test
    fun aStatusLookupThatThrowsOrStallsMeansStable() = runBlocking<Unit> {
        val log = CopyOnWriteArrayList<String>()
        val throws = FakeEngine(status = {
            if (it == AndroidModelOption.PREVIEW) throw IllegalStateException("AICore died")
            AvailabilityResult(OnDeviceStatus.AVAILABLE, modelLabel = "nano-v3")
        })
        assertEquals(AndroidModelOption.STABLE, engine(throws, log).selected().decision)
        assertTrue(log.any { "status check failed" in it }, "$log")

        val main = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        try {
            val stalls = FakeEngine(status = {
                if (it == AndroidModelOption.PREVIEW) Thread.sleep(1_000) // a synchronous native stall
                AvailabilityResult(OnDeviceStatus.AVAILABLE, modelLabel = FakeEngine.label(it))
            })
            val plugin = CoroutineScope(SupervisorJob() + main)
            // Production default for `work` (Dispatchers.IO); the plugin's scope is single-threaded.
            val e = AutoModelEngine(stalls, plugin, selectionTimeoutMs = 20)
            val start = System.nanoTime()
            withContext(main) { e.configured(auto) }
            val ms = (System.nanoTime() - start) / 1_000_000
            assertTrue(ms < 500, "configure answered in $ms ms despite a 1 s stall")
            assertEquals(AndroidModelOption.STABLE, e.decision)
            plugin.cancel()
        } finally {
            main.close()
        }
    }

    @Test
    fun detachingStopsTheSelection() = runBlocking<Unit> {
        val release = CompletableDeferred<Unit>()
        val lookup = CompletableDeferred<Unit>()
        val inner = FakeEngine(status = {
            lookup.complete(Unit)
            runBlocking { withContext(NonCancellable) { release.await() } }
            AvailabilityResult(OnDeviceStatus.AVAILABLE, modelLabel = FakeEngine.label(it))
        })
        val owner = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val e = engine(inner, scope = owner)
        val configuring = async(Dispatchers.Default) { runCatching { e.configured(auto) } }
        withTimeout(5_000) { lookup.await() }
        owner.cancel() // the plugin detaches
        assertTrue(withTimeout(5_000) { configuring.await() }.exceptionOrNull() is CancellationException)
        release.complete(Unit)
        delay(200)
        assertTrue(inner.generateCalls.isEmpty(), "no probe after teardown")
        assertEquals(AndroidModelOption.STABLE, e.decision)
    }

    @Test
    fun debugBuildsProbeStableWhenItIsKept() = runBlocking<Unit> {
        val log = CopyOnWriteArrayList<String>()
        val inner = pixel9()
        val e = engine(inner, log, verify = true).selected()
        withTimeout(5_000) { assertNotNull(e.verifyJob).join() }
        assertEquals(listOf(AndroidModelOption.PREVIEW, AndroidModelOption.STABLE), inner.probes.map { it.option })
        assertTrue(log.any { "option=stable source=onDevice model=nano-v3" in it }, "$log")

        val failing = CopyOnWriteArrayList<String>()
        val nothing = FakeEngine(
            status = { AvailabilityResult(OnDeviceStatus.UNAVAILABLE) },
            onGenerate = { _, _ -> throw code8() },
        )
        val f = engine(nothing, failing, verify = true).selected()
        withTimeout(5_000) { assertNotNull(f.verifyJob).join() }
        assertTrue(failing.any { "stable did not answer the debug probe" in it }, "$failing")

        val hangs = FakeEngine(status = { AvailabilityResult(OnDeviceStatus.UNAVAILABLE) }, onGenerate = { _, _ -> awaitCancellation() })
        val slow = CopyOnWriteArrayList<String>()
        val h = engine(hangs, slow, selectionTimeoutMs = 50, verify = true).selected()
        withTimeout(5_000) { assertNotNull(h.verifyJob).join() }
        assertTrue(slow.any { "no answer within 50 ms" in it }, "$slow")
        assertNull(engine(pixel9()).selected().verifyJob, "release builds skip it")
    }

    // --- The ratchet: preview to stable, once, for good ---

    @Test
    fun aFailedCallOnPreviewReturnsItsErrorAndLaterCallsUseStable() = runBlocking<Unit> {
        val inner = breaksAfterStartup(AtomicBoolean(true))
        val log = CopyOnWriteArrayList<String>()
        val e = engine(inner, log).selected()
        assertEquals(AndroidModelOption.PREVIEW, e.decision)

        assertFailsWith<FirebaseAIOnDeviceNotAvailableException> { e.generate(auto, request()) }
        assertEquals(listOf(AndroidModelOption.PREVIEW), inner.work.map { it.option }, "no hidden retry")
        assertEquals(AndroidModelOption.STABLE, e.decision)
        assertTrue(log.any { "call on preview failed" in it }, "$log")
        assertEquals("local", e.generate(auto, request(id = "r2")).text)
        assertEquals(AndroidModelOption.STABLE, inner.work.last().option)
        assertEquals(AndroidModelOption.STABLE, e.availability(auto, false).modelOption)
        e.configured(auto)
        assertEquals(1, inner.probes.size, "never re-checked")
    }

    @Test
    fun aBusyPreviewFailureAlsoRatchets() = runBlocking<Unit> {
        val inner = FakeEngine(onGenerate = { option, req ->
            if (option == AndroidModelOption.PREVIEW && req.requestId != AutoModelEngine.PROBE_REQUEST_ID) {
                throw GenAiException("busy", null, GenAiException.ErrorCode.BUSY)
            }
            GenerateResult("OK", InferenceSourceWire.ON_DEVICE, FakeEngine.label(option))
        })
        val e = engine(inner).selected()
        assertFailsWith<GenAiException> { e.generate(auto, request(HybridMode.PREFER_ON_DEVICE)) }
        assertEquals(AndroidModelOption.STABLE, e.decision)
    }

    @Test
    fun inputErrorsCloudOnlyCallsAndCancellationDoNotRatchet() = runBlocking<Unit> {
        val inner = FakeEngine(onGenerate = { _, req ->
            when {
                req.requestId == AutoModelEngine.PROBE_REQUEST_ID -> GenerateResult("OK", InferenceSourceWire.ON_DEVICE, "x")
                req.feature == "bad" -> throw HybridError(HybridErrorCode.UNSUPPORTED_INPUT, "bad image")
                req.feature == "gone" -> throw CancellationException("gone")
                else -> throw code8()
            }
        })
        val e = engine(inner).selected()
        assertFailsWith<HybridError> { e.generate(auto, request().copy(feature = "bad")) }
        assertFailsWith<CancellationException> { e.generate(auto, request().copy(feature = "gone")) }
        assertFailsWith<FirebaseAIOnDeviceNotAvailableException> { e.generate(auto, request(HybridMode.ONLY_IN_CLOUD)) }
        assertEquals(AndroidModelOption.PREVIEW, e.decision)
    }

    @Test
    fun aPreviewThatLosesReadinessRatchetsAndReportsStablesStatus() = runBlocking<Unit> {
        for (lost in listOf(OnDeviceStatus.UNAVAILABLE, OnDeviceStatus.DOWNLOADABLE, OnDeviceStatus.DOWNLOADING)) {
            val preview = AtomicReference(OnDeviceStatus.AVAILABLE)
            val inner = FakeEngine(status = {
                if (it == AndroidModelOption.PREVIEW) AvailabilityResult(preview.get(), modelLabel = "nano-v4-full")
                else AvailabilityResult(OnDeviceStatus.AVAILABLE, modelLabel = "nano-v3")
            })
            val e = engine(inner).selected()
            assertEquals(AndroidModelOption.PREVIEW, e.decision)
            preview.set(lost)
            val a = e.availability(auto, false)
            assertEquals(OnDeviceStatus.AVAILABLE, a.status, "$lost")
            assertEquals(AndroidModelOption.STABLE, a.modelOption)
            assertEquals("nano-v3", a.modelLabel)
            assertEquals(AndroidModelOption.STABLE, e.decision)
            // Back to available: no promotion.
            preview.set(OnDeviceStatus.AVAILABLE)
            assertEquals(AndroidModelOption.STABLE, e.availability(auto, false).modelOption)
        }
    }

    @Test
    fun prepareAfterTheRatchetSetsUpStableNeverPreview() = runBlocking<Unit> {
        val preview = AtomicReference(OnDeviceStatus.AVAILABLE)
        val inner = FakeEngine(status = {
            if (it == AndroidModelOption.PREVIEW) AvailabilityResult(preview.get())
            else AvailabilityResult(OnDeviceStatus.DOWNLOADABLE)
        })
        val e = engine(inner).selected()
        preview.set(OnDeviceStatus.DOWNLOADABLE) // e.g. a reinstall
        assertEquals(listOf(0.5, 1.0), e.prepare(auto, false).toList())
        assertEquals(listOf(AndroidModelOption.STABLE), inner.prepareCalls)
        assertEquals(AndroidModelOption.STABLE, e.decision)
    }

    @Test
    fun aPreviewStatusCheckThatThrowsRatchets() = runBlocking<Unit> {
        val broken = AtomicBoolean(false)
        val inner = FakeEngine(status = {
            if (it == AndroidModelOption.PREVIEW && broken.get()) throw IllegalStateException("AICore died")
            AvailabilityResult(OnDeviceStatus.AVAILABLE, modelLabel = FakeEngine.label(it))
        })
        val e = engine(inner).selected()
        broken.set(true)
        assertEquals(AndroidModelOption.STABLE, e.availability(auto, false).modelOption)
        assertEquals(AndroidModelOption.STABLE, e.decision)
    }

    @Test
    fun availabilityNeverPublishesAPreviewThatWasDemotedDuringItsLookup() = runBlocking<Unit> {
        val hold = CompletableDeferred<Unit>()
        val holding = CompletableDeferred<Unit>()
        val armed = AtomicBoolean(false)
        val inner = FakeEngine(
            status = {
                if (it == AndroidModelOption.PREVIEW && armed.get()) {
                    holding.complete(Unit)
                    runBlocking { hold.await() }
                }
                AvailabilityResult(OnDeviceStatus.AVAILABLE, modelLabel = FakeEngine.label(it))
            },
            onGenerate = breaksAfterStartup(AtomicBoolean(true)).onGenerate,
        )
        val e = engine(inner).selected()
        armed.set(true)
        val inFlight = async(Dispatchers.Default) { e.availability(auto, false) }
        withTimeout(5_000) { holding.await() }
        assertFailsWith<FirebaseAIOnDeviceNotAvailableException> { e.generate(auto, request()) }
        hold.complete(Unit)
        val a = inFlight.await()
        assertEquals(AndroidModelOption.STABLE, a.modelOption)
        assertEquals("nano-v3", a.modelLabel)
        assertEquals(e.modelOption(auto), a.modelOption)
    }

    // --- Pass-through ---

    @Test
    fun explicitOptionsPassThrough() = runBlocking<Unit> {
        for (option in listOf(AndroidModelOption.PREVIEW, AndroidModelOption.PREVIEW_FAST, AndroidModelOption.STABLE)) {
            val inner = pixel9()
            val e = engine(inner)
            val config = auto.copy(androidModel = option)
            e.configured(config)
            assertTrue(inner.probes.isEmpty(), "no selection for $option")
            assertEquals(option, e.availability(config, false).modelOption)
            assertEquals(option, e.modelOption(config))
            assertEquals(listOf(0.5, 1.0), e.prepare(config, false).toList())
            assertEquals(listOf(option), inner.prepareCalls)
            if (option == AndroidModelOption.PREVIEW) {
                assertFailsWith<FirebaseAIOnDeviceNotAvailableException> { e.generate(config, request()) }
            } else {
                e.generate(config, request())
            }
            assertEquals(listOf(option), inner.generateCalls.map { it.option }, "$option: no probe, no retry")
            assertEquals(AndroidModelOption.STABLE, e.decision)
        }
    }
}

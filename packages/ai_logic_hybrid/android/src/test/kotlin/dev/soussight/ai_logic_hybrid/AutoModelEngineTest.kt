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
        probeTimeoutMs: Long = 2_000,
        statusTimeoutMs: Long = 2_000,
        verify: Boolean = false,
        scope: CoroutineScope = lifetime,
    ) = AutoModelEngine(
        inner,
        scope,
        probeTimeoutMs = probeTimeoutMs,
        statusTimeoutMs = statusTimeoutMs,
        verifyChoice = verify,
        log = { log += it },
    )

    /** Runs the startup check to completion. */
    private suspend fun AutoModelEngine.checked(): AutoModelEngine {
        configured(auto)
        withTimeout(5_000) { checkJob?.join() }
        return this
    }

    // --- Startup selection ---

    @Test
    fun stableIsUsedUntilTheCheckProvesPreview() = runBlocking {
        val gate = CompletableDeferred<Unit>()
        val inner = FakeEngine(status = {
            if (it == AndroidModelOption.PREVIEW) runBlocking { gate.await() }
            AvailabilityResult(OnDeviceStatus.AVAILABLE, modelLabel = FakeEngine.label(it))
        })
        val e = engine(inner)
        e.configured(auto)

        // The check is stuck; a request neither waits for it nor uses preview.
        val r = withTimeout(1_000) { e.generate(auto, request()) }
        assertEquals("nano-v3", r.modelLabel)
        assertEquals(listOf(AndroidModelOption.STABLE), inner.work.map { it.option })
        assertEquals(AndroidModelOption.STABLE, e.decision)
        assertEquals(AndroidModelOption.STABLE, e.modelOption(auto))

        gate.complete(Unit)
        withTimeout(5_000) { assertNotNull(e.checkJob).join() }
        assertEquals(AndroidModelOption.PREVIEW, e.decision)
        e.generate(auto, request(id = "r2"))
        assertEquals(AndroidModelOption.PREVIEW, inner.work.last().option)
    }

    @Test
    fun previewThatAnswersTheProbeIsSelected() = runBlocking {
        val inner = FakeEngine()
        val log = CopyOnWriteArrayList<String>()
        val e = engine(inner, log).checked()

        assertEquals(AndroidModelOption.PREVIEW, e.decision)
        val probe = inner.probes.single()
        assertEquals(AndroidModelOption.PREVIEW, probe.option)
        assertEquals(HybridMode.ONLY_ON_DEVICE, probe.request.mode)
        assertEquals(AutoModelEngine.PROBE_MAX_TOKENS, probe.request.maxOutputTokens)
        assertEquals(listOf(HybridPart.Text(AutoModelEngine.PROBE_PROMPT)), probe.request.parts)
        assertTrue(log.any { "source=onDevice" in it && "model=nano-v4-full" in it && "latencyMs=" in it }, "$log")
        val a = e.availability(auto, false)
        assertEquals(AndroidModelOption.PREVIEW, a.modelOption)
        assertEquals("nano-v4-full", a.modelLabel)
        // Already selected: configuring again starts nothing.
        e.configured(auto)
        assertEquals(1, inner.probes.size)
    }

    @Test
    fun previewThatFailsTheProbeIsNotTriedAgainThisRun() = runBlocking {
        val inner = pixel9()
        val log = CopyOnWriteArrayList<String>()
        val e = engine(inner, log).checked()

        assertEquals(AndroidModelOption.STABLE, e.decision)
        assertTrue(log.any { "cannot answer" in it && "NOT_AVAILABLE" in it }, "$log")
        assertTrue(log.none { AutoModelEngine.PROBE_PROMPT in it })
        val a = e.availability(auto, true)
        assertEquals(AndroidModelOption.STABLE, a.modelOption)
        assertEquals("nano-v3", a.modelLabel)
        assertEquals("nano-v3", e.generate(auto, request()).modelLabel)
        e.configured(auto)
        e.prepare(auto, false).toList()
        withTimeout(5_000) { e.checkJob?.join() }
        assertEquals(1, inner.probes.size, "the broken preview is probed once per run")
    }

    @Test
    fun theProbeMustReturnTextFromTheDevice() = runBlocking {
        val answers = listOf(
            GenerateResult("", InferenceSourceWire.ON_DEVICE, "nano-v4-full"),
            GenerateResult("  \n", InferenceSourceWire.ON_DEVICE, "nano-v4-full"),
            GenerateResult("OK", InferenceSourceWire.CLOUD, "gemini-x"),
        )
        for (answer in answers) {
            val inner = FakeEngine(onGenerate = { _, _ -> answer })
            assertEquals(AndroidModelOption.STABLE, engine(inner).checked().decision, "$answer")
        }
        val busy = FakeEngine(onGenerate = { _, _ -> throw GenAiException("busy", null, GenAiException.ErrorCode.BUSY) })
        assertEquals(AndroidModelOption.STABLE, engine(busy).checked().decision)
    }

    @Test
    fun aHungProbeOrStatusLookupEndsTheCheckAtItsDeadline() = runBlocking {
        val hangProbe = FakeEngine(onGenerate = { _, _ -> withContext(NonCancellable) { delay(3_000) }; error("late") })
        val log = CopyOnWriteArrayList<String>()
        var start = System.nanoTime()
        assertEquals(AndroidModelOption.STABLE, engine(hangProbe, log, probeTimeoutMs = 100).checked().decision)
        assertTrue((System.nanoTime() - start) / 1_000_000 < 2_000)
        assertTrue(log.any { "no answer within 100 ms" in it }, "$log")

        val release = CompletableDeferred<Unit>()
        val hangStatus = FakeEngine(status = {
            if (it == AndroidModelOption.PREVIEW) runBlocking { withContext(NonCancellable) { release.await() } }
            AvailabilityResult(OnDeviceStatus.AVAILABLE, modelLabel = FakeEngine.label(it))
        })
        start = System.nanoTime()
        val e = engine(hangStatus, statusTimeoutMs = 100).checked()
        assertTrue((System.nanoTime() - start) / 1_000_000 < 2_000)
        release.complete(Unit)
        delay(100)
        assertEquals(AndroidModelOption.STABLE, e.decision, "a late status answer is discarded")
        assertTrue(hangStatus.probes.isEmpty())
    }

    @Test
    fun theStatusDeadlineHoldsWhenThePluginThreadIsBlocked() = runBlocking {
        val main = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        try {
            val inner = FakeEngine(status = {
                if (it == AndroidModelOption.PREVIEW) Thread.sleep(1_000) // a synchronous native stall
                AvailabilityResult(OnDeviceStatus.AVAILABLE, modelLabel = FakeEngine.label(it))
            })
            val plugin = CoroutineScope(SupervisorJob() + main)
            // Production default for `work` (Dispatchers.IO); the plugin's scope is single-threaded.
            val e = AutoModelEngine(inner, plugin, statusTimeoutMs = 20)
            val start = System.nanoTime()
            withContext(main) { e.configured(auto) }
            withTimeout(5_000) { assertNotNull(e.checkJob).join() }
            val ms = (System.nanoTime() - start) / 1_000_000
            assertTrue(ms < 500, "check ended in $ms ms despite a 1 s stall")
            assertEquals(AndroidModelOption.STABLE, e.decision)
            plugin.cancel()
        } finally {
            main.close()
        }
    }

    @Test
    fun detachingStopsTheCheck() = runBlocking {
        val release = CompletableDeferred<Unit>()
        val lookup = CompletableDeferred<Unit>()
        val inner = FakeEngine(status = {
            lookup.complete(Unit)
            runBlocking { withContext(NonCancellable) { release.await() } }
            AvailabilityResult(OnDeviceStatus.AVAILABLE, modelLabel = FakeEngine.label(it))
        })
        val owner = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val e = engine(inner, scope = owner)
        e.configured(auto)
        withTimeout(5_000) { lookup.await() }
        owner.cancel() // the plugin detaches
        release.complete(Unit)
        delay(200)
        assertTrue(inner.generateCalls.isEmpty(), "no probe after teardown")
        assertEquals(AndroidModelOption.STABLE, e.decision)
    }

    @Test
    fun oneCheckAtATime() = runBlocking {
        val release = CompletableDeferred<Unit>()
        val inner = FakeEngine(onGenerate = { option, _ ->
            release.await()
            GenerateResult("OK", InferenceSourceWire.ON_DEVICE, FakeEngine.label(option))
        })
        val e = engine(inner)
        val first = e.startCheck(auto)
        repeat(3) { assertSame(first, e.startCheck(auto)) }
        release.complete(Unit)
        withTimeout(5_000) { assertNotNull(first).join() }
        assertEquals(1, inner.probes.size)
    }

    @Test
    fun previewNotReadyAtStartupIsCheckedAgainAfterPrepare() = runBlocking {
        val preview = AtomicReference(OnDeviceStatus.DOWNLOADABLE)
        val inner = FakeEngine(
            status = {
                if (it == AndroidModelOption.PREVIEW) AvailabilityResult(preview.get(), Reasons.MODEL_NOT_READY, "nano-v4-full")
                else AvailabilityResult(OnDeviceStatus.UNAVAILABLE, Reasons.DEVICE_NOT_ELIGIBLE)
            },
            onPrepare = { preview.set(OnDeviceStatus.AVAILABLE) }, // the download finishes
        )
        val e = engine(inner).checked()
        assertEquals(AndroidModelOption.STABLE, e.decision)
        assertTrue(inner.probes.isEmpty())

        val a = e.availability(auto, false)
        assertEquals(OnDeviceStatus.DOWNLOADABLE, a.status, "setup stays visible")
        assertEquals(AndroidModelOption.PREVIEW, a.modelOption)

        assertEquals(listOf(0.5, 1.0), e.prepare(auto, false).toList())
        assertEquals(listOf(AndroidModelOption.PREVIEW), inner.prepareCalls)
        withTimeout(5_000) { assertNotNull(e.checkJob).join() }
        assertEquals(1, inner.probes.size, "probed before it is used")
        assertEquals(AndroidModelOption.PREVIEW, e.decision)
    }

    @Test
    fun anUnprovenAvailablePreviewIsNeverReportedReady() = runBlocking {
        val inner = FakeEngine(status = {
            if (it == AndroidModelOption.PREVIEW) AvailabilityResult(OnDeviceStatus.AVAILABLE, modelLabel = "nano-v4-full")
            else AvailabilityResult(OnDeviceStatus.UNAVAILABLE, Reasons.DEVICE_NOT_ELIGIBLE)
        }, onGenerate = { _, _ -> awaitCancellation() })
        val e = engine(inner, probeTimeoutMs = 60_000)
        val a = e.availability(auto, false) // no configure yet: this starts the check
        assertEquals(OnDeviceStatus.UNAVAILABLE, a.status)
        assertEquals(AndroidModelOption.STABLE, a.modelOption)
        assertNotNull(e.checkJob)
    }

    @Test
    fun debugBuildsProbeStableWhenItIsKept() = runBlocking {
        val log = CopyOnWriteArrayList<String>()
        val inner = pixel9()
        engine(inner, log, verify = true).checked()
        assertEquals(listOf(AndroidModelOption.PREVIEW, AndroidModelOption.STABLE), inner.probes.map { it.option })
        assertTrue(log.any { "option=stable source=onDevice model=nano-v3" in it }, "$log")

        val failing = CopyOnWriteArrayList<String>()
        val nothing = FakeEngine(
            status = { AvailabilityResult(OnDeviceStatus.UNAVAILABLE) },
            onGenerate = { _, _ -> throw code8() },
        )
        engine(nothing, failing, verify = true).checked()
        assertTrue(failing.any { "stable did not answer the debug probe" in it }, "$failing")
    }

    // --- Availability reporting ---

    @Test
    fun aDownloadableStableIsNeverHidden() = runBlocking {
        val inner = FakeEngine(status = {
            if (it == AndroidModelOption.PREVIEW) AvailabilityResult(OnDeviceStatus.UNAVAILABLE, Reasons.NOT_ENROLLED)
            else AvailabilityResult(OnDeviceStatus.DOWNLOADABLE, Reasons.MODEL_NOT_READY)
        })
        val e = engine(inner).checked()
        val a = e.availability(auto, false)
        assertEquals(OnDeviceStatus.DOWNLOADABLE, a.status)
        assertEquals(AndroidModelOption.STABLE, a.modelOption)
        e.prepare(auto, false).toList()
        assertEquals(listOf(AndroidModelOption.STABLE), inner.prepareCalls)
    }

    @Test
    fun aLostPreviewShowsStableSetupAndPromotesStableWhenReady() = runBlocking {
        val preview = AtomicReference(OnDeviceStatus.AVAILABLE)
        val stable = AtomicReference(OnDeviceStatus.DOWNLOADABLE)
        val inner = FakeEngine(status = {
            if (it == AndroidModelOption.PREVIEW) AvailabilityResult(preview.get(), modelLabel = "nano-v4-full")
            else AvailabilityResult(stable.get(), modelLabel = "nano-v3")
        })
        val e = engine(inner).checked()
        assertEquals(AndroidModelOption.PREVIEW, e.decision)

        preview.set(OnDeviceStatus.UNAVAILABLE)
        val a = e.availability(auto, false)
        assertEquals(OnDeviceStatus.DOWNLOADABLE, a.status, "the recovery path is shown")
        assertEquals(AndroidModelOption.STABLE, a.modelOption)
        e.prepare(auto, false).toList()
        assertEquals(listOf(AndroidModelOption.STABLE), inner.prepareCalls)

        stable.set(OnDeviceStatus.AVAILABLE)
        val ready = e.availability(auto, false)
        assertEquals(OnDeviceStatus.AVAILABLE, ready.status)
        assertEquals(AndroidModelOption.STABLE, ready.modelOption)
        assertEquals(AndroidModelOption.STABLE, e.decision)
    }

    @Test
    fun aDownloadingModelOutranksADownloadableOne() = runBlocking {
        val inner = FakeEngine(status = {
            if (it == AndroidModelOption.PREVIEW) AvailabilityResult(OnDeviceStatus.DOWNLOADING)
            else AvailabilityResult(OnDeviceStatus.DOWNLOADABLE)
        })
        val a = engine(inner).checked().availability(auto, false)
        assertEquals(OnDeviceStatus.DOWNLOADING, a.status)
        assertEquals(AndroidModelOption.PREVIEW, a.modelOption)
    }

    @Test
    fun aStatusLookupThatThrowsCountsAsNotReady() = runBlocking {
        val log = CopyOnWriteArrayList<String>()
        val inner = FakeEngine(status = { throw IllegalStateException("AICore died") })
        val e = engine(inner, log).checked()
        assertEquals(AndroidModelOption.STABLE, e.decision)
        val a = e.availability(auto, false)
        assertEquals(OnDeviceStatus.UNAVAILABLE, a.status)
        assertEquals(Reasons.MODEL_NOT_READY, a.reason)
        assertTrue(log.any { "status check failed" in it }, "$log")
    }

    @Test
    fun nothingObtainableReportsTheSelectedModel() = runBlocking {
        val inner = FakeEngine(status = { AvailabilityResult(OnDeviceStatus.UNAVAILABLE, Reasons.DEVICE_NOT_ELIGIBLE) })
        val a = engine(inner).checked().availability(auto, false)
        assertEquals(OnDeviceStatus.UNAVAILABLE, a.status)
        assertEquals(Reasons.DEVICE_NOT_ELIGIBLE, a.reason)
        assertEquals(AndroidModelOption.STABLE, a.modelOption)
    }

    @Test
    fun aBrokenPreviewIsNotOfferedForSetup() = runBlocking {
        val preview = AtomicReference(OnDeviceStatus.AVAILABLE)
        val inner = FakeEngine(
            status = {
                if (it == AndroidModelOption.PREVIEW) AvailabilityResult(preview.get())
                else AvailabilityResult(OnDeviceStatus.UNAVAILABLE, Reasons.DEVICE_NOT_ELIGIBLE)
            },
            onGenerate = { _, _ -> throw code8() },
        )
        val e = engine(inner).checked()
        preview.set(OnDeviceStatus.DOWNLOADABLE)
        val a = e.availability(auto, false)
        assertEquals(OnDeviceStatus.UNAVAILABLE, a.status)
        assertEquals(AndroidModelOption.STABLE, a.modelOption)
    }

    @Test
    fun aHungReportingLookupIsBounded() = runBlocking {
        val inner = FakeEngine(status = {
            if (it == AndroidModelOption.STABLE) runBlocking { awaitCancellation() }
            AvailabilityResult(OnDeviceStatus.UNAVAILABLE)
        })
        val e = engine(inner, statusTimeoutMs = 50)
        val a = withTimeout(2_000) { e.availability(auto, false) }
        assertEquals(OnDeviceStatus.UNAVAILABLE, a.status)
        assertEquals(Reasons.MODEL_NOT_READY, a.reason)
    }

    @Test
    fun availabilityReportsADowngradeThatLandsDuringItsLookup() = runBlocking {
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
        val e = engine(inner).checked()
        assertEquals(AndroidModelOption.PREVIEW, e.decision)
        armed.set(true)
        val inFlight = async(Dispatchers.Default) { e.availability(auto, false) }
        withTimeout(5_000) { holding.await() }
        e.generate(auto, request()) // code 8 on preview: stable from now on
        hold.complete(Unit)
        val a = inFlight.await()
        assertEquals(AndroidModelOption.STABLE, a.modelOption)
        assertEquals("nano-v3", a.modelLabel)
        assertEquals(e.modelOption(auto), a.modelOption)
    }

    // --- Mid-session ---

    @Test
    fun aCodeEightOnPreviewRetriesOnceOnStableOnDeviceAndSticks() = runBlocking {
        val inner = breaksAfterStartup(AtomicBoolean(true))
        val log = CopyOnWriteArrayList<String>()
        val e = engine(inner, log).checked()

        val r = e.generate(auto, request(HybridMode.PREFER_IN_CLOUD))

        assertEquals("nano-v3", r.modelLabel)
        assertEquals(listOf(AndroidModelOption.PREVIEW, AndroidModelOption.STABLE), inner.work.map { it.option })
        assertEquals(HybridMode.ONLY_ON_DEVICE, inner.work.last().request.mode, "narrowed: never cloud, never widened")
        assertEquals(AndroidModelOption.STABLE, e.decision)
        assertTrue(log.any { "mid-session" in it })
        e.generate(auto, request(id = "r2"))
        assertEquals(AndroidModelOption.STABLE, inner.work.last().option)
        e.configured(auto)
        assertEquals(1, inner.probes.size, "a broken preview is not re-checked")
    }

    @Test
    fun theRetryHappensOnlyOnce() = runBlocking {
        val stableError = code8()
        val inner = FakeEngine(onGenerate = { option, req ->
            when {
                req.requestId == AutoModelEngine.PROBE_REQUEST_ID -> GenerateResult("OK", InferenceSourceWire.ON_DEVICE, "x")
                option == AndroidModelOption.STABLE -> throw stableError
                else -> throw code8()
            }
        })
        val e = engine(inner).checked()
        assertSame(stableError, assertFailsWith<FirebaseAIOnDeviceNotAvailableException> { e.generate(auto, request()) })
        assertEquals(2, inner.work.size)
    }

    @Test
    fun noRetryForOtherErrorsCloudOnlyOrStable() = runBlocking {
        val busy = GenAiException("busy", null, GenAiException.ErrorCode.BUSY)
        val inner = FakeEngine(onGenerate = { _, req ->
            when {
                req.requestId == AutoModelEngine.PROBE_REQUEST_ID -> GenerateResult("OK", InferenceSourceWire.ON_DEVICE, "x")
                req.feature == "busy" -> throw busy
                else -> throw code8()
            }
        })
        val e = engine(inner).checked()
        assertSame(busy, assertFailsWith<GenAiException> { e.generate(auto, request().copy(feature = "busy")) })
        assertFailsWith<FirebaseAIOnDeviceNotAvailableException> { e.generate(auto, request(HybridMode.ONLY_IN_CLOUD)) }
        assertEquals(2, inner.work.size)
        assertEquals(AndroidModelOption.PREVIEW, e.decision, "busy or cloud-only failures say nothing about preview")

        val stableOnly = engine(pixel9())
        val onStable = FakeEngine(onGenerate = { _, _ -> throw code8() })
        assertFailsWith<FirebaseAIOnDeviceNotAvailableException> { engine(onStable).generate(auto, request()) }
        assertEquals(1, onStable.work.size)
        assertEquals(AndroidModelOption.STABLE, stableOnly.decision)
    }

    @Test
    fun aLateCodeEightAfterCancellationStartsNoStableRetry() = runBlocking {
        val started = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val inner = FakeEngine(onGenerate = { option, req ->
            if (req.requestId != AutoModelEngine.PROBE_REQUEST_ID && option == AndroidModelOption.PREVIEW) {
                started.complete(Unit)
                withContext(NonCancellable) { release.await() } // native work that ignores cancel
                throw code8()
            }
            GenerateResult("OK", InferenceSourceWire.ON_DEVICE, FakeEngine.label(option))
        })
        val e = engine(inner).checked()
        val call = async(Dispatchers.Default) { e.generate(auto, request()) }
        started.await()
        call.cancel()
        release.complete(Unit)
        call.join()
        assertTrue(call.isCancelled)
        assertEquals(listOf(AndroidModelOption.PREVIEW), inner.work.map { it.option }, "no STABLE generation")
    }

    @Test
    fun cancellationIsPassedThrough() = runBlocking {
        val inner = FakeEngine(onGenerate = { _, _ -> throw CancellationException("gone") })
        assertFailsWith<CancellationException> { engine(inner).generate(auto, request()) }
        assertEquals(1, inner.work.size)
    }

    @Test
    fun aCloudAnswerOnABrokenPreviewMovesLaterRequestsToStable() = runBlocking {
        val probeWorks = AtomicBoolean(true)
        val inner = breaksAfterStartup(probeWorks)
        val log = CopyOnWriteArrayList<String>()
        val e = engine(inner, log).checked()
        probeWorks.set(false)

        val first = e.generate(auto, request(HybridMode.PREFER_ON_DEVICE))
        assertEquals(InferenceSourceWire.CLOUD, first.source, "the completed answer keeps its cloud provenance")
        withTimeout(5_000) { assertNotNull(e.recheckJob).join() }
        assertEquals(AndroidModelOption.STABLE, e.decision)
        assertTrue(log.any { "came from the cloud" in it }, "$log")

        val next = e.generate(auto, request(HybridMode.PREFER_ON_DEVICE, id = "r2"))
        assertEquals(InferenceSourceWire.ON_DEVICE, next.source)
        assertTrue(inner.probes.all { it.request.parts == listOf(HybridPart.Text(AutoModelEngine.PROBE_PROMPT)) })
    }

    @Test
    fun aCloudAnswerWhilePreviewStillAnswersKeepsIt() = runBlocking {
        val inner = breaksAfterStartup(AtomicBoolean(true))
        val e = engine(inner).checked()
        e.generate(auto, request(HybridMode.PREFER_ON_DEVICE))
        withTimeout(5_000) { assertNotNull(e.recheckJob).join() }
        assertEquals(AndroidModelOption.PREVIEW, e.decision)
        assertEquals(2, inner.probes.size)
        // Expected cloud answers start no recheck.
        val other = engine(FakeEngine(onGenerate = { _, req ->
            if (req.requestId == AutoModelEngine.PROBE_REQUEST_ID) GenerateResult("OK", InferenceSourceWire.ON_DEVICE, "x")
            else GenerateResult("cloud", InferenceSourceWire.CLOUD, "gemini-x")
        })).checked()
        other.generate(auto, request(HybridMode.PREFER_IN_CLOUD))
        other.generate(auto, request(HybridMode.ONLY_IN_CLOUD))
        assertNull(other.recheckJob)
    }

    // --- Pass-through and input ---

    @Test
    fun explicitOptionsPassThrough() = runBlocking {
        for (option in listOf(AndroidModelOption.PREVIEW, AndroidModelOption.PREVIEW_FAST, AndroidModelOption.STABLE)) {
            val inner = pixel9()
            val e = engine(inner)
            val config = auto.copy(androidModel = option)
            e.configured(config)
            assertNull(e.checkJob, "no startup check for $option")
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
        }
    }

    @Test
    fun invalidInputCausesNoSelectionWork() = runBlocking {
        // The engine below validates (FirebaseHybridEngine does, before any SDK call); auto adds
        // nothing in front of it: no status lookup, no probe.
        val inner = FakeEngine(onGenerate = { _, _ -> throw HybridError(HybridErrorCode.UNSUPPORTED_INPUT, "bad") })
        val e = engine(inner)
        val error = assertFailsWith<HybridError> { e.generate(auto, request()) }
        assertEquals(HybridErrorCode.UNSUPPORTED_INPUT, error.code)
        assertEquals(1, inner.generateCalls.size)
        assertTrue(inner.probes.isEmpty())
        assertTrue(inner.availabilityCalls.isEmpty())
    }
}

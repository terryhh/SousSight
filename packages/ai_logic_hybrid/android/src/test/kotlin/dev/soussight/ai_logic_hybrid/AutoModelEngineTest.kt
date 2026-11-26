package dev.soussight.ai_logic_hybrid

import com.google.firebase.ai.type.FirebaseAIOnDeviceNotAvailableException
import com.google.firebase.ai.type.PublicPreviewAPI
import com.google.mlkit.genai.common.GenAiException
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.async
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.awaitCancellation
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
        val validator: (GenerateRequest) -> Unit = InputRules::validate,
    ) : HybridEngine {
        override fun validate(request: GenerateRequest) = validator(request)

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

    /** Preview reports available but every generate fails with code 8 (the Pixel 9). */
    private fun pixel9() = FakeEngine(onGenerate = { option, _ ->
        if (option == AndroidModelOption.PREVIEW) throw code8()
        GenerateResult("OK", InferenceSourceWire.ON_DEVICE, FakeEngine.label(option))
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
        verify: Boolean = false,
        statusTimeoutMs: Long = 2_000,
        scope: CoroutineScope = lifetime,
    ) = AutoModelEngine(
        inner,
        scope,
        probeTimeoutMs = probeTimeoutMs,
        statusTimeoutMs = statusTimeoutMs,
        verifyChoice = verify,
        log = { log += it },
    )

    @Test
    fun previewThatAnswersTheProbeIsChosen() = runBlocking {
        val inner = FakeEngine()
        val log = CopyOnWriteArrayList<String>()
        val e = engine(inner, log)

        val a = e.availability(auto, withImage = false)

        assertEquals(OnDeviceStatus.AVAILABLE, a.status)
        assertEquals("nano-v4-full", a.modelLabel)
        assertEquals(AndroidModelOption.PREVIEW, a.modelOption)
        assertEquals(AndroidModelOption.PREVIEW, e.decision)
        val probe = inner.probes.single()
        assertEquals(AndroidModelOption.PREVIEW, probe.option)
        assertEquals(HybridMode.ONLY_ON_DEVICE, probe.request.mode)
        assertEquals(AutoModelEngine.PROBE_MAX_TOKENS, probe.request.maxOutputTokens)
        assertEquals(listOf(HybridPart.Text(AutoModelEngine.PROBE_PROMPT)), probe.request.parts)
        assertTrue(log.any { "source=onDevice" in it && "model=nano-v4-full" in it && "latencyMs=" in it }, "$log")

        val r = e.generate(auto, request())
        assertEquals("nano-v4-full", r.modelLabel)
        assertEquals(AndroidModelOption.PREVIEW, inner.work.single().option)
        assertEquals(1, inner.probes.size, "decision is cached")
    }

    @Test
    fun previewThatFailsTheProbeFallsBackToStable() = runBlocking {
        val inner = pixel9()
        val log = CopyOnWriteArrayList<String>()
        val e = engine(inner, log)

        val a = e.availability(auto, withImage = true)

        assertEquals(OnDeviceStatus.AVAILABLE, a.status)
        assertEquals("nano-v3", a.modelLabel, "availability reports the chosen model")
        assertEquals(AndroidModelOption.STABLE, a.modelOption)
        assertEquals(AndroidModelOption.STABLE, e.decision)
        assertEquals(AndroidModelOption.STABLE, e.modelOption(auto))
        assertTrue(log.any { "cannot answer" in it && "NOT_AVAILABLE" in it }, "$log")
        // The log never carries prompt or answer text.
        assertTrue(log.none { AutoModelEngine.PROBE_PROMPT in it || "dough" in it })

        val r = e.generate(auto, request())
        assertEquals("nano-v3", r.modelLabel)
        assertEquals(InferenceSourceWire.ON_DEVICE, r.source)
        assertEquals(listOf(AndroidModelOption.STABLE), inner.work.map { it.option })
        e.availability(auto, withImage = false)
        assertEquals(1, inner.probes.size, "the preview is probed once per run")
    }

    @Test
    fun previewNotAvailableSkipsTheProbe() = runBlocking {
        for (status in listOf(OnDeviceStatus.UNAVAILABLE, OnDeviceStatus.DOWNLOADABLE, OnDeviceStatus.DOWNLOADING)) {
            val inner = FakeEngine(status = {
                if (it == AndroidModelOption.PREVIEW) AvailabilityResult(status, Reasons.NOT_ENROLLED)
                else AvailabilityResult(OnDeviceStatus.AVAILABLE, modelLabel = "nano-v3")
            })
            val e = engine(inner)
            val a = e.availability(auto, withImage = false)
            assertEquals(AndroidModelOption.STABLE, a.modelOption, "$status")
            assertEquals("nano-v3", a.modelLabel)
            assertTrue(inner.generateCalls.isEmpty(), "no probe when the preview is $status")
        }
    }

    @Test
    fun previewStatusThatThrowsFallsBackToStable() = runBlocking {
        val inner = FakeEngine(status = {
            if (it == AndroidModelOption.PREVIEW) throw IllegalStateException("AICore died")
            AvailabilityResult(OnDeviceStatus.AVAILABLE, modelLabel = "nano-v3")
        })
        val e = engine(inner)
        assertEquals(AndroidModelOption.STABLE, e.availability(auto, false).modelOption)
        assertTrue(inner.generateCalls.isEmpty())
    }

    @Test
    fun stableUnavailableIsReportedHonestly() = runBlocking {
        val inner = FakeEngine(
            status = { AvailabilityResult(OnDeviceStatus.UNAVAILABLE, Reasons.DEVICE_NOT_ELIGIBLE) },
        )
        val a = engine(inner).availability(auto, false)
        assertEquals(OnDeviceStatus.UNAVAILABLE, a.status)
        assertEquals(Reasons.DEVICE_NOT_ELIGIBLE, a.reason)
        assertEquals(AndroidModelOption.STABLE, a.modelOption)
        assertNull(a.modelLabel)
    }

    @Test
    fun aProbeThatHangsTimesOutToStable() = runBlocking {
        // Ignores cancellation, as native work may: the deadline must still hold.
        val inner = FakeEngine(onGenerate = { option, _ ->
            if (option == AndroidModelOption.PREVIEW) withContext(NonCancellable) { delay(3_000) }
            GenerateResult("OK", InferenceSourceWire.ON_DEVICE, FakeEngine.label(option))
        })
        val log = CopyOnWriteArrayList<String>()
        val e = engine(inner, log, probeTimeoutMs = 100)
        val start = System.nanoTime()
        assertEquals(AndroidModelOption.STABLE, e.resolve(auto))
        val ms = (System.nanoTime() - start) / 1_000_000
        assertTrue(ms < 2_000, "resolved in $ms ms")
        assertTrue(log.any { "no answer within 100 ms" in it }, "$log")
    }

    @Test
    fun aProbeAnsweredFromTheCloudIsNotTrusted() = runBlocking {
        val inner = FakeEngine(onGenerate = { option, _ ->
            GenerateResult("OK", InferenceSourceWire.CLOUD, FakeEngine.label(option))
        })
        assertEquals(AndroidModelOption.STABLE, engine(inner).resolve(auto))
    }

    @Test
    fun anyProbeFailureMeansStable() = runBlocking {
        val inner = FakeEngine(onGenerate = { option, _ ->
            if (option == AndroidModelOption.PREVIEW) {
                throw GenAiException("busy", null, GenAiException.ErrorCode.BUSY)
            }
            GenerateResult("OK", InferenceSourceWire.ON_DEVICE, FakeEngine.label(option))
        })
        assertEquals(AndroidModelOption.STABLE, engine(inner).resolve(auto))
    }

    @Test
    fun concurrentCallersShareOneProbe() = runBlocking {
        val release = CompletableDeferred<Unit>()
        val inner = FakeEngine(onGenerate = { option, _ ->
            if (option == AndroidModelOption.PREVIEW) release.await()
            GenerateResult("OK", InferenceSourceWire.ON_DEVICE, FakeEngine.label(option))
        })
        val e = engine(inner)
        val callers = (1..5).map { async(Dispatchers.Default) { e.availability(auto, false) } }
        delay(100)
        release.complete(Unit)
        val answers = callers.map { it.await() }
        assertEquals(1, inner.probes.size)
        assertTrue(answers.all { it.modelOption == AndroidModelOption.PREVIEW })
    }

    @Test
    fun aCancelledCallerDoesNotAbandonTheCheck() = runBlocking {
        val release = CompletableDeferred<Unit>()
        val inner = FakeEngine(onGenerate = { option, _ ->
            if (option == AndroidModelOption.PREVIEW) release.await()
            GenerateResult("OK", InferenceSourceWire.ON_DEVICE, FakeEngine.label(option))
        })
        val e = engine(inner)
        // A generate whose own deadline expires while the check runs.
        assertFailsWith<kotlinx.coroutines.TimeoutCancellationException> {
            withTimeout(50) { e.generate(auto, request()) }
        }
        assertNull(e.decision)
        release.complete(Unit)
        assertEquals(AndroidModelOption.PREVIEW, e.resolve(auto))
        assertEquals(1, inner.probes.size, "the next caller joined the same check")
        assertTrue(inner.work.isEmpty(), "the cancelled request was never sent")
    }

    @Test
    fun midSessionCode8RetriesOnceOnStableOnDevice() = runBlocking {
        val previewWorks = AtomicInteger(1) // the probe succeeds, then the preview breaks
        val inner = FakeEngine(onGenerate = { option, _ ->
            if (option == AndroidModelOption.PREVIEW && previewWorks.getAndDecrement() <= 0) throw code8()
            GenerateResult("OK", InferenceSourceWire.ON_DEVICE, FakeEngine.label(option))
        })
        val log = CopyOnWriteArrayList<String>()
        val e = engine(inner, log)
        assertEquals(AndroidModelOption.PREVIEW, e.resolve(auto))

        val r = e.generate(auto, request())

        assertEquals("nano-v3", r.modelLabel)
        assertEquals(InferenceSourceWire.ON_DEVICE, r.source)
        assertEquals(listOf(AndroidModelOption.PREVIEW, AndroidModelOption.STABLE), inner.work.map { it.option })
        assertTrue(inner.work.all { it.request.mode == HybridMode.ONLY_ON_DEVICE }, "never widened, never cloud")
        assertEquals(AndroidModelOption.STABLE, e.decision)
        assertTrue(log.any { "mid-session" in it })
        // Later calls go straight to stable and availability reports it.
        e.generate(auto, request(id = "r2"))
        assertEquals(AndroidModelOption.STABLE, inner.work.last().option)
        assertEquals(3, inner.work.size)
        assertEquals("nano-v3", e.availability(auto, false).modelLabel)
    }

    @Test
    fun theRetryIsNarrowedToOnDeviceForPreferInCloud() = runBlocking {
        // preferInCloud runs on-device only when offline; the retry may never go to the cloud.
        val previewWorks = AtomicInteger(1)
        val inner = FakeEngine(onGenerate = { option, _ ->
            if (option == AndroidModelOption.PREVIEW && previewWorks.getAndDecrement() <= 0) throw code8()
            GenerateResult("OK", InferenceSourceWire.ON_DEVICE, FakeEngine.label(option))
        })
        val e = engine(inner)
        e.resolve(auto)
        e.generate(auto, request(HybridMode.PREFER_IN_CLOUD))
        assertEquals(
            listOf(HybridMode.PREFER_IN_CLOUD, HybridMode.ONLY_ON_DEVICE),
            inner.work.map { it.request.mode },
        )
    }

    @Test
    fun theRetryHappensOnlyOnce() = runBlocking {
        val previewWorks = AtomicInteger(1)
        val stableError = code8()
        val inner = FakeEngine(onGenerate = { option, _ ->
            if (option == AndroidModelOption.PREVIEW && previewWorks.getAndDecrement() > 0) {
                return@FakeEngine GenerateResult("OK", InferenceSourceWire.ON_DEVICE, "nano-v4-full")
            }
            throw if (option == AndroidModelOption.STABLE) stableError else code8()
        })
        val e = engine(inner)
        e.resolve(auto)
        val thrown = assertFailsWith<FirebaseAIOnDeviceNotAvailableException> { e.generate(auto, request()) }
        assertSame(stableError, thrown)
        assertEquals(2, inner.work.size)
    }

    @Test
    fun otherErrorsAreNotRetried() = runBlocking {
        val previewWorks = AtomicInteger(1)
        val busy = GenAiException("busy", null, GenAiException.ErrorCode.BUSY)
        val inner = FakeEngine(onGenerate = { option, _ ->
            if (previewWorks.getAndDecrement() > 0) {
                return@FakeEngine GenerateResult("OK", InferenceSourceWire.ON_DEVICE, FakeEngine.label(option))
            }
            throw busy
        })
        val e = engine(inner)
        e.resolve(auto)
        assertSame(busy, assertFailsWith<GenAiException> { e.generate(auto, request()) })
        assertEquals(1, inner.work.size)
        assertEquals(AndroidModelOption.PREVIEW, e.decision, "a busy model is not a broken one")
    }

    @Test
    fun onlyInCloudIsNeverRetried() = runBlocking {
        val previewWorks = AtomicInteger(1)
        val inner = FakeEngine(onGenerate = { option, _ ->
            if (previewWorks.getAndDecrement() > 0) {
                return@FakeEngine GenerateResult("OK", InferenceSourceWire.ON_DEVICE, FakeEngine.label(option))
            }
            throw code8()
        })
        val e = engine(inner)
        e.resolve(auto)
        assertFailsWith<FirebaseAIOnDeviceNotAvailableException> {
            e.generate(auto, request(HybridMode.ONLY_IN_CLOUD))
        }
        assertEquals(1, inner.work.size)
        assertEquals(AndroidModelOption.PREVIEW, e.decision)
    }

    @Test
    fun onlyInCloudNeverWaitsForTheLocalCheck() = runBlocking {
        // The probe would hang for its whole deadline; a cloud-only request must not notice.
        val probeStarted = CompletableDeferred<Unit>()
        val inner = FakeEngine(onGenerate = { option, req ->
            if (req.requestId == AutoModelEngine.PROBE_REQUEST_ID) {
                probeStarted.complete(Unit)
                awaitCancellation()
            }
            GenerateResult("cloud", InferenceSourceWire.CLOUD, "gemini-x")
        })
        val e = engine(inner, probeTimeoutMs = 60_000)

        val r = withTimeout(1_000) { e.generate(auto, request(HybridMode.ONLY_IN_CLOUD)) }

        assertEquals(InferenceSourceWire.CLOUD, r.source)
        assertTrue(inner.availabilityCalls.isEmpty(), "no local status check")
        assertTrue(inner.probes.isEmpty(), "no probe")
        assertEquals(listOf(AndroidModelOption.STABLE), inner.work.map { it.option }, "a concrete option")
        assertEquals(HybridMode.ONLY_IN_CLOUD, inner.work.single().request.mode)
        assertNull(e.decision, "a cloud call decides nothing about the local model")
        assertFalse(probeStarted.isCompleted)
    }

    @Test
    fun onlyInCloudAfterADecisionUsesIt() = runBlocking {
        val inner = FakeEngine()
        val decided = engine(inner)
        decided.resolve(auto)
        decided.generate(auto, request(HybridMode.ONLY_IN_CLOUD))
        assertEquals(AndroidModelOption.PREVIEW, inner.work.single().option)
        assertEquals(1, inner.probes.size)
    }

    @Test
    fun aLateCodeEightAfterCancellationStartsNoStableRetry() = runBlocking {
        val previewStarted = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val inner = FakeEngine(onGenerate = { option, req ->
            if (req.requestId != AutoModelEngine.PROBE_REQUEST_ID && option == AndroidModelOption.PREVIEW) {
                previewStarted.complete(Unit)
                // Native work that ignores cancellation, then fails late with code 8.
                withContext(NonCancellable) { release.await() }
                throw code8()
            }
            GenerateResult("OK", InferenceSourceWire.ON_DEVICE, FakeEngine.label(option))
        })
        val e = engine(inner)
        assertEquals(AndroidModelOption.PREVIEW, e.resolve(auto))

        val call = async(Dispatchers.Default) { e.generate(auto, request()) }
        previewStarted.await()
        call.cancel()
        release.complete(Unit)

        call.join() // waits until the late failure has been handled
        assertTrue(call.isCancelled)
        assertFailsWith<kotlinx.coroutines.CancellationException> { call.await() }
        assertEquals(listOf(AndroidModelOption.PREVIEW), inner.work.map { it.option }, "no STABLE generation")
    }

    @Test
    fun aCodeEightOnStableIsNotRetried() = runBlocking {
        // The probe fails (so stable is chosen) and stable then fails the same way.
        val inner = FakeEngine(onGenerate = { _, _ -> throw code8() })
        val e = engine(inner)
        assertFailsWith<FirebaseAIOnDeviceNotAvailableException> { e.generate(auto, request()) }
        assertEquals(listOf(AndroidModelOption.STABLE), inner.work.map { it.option })
    }

    @Test
    fun cancellationIsNotRetried() = runBlocking {
        val started = CompletableDeferred<Unit>()
        val inner = FakeEngine(onGenerate = { option, req ->
            if (req.requestId != AutoModelEngine.PROBE_REQUEST_ID) {
                started.complete(Unit)
                awaitCancellation()
            }
            GenerateResult("OK", InferenceSourceWire.ON_DEVICE, FakeEngine.label(option))
        })
        val e = engine(inner)
        val call = async(start = CoroutineStart.UNDISPATCHED) { e.generate(auto, request()) }
        started.await()
        call.cancel()
        assertFailsWith<kotlinx.coroutines.CancellationException> { call.await() }
        assertEquals(1, inner.work.size)
    }

    @Test
    fun explicitOptionsPassThroughWithoutProbeOrRetry() = runBlocking {
        for (option in listOf(AndroidModelOption.PREVIEW, AndroidModelOption.PREVIEW_FAST, AndroidModelOption.STABLE)) {
            val inner = pixel9()
            val e = engine(inner)
            val config = auto.copy(androidModel = option)
            val a = e.availability(config, false)
            assertEquals(option, a.modelOption)
            assertEquals(option, e.modelOption(config))
            assertEquals(listOf(1.0 / 2, 1.0), e.prepare(config, false).toList())
            assertEquals(listOf(option), inner.prepareCalls)
            if (option == AndroidModelOption.PREVIEW) {
                assertFailsWith<FirebaseAIOnDeviceNotAvailableException> { e.generate(config, request()) }
            } else {
                e.generate(config, request())
            }
            assertEquals(listOf(option), inner.generateCalls.map { it.option }, "$option: no probe, no retry")
            assertNull(e.decision)
        }
    }

    @Test
    fun prepareDownloadsTheChosenModel() = runBlocking {
        val inner = pixel9()
        val log = CopyOnWriteArrayList<String>()
        val e = engine(inner, log)
        assertNull(e.modelOption(auto), "not chosen until checked")
        assertEquals(listOf(0.5, 1.0), e.prepare(auto, withImage = true).toList())
        assertEquals(listOf(AndroidModelOption.STABLE), inner.prepareCalls)
        assertTrue(log.any { "preparing stable" in it })
    }

    @Test
    fun debugBuildsAlsoProbeTheStableChoice() = runBlocking {
        val inner = pixel9()
        val log = CopyOnWriteArrayList<String>()
        val e = engine(inner, log, verify = true)
        assertEquals(AndroidModelOption.STABLE, e.resolve(auto))
        assertEquals(listOf(AndroidModelOption.PREVIEW, AndroidModelOption.STABLE), inner.probes.map { it.option })
        assertTrue(log.any { "option=stable source=onDevice model=nano-v3" in it }, "$log")
    }

    @Test
    fun aFailingDebugProbeIsLoggedButDoesNotChangeTheChoice() = runBlocking {
        val inner = FakeEngine(
            status = {
                if (it == AndroidModelOption.PREVIEW) AvailabilityResult(OnDeviceStatus.UNAVAILABLE)
                else AvailabilityResult(OnDeviceStatus.AVAILABLE)
            },
            onGenerate = { _, _ -> throw code8() },
        )
        val log = CopyOnWriteArrayList<String>()
        assertEquals(AndroidModelOption.STABLE, engine(inner, log, verify = true).resolve(auto))
        assertTrue(log.any { "stable did not answer the debug probe" in it }, "$log")
    }

    // --- Codex review of f420fcd ---

    @Test
    fun aHungStatusLookupSelectsStableAndItsLateAnswerIsDiscarded() = runBlocking {
        val release = CompletableDeferred<Unit>()
        val first = AtomicInteger(0)
        val inner = FakeEngine(status = {
            // Only the first preview lookup hangs (ignoring cancellation), then says available.
            if (it == AndroidModelOption.PREVIEW && first.getAndIncrement() == 0) {
                runBlocking { withContext(NonCancellable) { release.await() } }
            }
            AvailabilityResult(OnDeviceStatus.AVAILABLE, modelLabel = FakeEngine.label(it))
        })
        val log = CopyOnWriteArrayList<String>()
        val e = engine(inner, log, statusTimeoutMs = 100)
        val start = System.nanoTime()

        val a = withTimeout(2_000) { e.availability(auto, false) }

        assertTrue((System.nanoTime() - start) / 1_000_000 < 2_000)
        assertEquals(AndroidModelOption.STABLE, a.modelOption)
        assertEquals("nano-v3", a.modelLabel)
        assertTrue(log.any { "no answer within 100 ms" in it }, "$log")
        release.complete(Unit)
        delay(100)
        assertEquals(AndroidModelOption.STABLE, e.decision, "the late preview answer is discarded")
        assertTrue(inner.probes.isEmpty(), "no probe after the deadline")
        e.generate(auto, request())
        assertEquals(listOf(AndroidModelOption.STABLE), inner.work.map { it.option })
    }

    @Test
    fun previewThatBecomesUnavailableGivesWayToStable() = runBlocking {
        val previewStatus = AtomicReference(OnDeviceStatus.AVAILABLE)
        val inner = FakeEngine(status = {
            if (it == AndroidModelOption.PREVIEW) AvailabilityResult(previewStatus.get(), Reasons.MODEL_NOT_READY, "nano-v4-full")
            else AvailabilityResult(OnDeviceStatus.AVAILABLE, modelLabel = "nano-v3")
        })
        val e = engine(inner)
        assertEquals(AndroidModelOption.PREVIEW, e.availability(auto, false).modelOption)

        previewStatus.set(OnDeviceStatus.UNAVAILABLE)
        val a = e.availability(auto, false)

        assertEquals(OnDeviceStatus.AVAILABLE, a.status)
        assertEquals(AndroidModelOption.STABLE, a.modelOption)
        assertEquals("nano-v3", a.modelLabel)
        assertEquals(AndroidModelOption.STABLE, e.decision)
        assertEquals(AndroidModelOption.STABLE, e.modelOption(auto))
        e.generate(auto, request())
        assertEquals(AndroidModelOption.STABLE, inner.work.last().option)
    }

    @Test
    fun previewUnavailableWithStableUnavailableIsReportedAsIs() = runBlocking {
        val previewStatus = AtomicReference(OnDeviceStatus.AVAILABLE)
        val inner = FakeEngine(status = {
            if (it == AndroidModelOption.PREVIEW) AvailabilityResult(previewStatus.get(), Reasons.NOT_ENROLLED)
            else AvailabilityResult(OnDeviceStatus.DOWNLOADABLE, Reasons.MODEL_NOT_READY)
        })
        val e = engine(inner)
        e.resolve(auto)
        previewStatus.set(OnDeviceStatus.UNAVAILABLE)
        val a = e.availability(auto, false)
        assertEquals(OnDeviceStatus.UNAVAILABLE, a.status)
        assertEquals(Reasons.NOT_ENROLLED, a.reason)
        assertEquals(AndroidModelOption.PREVIEW, a.modelOption)
        assertEquals(AndroidModelOption.PREVIEW, e.decision, "stable is not ready, so no switch")
    }

    @Test
    fun availabilityReportsADowngradeThatLandsDuringItsAwait() = runBlocking {
        val hold = CompletableDeferred<Unit>()
        val holding = CompletableDeferred<Unit>()
        val decided = AtomicBoolean(false)
        val previewWorks = AtomicInteger(1)
        val inner = FakeEngine(
            status = {
                if (it == AndroidModelOption.PREVIEW && decided.get()) {
                    holding.complete(Unit)
                    runBlocking { hold.await() }
                }
                AvailabilityResult(OnDeviceStatus.AVAILABLE, modelLabel = FakeEngine.label(it))
            },
            onGenerate = { option, _ ->
                if (option == AndroidModelOption.PREVIEW && previewWorks.getAndDecrement() <= 0) throw code8()
                GenerateResult("OK", InferenceSourceWire.ON_DEVICE, FakeEngine.label(option))
            },
        )
        val e = engine(inner)
        assertEquals(AndroidModelOption.PREVIEW, e.resolve(auto))
        decided.set(true)

        val inFlight = async(Dispatchers.Default) { e.availability(auto, false) }
        holding.await()
        e.generate(auto, request()) // code 8 on preview: downgrade to stable
        assertEquals(AndroidModelOption.STABLE, e.decision)
        hold.complete(Unit)
        val a = inFlight.await()

        assertEquals(AndroidModelOption.STABLE, a.modelOption, "never the superseded preview")
        assertEquals("nano-v3", a.modelLabel)
        assertEquals(e.modelOption(auto), a.modelOption, "availability and capabilities agree")
    }

    @Test
    fun cancellingTheEngineLifetimeStopsTheCheck() = runBlocking {
        val release = CompletableDeferred<Unit>()
        val lookup = CompletableDeferred<Unit>()
        val inner = FakeEngine(status = {
            if (it == AndroidModelOption.PREVIEW) {
                lookup.complete(Unit)
                runBlocking { withContext(NonCancellable) { release.await() } }
            }
            AvailabilityResult(OnDeviceStatus.AVAILABLE, modelLabel = FakeEngine.label(it))
        })
        val owner = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val e = engine(inner, scope = owner)
        val caller = async(Dispatchers.Default) { runCatching { e.resolve(auto) } }
        lookup.await()

        owner.cancel() // the plugin detaches
        release.complete(Unit)
        val outcome = caller.await()

        assertTrue(outcome.exceptionOrNull() is kotlinx.coroutines.CancellationException, "$outcome")
        delay(200)
        assertTrue(inner.generateCalls.isEmpty(), "no native generation after teardown")
        assertNull(e.decision)
    }

    @Test
    fun aColdInvalidRequestMakesNoBackendCall() = runBlocking {
        val inner = FakeEngine()
        val e = engine(inner)
        val photo = HybridPart.InlineData(ByteArray(16), "image/jpeg")
        for (mode in HybridMode.entries) {
            val twoPhotos = request(mode).copy(parts = listOf(HybridPart.Text("which?"), photo, photo))
            val error = assertFailsWith<HybridError> { e.generate(auto, twoPhotos) }
            assertEquals(HybridErrorCode.UNSUPPORTED_INPUT, error.code, "$mode")
        }
        val audio = request().copy(parts = listOf(HybridPart.InlineData(ByteArray(4), "audio/wav")))
        assertEquals(HybridErrorCode.UNSUPPORTED_INPUT, assertFailsWith<HybridError> { e.generate(auto, audio) }.code)
        assertTrue(inner.availabilityCalls.isEmpty())
        assertTrue(inner.generateCalls.isEmpty())
        assertNull(e.decision)
    }

    @Test
    fun aBlankOnDeviceProbeAnswerDoesNotSelectPreview() = runBlocking {
        for (text in listOf("", "  \n")) {
            val inner = FakeEngine(onGenerate = { option, _ ->
                val answer = if (option == AndroidModelOption.PREVIEW) text else "OK"
                GenerateResult(answer, InferenceSourceWire.ON_DEVICE, FakeEngine.label(option))
            })
            val log = CopyOnWriteArrayList<String>()
            assertEquals(AndroidModelOption.STABLE, engine(inner, log).resolve(auto), "'$text'")
            assertTrue(log.any { "blank answer" in it }, "$log")
        }
    }

    // --- Codex review of 56811ee ---

    /** preferOnDevice on a preview that fails locally: the SDK answers from the cloud. */
    private fun swallowingSdk(previewProbeWorks: AtomicBoolean) = FakeEngine(onGenerate = { option, req ->
        when {
            req.requestId == AutoModelEngine.PROBE_REQUEST_ID && option == AndroidModelOption.PREVIEW ->
                if (previewProbeWorks.get()) GenerateResult("OK", InferenceSourceWire.ON_DEVICE, "nano-v4-full")
                else throw code8()
            option == AndroidModelOption.PREVIEW && req.mode == HybridMode.PREFER_ON_DEVICE ->
                GenerateResult("cloud answer", InferenceSourceWire.CLOUD, "gemini-x")
            else -> GenerateResult("local answer", InferenceSourceWire.ON_DEVICE, FakeEngine.label(option))
        }
    })

    @Test
    fun aPreferOnDeviceCloudAnswerOnABrokenPreviewMovesLaterRequestsToStable() = runBlocking {
        val probeWorks = AtomicBoolean(true)
        val inner = swallowingSdk(probeWorks)
        val log = CopyOnWriteArrayList<String>()
        val e = engine(inner, log)
        assertEquals(AndroidModelOption.PREVIEW, e.resolve(auto))
        probeWorks.set(false) // preview breaks after startup

        val first = e.generate(auto, request(HybridMode.PREFER_ON_DEVICE))
        assertEquals(InferenceSourceWire.CLOUD, first.source, "the completed answer keeps its cloud provenance")
        assertEquals("gemini-x", first.modelLabel)
        withTimeout(2_000) { assertNotNull(e.recheckJob).join() }

        assertEquals(AndroidModelOption.STABLE, e.decision)
        assertTrue(log.any { "fell back to the cloud" in it }, "$log")
        val next = e.generate(auto, request(HybridMode.PREFER_ON_DEVICE, id = "r2"))
        assertEquals(InferenceSourceWire.ON_DEVICE, next.source)
        assertEquals("nano-v3", next.modelLabel)
        // The recheck sent only the fixed probe prompt.
        assertTrue(inner.probes.all { it.request.parts == listOf(HybridPart.Text(AutoModelEngine.PROBE_PROMPT)) })
        assertTrue(inner.probes.all { it.request.mode == HybridMode.ONLY_ON_DEVICE })
    }

    @Test
    fun aCloudAnswerWhilePreviewStillAnswersKeepsPreview() = runBlocking {
        val inner = swallowingSdk(AtomicBoolean(true))
        val e = engine(inner)
        e.resolve(auto)
        e.generate(auto, request(HybridMode.PREFER_ON_DEVICE))
        withTimeout(2_000) { assertNotNull(e.recheckJob).join() }
        assertEquals(AndroidModelOption.PREVIEW, e.decision)
        assertEquals(2, inner.probes.size)
    }

    @Test
    fun aBrokenPreviewWithoutAReadyStableIsKept() = runBlocking {
        val probeWorks = AtomicBoolean(true)
        val stableReady = AtomicBoolean(true)
        val inner = FakeEngine(
            status = {
                if (it == AndroidModelOption.STABLE && !stableReady.get()) AvailabilityResult(OnDeviceStatus.DOWNLOADABLE)
                else AvailabilityResult(OnDeviceStatus.AVAILABLE, modelLabel = FakeEngine.label(it))
            },
            onGenerate = swallowingSdk(probeWorks).onGenerate,
        )
        val e = engine(inner)
        e.resolve(auto)
        probeWorks.set(false)
        stableReady.set(false)
        e.generate(auto, request(HybridMode.PREFER_ON_DEVICE))
        withTimeout(2_000) { assertNotNull(e.recheckJob).join() }
        assertEquals(AndroidModelOption.PREVIEW, e.decision, "no switch to a model that is not ready")
    }

    @Test
    fun noRecheckForCloudAnswersThatAreExpected() = runBlocking {
        val inner = FakeEngine(onGenerate = { option, req ->
            if (req.requestId == AutoModelEngine.PROBE_REQUEST_ID) GenerateResult("OK", InferenceSourceWire.ON_DEVICE, "x")
            else GenerateResult("cloud", InferenceSourceWire.CLOUD, "gemini-x")
        })
        val e = engine(inner)
        e.resolve(auto)
        e.generate(auto, request(HybridMode.PREFER_IN_CLOUD))
        e.generate(auto, request(HybridMode.ONLY_IN_CLOUD))
        assertNull(e.recheckJob)
        assertEquals(1, inner.probes.size)
    }

    @Test
    fun aDownloadablePreviewIsNotHiddenWhenStableIsUnavailable() = runBlocking {
        val preview = AtomicReference(OnDeviceStatus.DOWNLOADABLE)
        val inner = FakeEngine(status = {
            if (it == AndroidModelOption.PREVIEW) AvailabilityResult(preview.get(), Reasons.MODEL_NOT_READY, "nano-v4-full")
            else AvailabilityResult(OnDeviceStatus.UNAVAILABLE, Reasons.DEVICE_NOT_ELIGIBLE)
        })
        val e = engine(inner)

        val a = e.availability(auto, false)
        assertEquals(OnDeviceStatus.DOWNLOADABLE, a.status, "setup stays visible")
        assertEquals(AndroidModelOption.PREVIEW, a.modelOption)
        assertNull(e.decision, "provisional, not cached")
        assertEquals(listOf(0.5, 1.0), e.prepare(auto, false).toList())
        assertEquals(listOf(AndroidModelOption.PREVIEW), inner.prepareCalls, "prepare downloads the obtainable model")
        assertTrue(inner.probes.isEmpty())

        preview.set(OnDeviceStatus.AVAILABLE) // downloaded
        val ready = e.availability(auto, false)
        assertEquals(AndroidModelOption.PREVIEW, ready.modelOption)
        assertEquals(1, inner.probes.size, "the downloaded preview is probed before it is selected")
        assertEquals(AndroidModelOption.PREVIEW, e.decision)
    }

    @Test
    fun aDownloadedPreviewThatFailsTheProbeIsNotSelected() = runBlocking {
        val preview = AtomicReference(OnDeviceStatus.DOWNLOADING)
        val inner = FakeEngine(
            status = {
                if (it == AndroidModelOption.PREVIEW) AvailabilityResult(preview.get())
                else AvailabilityResult(OnDeviceStatus.UNAVAILABLE, Reasons.DEVICE_NOT_ELIGIBLE)
            },
            onGenerate = { _, _ -> throw code8() },
        )
        val e = engine(inner)
        assertEquals(OnDeviceStatus.DOWNLOADING, e.availability(auto, false).status)
        preview.set(OnDeviceStatus.AVAILABLE)
        val a = e.availability(auto, false)
        assertEquals(AndroidModelOption.STABLE, e.decision)
        assertEquals(OnDeviceStatus.UNAVAILABLE, a.status, "honest: the only obtainable model cannot answer")
    }

    @Test
    fun aDownloadableStableIsPreferredWhilePreviewIsNotReady() = runBlocking {
        val stable = AtomicReference(OnDeviceStatus.DOWNLOADABLE)
        val inner = FakeEngine(status = {
            if (it == AndroidModelOption.PREVIEW) AvailabilityResult(OnDeviceStatus.DOWNLOADABLE)
            else AvailabilityResult(stable.get(), modelLabel = "nano-v3".takeIf { _ -> stable.get() == OnDeviceStatus.AVAILABLE })
        })
        val e = engine(inner)
        val a = e.availability(auto, false)
        assertEquals(OnDeviceStatus.DOWNLOADABLE, a.status)
        assertEquals(AndroidModelOption.STABLE, a.modelOption)
        assertNull(e.decision)
        stable.set(OnDeviceStatus.AVAILABLE)
        assertEquals("nano-v3", e.availability(auto, false).modelLabel)
        assertEquals(AndroidModelOption.STABLE, e.decision)
        assertTrue(inner.probes.isEmpty())
    }

    @Test
    fun aSelectedPreviewThatIsNoLongerReadyGivesWayToAReadyStable() = runBlocking {
        val preview = AtomicReference(OnDeviceStatus.AVAILABLE)
        val inner = FakeEngine(status = {
            if (it == AndroidModelOption.PREVIEW) AvailabilityResult(preview.get(), modelLabel = "nano-v4-full")
            else AvailabilityResult(OnDeviceStatus.AVAILABLE, modelLabel = "nano-v3")
        })
        val e = engine(inner)
        assertEquals(AndroidModelOption.PREVIEW, e.resolve(auto))
        preview.set(OnDeviceStatus.DOWNLOADABLE) // e.g. a model update
        val a = e.availability(auto, false)
        assertEquals(OnDeviceStatus.AVAILABLE, a.status)
        assertEquals(AndroidModelOption.STABLE, a.modelOption)
        assertEquals(AndroidModelOption.STABLE, e.decision)
    }

    @Test
    fun undecodableOrOversizedImagesFailBeforeAnyBackendCall() = runBlocking {
        val sizes = mapOf<Byte, Pair<Int, Int>?>(1.toByte() to (769 to 1), 2.toByte() to null, 3.toByte() to (768 to 768))
        val codec = object : ImageCodec {
            override fun bounds(bytes: ByteArray) = sizes[bytes[0]]
            override fun decode(bytes: ByteArray) = null
        }
        // The production validation path, with no SDK behind it.
        val firebase = FirebaseHybridEngine(codec) { error("no SDK in tests") }
        val inner = FakeEngine(validator = firebase::validate)
        val e = engine(inner)
        fun photo(tag: Byte, mode: HybridMode) = request(mode).copy(
            parts = listOf(HybridPart.Text("what is this?"), HybridPart.InlineData(byteArrayOf(tag), "image/jpeg")),
        )
        for (mode in HybridMode.entries) {
            for (tag in listOf<Byte>(1, 2)) {
                val error = assertFailsWith<HybridError> { e.generate(auto, photo(tag, mode)) }
                assertEquals(HybridErrorCode.UNSUPPORTED_INPUT, error.code, "$mode tag $tag")
            }
        }
        assertTrue(inner.availabilityCalls.isEmpty())
        assertTrue(inner.generateCalls.isEmpty(), "no startup probe for invalid input")
        assertFailsWith<HybridError> { e.validate(photo(1, HybridMode.ONLY_ON_DEVICE)) } // delegates
        // A valid image passes validation and reaches the backend.
        e.generate(auto, photo(3, HybridMode.ONLY_ON_DEVICE))
        assertEquals(1, inner.work.size)
    }

    @Test
    fun theStatusDeadlineHoldsWhenTheCallerIsOnASingleBlockedThread() = runBlocking {
        val main = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        try {
            val inner = FakeEngine(status = {
                // A synchronous native stall, as on the main thread.
                if (it == AndroidModelOption.PREVIEW) Thread.sleep(1_000)
                AvailabilityResult(OnDeviceStatus.AVAILABLE, modelLabel = FakeEngine.label(it))
            })
            val plugin = CoroutineScope(SupervisorJob() + main)
            // Production default for `work` (Dispatchers.IO); the plugin's scope is single-threaded.
            val e = AutoModelEngine(inner, plugin, statusTimeoutMs = 20)
            val start = System.nanoTime()
            val option = withContext(main) { e.resolve(auto) }
            val ms = (System.nanoTime() - start) / 1_000_000
            assertEquals(AndroidModelOption.STABLE, option)
            assertTrue(ms < 500, "selected in $ms ms despite a 1 s stall")
            plugin.cancel()
        } finally {
            main.close()
        }
    }
}

package dev.soussight.ai_logic_hybrid

import com.google.firebase.ai.type.FirebaseAIOnDeviceNotAvailableException
import com.google.firebase.ai.type.PublicPreviewAPI
import com.google.mlkit.genai.common.GenAiException
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.async
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

    private fun engine(inner: HybridEngine, log: MutableList<String> = mutableListOf(), probeTimeoutMs: Long = 2_000, verify: Boolean = false) =
        AutoModelEngine(inner, probeTimeoutMs = probeTimeoutMs, verifyChoice = verify, log = { log += it })

    @Test
    fun previewThatAnswersTheProbeIsChosen() = runBlocking {
        val inner = FakeEngine()
        val log = mutableListOf<String>()
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
        val log = mutableListOf<String>()
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
        val log = mutableListOf<String>()
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
        val log = mutableListOf<String>()
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
        val log = mutableListOf<String>()
        val e = engine(inner, log)
        assertNull(e.modelOption(auto), "not chosen until checked")
        assertEquals(listOf(0.5, 1.0), e.prepare(auto, withImage = true).toList())
        assertEquals(listOf(AndroidModelOption.STABLE), inner.prepareCalls)
        assertTrue(log.any { "preparing stable" in it })
    }

    @Test
    fun debugBuildsAlsoProbeTheStableChoice() = runBlocking {
        val inner = pixel9()
        val log = mutableListOf<String>()
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
        val log = mutableListOf<String>()
        assertEquals(AndroidModelOption.STABLE, engine(inner, log, verify = true).resolve(auto))
        assertTrue(log.any { "stable did not answer the debug probe" in it }, "$log")
    }
}

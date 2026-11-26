package dev.soussight.ai_logic_hybrid

import java.util.concurrent.CopyOnWriteArrayList
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout

internal class CoordinatorTest {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val config = HybridConfig("cloud-model", AndroidModelOption.PREVIEW, listOf("en"))

    @AfterTest
    fun tearDown() = scope.cancel()

    /** Records every reply; fails the test if a call is answered twice. */
    private class RecordingReply : Reply {
        val replies = CopyOnWriteArrayList<Pair<String, Any?>>()
        val first = CompletableDeferred<Pair<String, Any?>>()

        override fun success(value: Any?) = record("success" to value)
        override fun error(code: String, message: String?) = record(code to message)

        private fun record(r: Pair<String, Any?>) {
            replies += r
            first.complete(r)
        }

        fun await(): Pair<String, Any?> = runBlocking { withTimeout(5_000) { first.await() } }
    }

    private class FakeEngine(
        val onGenerate: suspend (HybridConfig, GenerateRequest) -> GenerateResult = { _, _ ->
            GenerateResult("hello", InferenceSourceWire.ON_DEVICE, "nano-test")
        },
        val onPrepare: () -> Flow<Double?> = { flow { emit(1.0) } },
    ) : HybridEngine {
        val seenConfigs = CopyOnWriteArrayList<HybridConfig>()
        var prepareCalls = 0
        val cancelled = CompletableDeferred<Unit>()

        override suspend fun availability(config: HybridConfig, withImage: Boolean) =
            AvailabilityResult(OnDeviceStatus.AVAILABLE)

        override fun prepare(config: HybridConfig, withImage: Boolean): Flow<Double?> {
            prepareCalls++
            return onPrepare()
        }

        override suspend fun generate(config: HybridConfig, request: GenerateRequest): GenerateResult {
            seenConfigs += config
            try {
                return onGenerate(config, request)
            } catch (e: kotlinx.coroutines.CancellationException) {
                cancelled.complete(Unit)
                throw e
            }
        }
    }

    private fun args(id: String = "r1", mode: String = "onlyOnDevice", timeoutMs: Int = 2_000) = mapOf(
        "requestId" to id,
        "mode" to mode,
        "feature" to "f",
        "parts" to listOf(mapOf("type" to "text", "text" to "hi")),
        "maxOutputTokens" to 64,
        "timeoutMs" to timeoutMs,
    )

    @Test
    fun successReturnsTheResultMap() {
        val c = GenerateCoordinator(scope, FakeEngine(), { config })
        val reply = RecordingReply()
        c.start(args(), reply)
        assertEquals(
            "success" to mapOf("requestId" to "r1", "text" to "hello", "source" to "onDevice", "modelLabel" to "nano-test"),
            reply.await(),
        )
    }

    @Test
    fun notConfiguredIsUnavailable() {
        val c = GenerateCoordinator(scope, FakeEngine(), { null })
        val reply = RecordingReply()
        c.start(args(), reply)
        assertEquals("unavailable" to Reasons.NOT_CONFIGURED, reply.await())
    }

    @Test
    fun badArgumentsAnswerWithoutCallingTheEngine() {
        val engine = FakeEngine()
        val c = GenerateCoordinator(scope, engine, { config })
        val reply = RecordingReply()
        c.start(args(mode = "auto"), reply)
        assertEquals("unsupportedMode", reply.await().first)
        assertTrue(engine.seenConfigs.isEmpty())
    }

    @Test
    fun onlyOnDeviceNeverReturnsACloudResult() {
        val engine = FakeEngine(onGenerate = { _, _ -> GenerateResult("x", InferenceSourceWire.CLOUD, null) })
        val c = GenerateCoordinator(scope, engine, { config })
        val reply = RecordingReply()
        c.start(args(mode = "onlyOnDevice"), reply)
        assertEquals("failed", reply.await().first)
        // The same result is fine for a mode that allows the cloud.
        val ok = RecordingReply()
        c.start(args(id = "r2", mode = "preferOnDevice"), ok)
        assertEquals("success", ok.await().first)
    }

    @Test
    fun timeoutAnswersTimeoutAndCancelsTheWork() {
        val engine = FakeEngine(onGenerate = { _, _ -> awaitCancellation() })
        val c = GenerateCoordinator(scope, engine, { config })
        val reply = RecordingReply()
        c.start(args(timeoutMs = 50), reply)
        assertEquals("timeout", reply.await().first)
        runBlocking { withTimeout(2_000) { engine.cancelled.await() } }
        assertEquals(0, c.pendingCount)
    }

    @Test
    fun timeoutIsAnsweredAtTheDeadlineWhenTheSdkIgnoresCancellation() {
        // Native work that does not honour coroutine cancellation: withTimeout cannot complete
        // until it unwinds 1.5 s later. The caller must still hear `timeout` at timeoutMs.
        val finished = CompletableDeferred<Unit>()
        val engine = FakeEngine(onGenerate = { _, _ ->
            withContext(NonCancellable) { delay(1_500) }
            finished.complete(Unit)
            GenerateResult("late", InferenceSourceWire.ON_DEVICE, null)
        })
        val c = GenerateCoordinator(scope, engine, { config })
        val reply = RecordingReply()
        val started = System.nanoTime()
        c.start(args(timeoutMs = 50), reply)
        assertEquals("timeout" to "Timed out after 50 ms", reply.await())
        val elapsedMs = (System.nanoTime() - started) / 1_000_000
        assertTrue(elapsedMs >= 50, "not before the deadline ($elapsedMs ms)")
        // Previously the reply waited for timeoutMs + 500 ms of grace (about 555 ms).
        assertTrue(elapsedMs < 400, "answered at the deadline, not after the grace ($elapsedMs ms)")
        assertFalse(finished.isCompleted, "native work was still running when the caller was told")
        assertEquals(0, c.pendingCount, "the request id is free again")
        runBlocking { withTimeout(5_000) { finished.await() }; delay(100) }
        assertEquals(1, reply.replies.size, "late result discarded")
    }

    @Test
    fun aFastResultCancelsTheDeadline() {
        val c = GenerateCoordinator(scope, FakeEngine(), { config })
        val reply = RecordingReply()
        c.start(args(timeoutMs = 100), reply)
        assertEquals("success", reply.await().first)
        runBlocking { delay(250) }
        assertEquals(1, reply.replies.size, "no timeout after a success")
    }

    @Test
    fun cancelAnswersCancelledOnceAndDropsTheLateResult() {
        val release = CompletableDeferred<Unit>()
        val engine = FakeEngine(onGenerate = { _, _ ->
            withContext(NonCancellable) { release.await() }
            GenerateResult("late", InferenceSourceWire.ON_DEVICE, null)
        })
        val c = GenerateCoordinator(scope, engine, { config })
        val reply = RecordingReply()
        c.start(args(), reply)
        runBlocking { delay(50) }
        c.cancel("r1")
        assertEquals("cancelled" to "Cancelled", reply.await())
        release.complete(Unit)
        runBlocking { delay(200) }
        assertEquals(1, reply.replies.size)
        c.cancel("r1") // unknown or finished ids are a no-op
        c.cancel(null)
    }

    @Test
    fun duplicateRequestIdIsRejected() {
        val engine = FakeEngine(onGenerate = { _, _ -> awaitCancellation() })
        val c = GenerateCoordinator(scope, engine, { config })
        val first = RecordingReply()
        c.start(args(), first)
        val second = RecordingReply()
        c.start(args(), second)
        assertEquals("failed", second.await().first)
        assertFalse(first.first.isCompleted)
        c.cancel("r1")
        assertEquals("cancelled", first.await().first)
    }

    @Test
    fun configIsSnapshottedWhenTheCallStarts() {
        var current: HybridConfig? = config
        val gate = CompletableDeferred<Unit>()
        val engine = FakeEngine(onGenerate = { cfg, _ ->
            gate.await()
            GenerateResult(cfg.cloudModel, InferenceSourceWire.ON_DEVICE, null)
        })
        val c = GenerateCoordinator(scope, engine, { current })
        val reply = RecordingReply()
        c.start(args(), reply)
        current = config.copy(cloudModel = "other")
        gate.complete(Unit)
        assertEquals("cloud-model", (reply.await().second as Map<*, *>)["text"])
    }

    @Test
    fun engineErrorsAreMapped() {
        val engine = FakeEngine(onGenerate = { _, _ ->
            throw RuntimeException(com.google.mlkit.genai.common.GenAiException("busy", null, 9))
        })
        val c = GenerateCoordinator(scope, engine, { config })
        val reply = RecordingReply()
        c.start(args(), reply)
        assertEquals("busy", reply.await().first)
    }

    private class RecordingSink : PrepareSink {
        val events = CopyOnWriteArrayList<Any?>()
        val done = CompletableDeferred<Unit>()
        override fun success(event: Any?) { events += event }
        override fun error(code: String, message: String?) { events += "error:$code"; done.complete(Unit) }
        override fun endOfStream() { events += "end"; done.complete(Unit) }
        fun await() = runBlocking { withTimeout(5_000) { done.await() } }
    }

    @Test
    fun prepareStreamsFractionsThenEnds() {
        val engine = FakeEngine(onPrepare = { flow { emit(0.0); emit(null); emit(1.0) } })
        val p = PrepareCoordinator(scope, engine, { config })
        val sink = RecordingSink()
        p.onListen(mapOf("withImage" to false), sink)
        sink.await()
        assertEquals(
            listOf(mapOf("fraction" to 0.0), mapOf("fraction" to null), mapOf("fraction" to 1.0), "end"),
            sink.events.toList(),
        )
    }

    @Test
    fun prepareErrorsCarryTheCode() {
        val engine = FakeEngine(onPrepare = {
            flow { throw HybridError(HybridErrorCode.UNAVAILABLE, Reasons.NOT_ENROLLED) }
        })
        val sink = RecordingSink()
        PrepareCoordinator(scope, engine, { config }).onListen(null, sink)
        sink.await()
        assertEquals(listOf<Any?>("error:unavailable"), sink.events.toList())
        val notConfigured = RecordingSink()
        PrepareCoordinator(scope, engine, { null }).onListen(null, notConfigured)
        notConfigured.await()
        assertEquals(listOf<Any?>("error:unavailable"), notConfigured.events.toList())
    }

    @Test
    fun aListenerForAnotherModelOptionIsNotJoinedToTheRunningDownload() {
        var current: HybridConfig? = config
        val gate = CompletableDeferred<Unit>()
        val engine = FakeEngine(onPrepare = { flow { gate.await(); emit(1.0) } })
        val p = PrepareCoordinator(scope, engine, { current })
        val first = RecordingSink()
        p.onListen(null, first)
        current = config.copy(androidModel = AndroidModelOption.STABLE)
        val second = RecordingSink()
        p.onListen(null, second)
        second.await()
        assertEquals(listOf<Any?>("error:busy"), second.events.toList())
        gate.complete(Unit)
        first.await()
        assertEquals("end", first.events.last())
        assertEquals(1, engine.prepareCalls)
    }

    @Test
    fun availabilityAnswersForTheCurrentConfig() = runBlocking {
        var current: HybridConfig? = config
        val asked = CopyOnWriteArrayList<AndroidModelOption>()
        val engine = object : HybridEngine by FakeEngine() {
            override suspend fun availability(config: HybridConfig, withImage: Boolean): AvailabilityResult {
                asked += config.androidModel
                // configure() lands while the first check is running.
                if (asked.size == 1) current = config.copy(androidModel = AndroidModelOption.STABLE)
                return AvailabilityResult(OnDeviceStatus.AVAILABLE, modelLabel = config.androidModel.wire)
            }
        }
        val answer = currentAvailability(engine, { current }, config, withImage = false)
        assertEquals(listOf(AndroidModelOption.PREVIEW, AndroidModelOption.STABLE), asked.toList())
        assertEquals("stable", answer.modelLabel)
        current = null
        assertEquals(
            Reasons.NOT_CONFIGURED,
            currentAvailability(engine, { current }, config, withImage = false).reason,
        )
    }

    @Test
    fun aSecondListenerJoinsTheRunningDownload() {
        val gate = CompletableDeferred<Unit>()
        val engine = FakeEngine(onPrepare = { flow { emit(0.1); gate.await(); emit(1.0) } })
        val p = PrepareCoordinator(scope, engine, { config })
        val first = RecordingSink()
        p.onListen(null, first)
        runBlocking { delay(50) }
        p.onCancel()
        val second = RecordingSink()
        p.onListen(null, second)
        assertTrue(p.isRunning)
        gate.complete(Unit)
        second.await()
        assertEquals(1, engine.prepareCalls)
        assertEquals(listOf<Any?>(mapOf("fraction" to 1.0), "end"), second.events.toList())
        assertFalse("end" in first.events, "a cancelled listener gets nothing more")
    }
}

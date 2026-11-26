package dev.soussight.ai_logic_hybrid

import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout

/** What the channel layer needs from an inference backend. The real one wraps Firebase AI Logic. */
interface HybridEngine {
    suspend fun availability(config: HybridConfig, withImage: Boolean): AvailabilityResult

    /** Fractions 0..1 (null if unknown); completes when the model is ready; throws [HybridError]. */
    fun prepare(config: HybridConfig, withImage: Boolean): Flow<Double?>

    suspend fun generate(config: HybridConfig, request: GenerateRequest): GenerateResult
}

/**
 * Availability for the configuration current when the answer is sent: if `configure` changed the
 * model option while the status check was running, the check is repeated for the new one.
 */
suspend fun currentAvailability(
    engine: HybridEngine,
    config: () -> HybridConfig?,
    start: HybridConfig,
    withImage: Boolean,
): AvailabilityResult {
    var snapshot = start
    repeat(3) {
        val answer = engine.availability(snapshot, withImage)
        val now = config() ?: return AvailabilityResult(OnDeviceStatus.UNAVAILABLE, Reasons.NOT_CONFIGURED)
        // modelOption: the option this answer is about.
        if (now == snapshot) return answer.copy(modelOption = snapshot.androidModel)
        snapshot = now
    }
    // Config keeps changing; report nothing rather than a status for a superseded option.
    return AvailabilityResult(OnDeviceStatus.UNAVAILABLE, Reasons.MODEL_NOT_READY)
}

/** A method-channel reply, answered at most once. */
interface Reply {
    fun success(value: Any?)
    fun error(code: String, message: String?)
}

/** An event-channel sink. */
interface PrepareSink {
    fun success(event: Any?)
    fun error(code: String, message: String?)
    fun endOfStream()
}

/**
 * Runs `generate` calls: timeout, cancel, one reply per call, and late results discarded.
 *
 * Config is snapshotted when the call starts, so a later `configure` cannot change a call in
 * flight. `cancel` answers `cancelled` at once and then cancels the coroutine; whether the SDK
 * stops the native work depends on the SDK (cloud calls are cancellable coroutines; on-device
 * work is abandoned if ML Kit does not honour cancellation). Whatever it returns later is dropped.
 */
class GenerateCoordinator(
    private val scope: CoroutineScope,
    private val engine: HybridEngine,
    private val config: () -> HybridConfig?,
) {
    private val pending = ConcurrentHashMap<String, PendingCall>()

    fun start(args: Any?, reply: Reply) {
        val request = try {
            Protocol.parseGenerate(args)
        } catch (e: HybridError) {
            reply.error(e.code.wire, e.message)
            return
        }
        val snapshot = config()
        if (snapshot == null) {
            reply.error(HybridErrorCode.UNAVAILABLE.wire, Reasons.NOT_CONFIGURED)
            return
        }
        val call = PendingCall(request.requestId, reply)
        if (pending.putIfAbsent(request.requestId, call) != null) {
            reply.error(HybridErrorCode.FAILED.wire, "Duplicate requestId ${request.requestId}")
            return
        }
        // The deadline is its own coroutine, started before the work, so the caller hears
        // `timeout` at timeoutMs even if the SDK is slow to honour cancellation (or never does).
        // The native work is cancelled after the reply and unwinds on its own time; whatever it
        // returns later is dropped by the one-reply guard.
        call.deadline = scope.launch {
            delay(request.timeoutMs)
            if (call.fail(HybridErrorCode.TIMEOUT, "Timed out after ${request.timeoutMs} ms")) {
                pending.remove(request.requestId, call)
                call.work?.cancel()
            }
        }
        val work = scope.launch {
            try {
                // Cooperative path; the deadline above answers even if this cannot unwind.
                val result = withTimeout(request.timeoutMs) { engine.generate(snapshot, request) }
                if (request.mode == HybridMode.ONLY_ON_DEVICE &&
                    result.source != InferenceSourceWire.ON_DEVICE
                ) {
                    // Never return a widened result; the engine also checks before sending.
                    call.fail(HybridErrorCode.FAILED, "onlyOnDevice result reported source ${result.source.wire}")
                } else {
                    call.succeed(Protocol.resultMap(request.requestId, result))
                }
            } catch (e: TimeoutCancellationException) {
                call.fail(HybridErrorCode.TIMEOUT, "Timed out after ${request.timeoutMs} ms")
            } catch (e: CancellationException) {
                call.fail(HybridErrorCode.CANCELLED, "Cancelled")
                throw e
            } catch (e: Throwable) {
                val mapped = ErrorMapping.classify(e)
                call.fail(mapped.code, mapped.message)
            } finally {
                call.deadline?.cancel()
                pending.remove(request.requestId, call)
            }
        }
        call.work = work
    }

    fun cancel(requestId: String?) {
        if (requestId == null) return
        val call = pending.remove(requestId) ?: return
        call.fail(HybridErrorCode.CANCELLED, "Cancelled")
        call.deadline?.cancel()
        call.work?.cancel()
    }

    fun cancelAll() {
        for (id in pending.keys.toList()) cancel(id)
    }

    val pendingCount: Int get() = pending.size

    private class PendingCall(val requestId: String, private val reply: Reply) {
        private val done = AtomicBoolean(false)
        @Volatile var work: Job? = null
        @Volatile var deadline: Job? = null

        fun succeed(value: Any?): Boolean {
            if (!done.compareAndSet(false, true)) return false
            reply.success(value)
            return true
        }

        fun fail(code: HybridErrorCode, message: String?): Boolean {
            if (!done.compareAndSet(false, true)) return false
            reply.error(code.wire, message)
            return true
        }
    }
}

/**
 * The prepare event stream. One download job at a time; a new listener while it runs is attached
 * to the same job (a download cannot be cancelled, DESIGN §4). Events go to the current sink only.
 */
class PrepareCoordinator(
    private val scope: CoroutineScope,
    private val engine: HybridEngine,
    private val config: () -> HybridConfig?,
) {
    @Volatile private var sink: PrepareSink? = null
    @Volatile private var job: Job? = null
    @Volatile private var jobConfig: HybridConfig? = null

    fun onListen(args: Any?, newSink: PrepareSink) {
        val snapshot = config()
        if (job?.isActive == true) {
            if (jobConfig == snapshot) {
                sink = newSink
            } else {
                // A download cannot be cancelled, and joining it would report readiness of a
                // model option the app no longer asks for.
                newSink.error(HybridErrorCode.BUSY.wire, "A download for another model option is running")
            }
            return
        }
        sink = newSink
        if (snapshot == null) {
            newSink.error(HybridErrorCode.UNAVAILABLE.wire, Reasons.NOT_CONFIGURED)
            return
        }
        val withImage = Protocol.parseWithImage(args)
        jobConfig = snapshot
        job = scope.launch {
            try {
                engine.prepare(snapshot, withImage).collect { sink?.success(Protocol.fractionEvent(it)) }
                sink?.endOfStream()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                val mapped = ErrorMapping.classify(e)
                sink?.error(mapped.code.wire, mapped.message)
            }
        }
    }

    fun onCancel() {
        sink = null
    }

    val isRunning: Boolean get() = job?.isActive == true
}

/** Download lifecycle events, decoupled from the SDK's DownloadStatus (internal constructors). */
sealed class DownloadEvent {
    data class Started(val bytesToDownload: Long) : DownloadEvent()
    data class Progress(val totalBytesDownloaded: Long) : DownloadEvent()
    data object Completed : DownloadEvent()
    data class Failed(val error: Throwable) : DownloadEvent()
}

/** Turns download events into fractions. Returns null for "unknown". */
class DownloadProgress {
    private var total = 0L

    fun fraction(event: DownloadEvent): Double? = when (event) {
        is DownloadEvent.Started -> {
            total = event.bytesToDownload
            if (total > 0) 0.0 else null
        }
        is DownloadEvent.Progress ->
            if (total > 0) (event.totalBytesDownloaded.toDouble() / total).coerceIn(0.0, 1.0) else null
        DownloadEvent.Completed -> 1.0
        is DownloadEvent.Failed -> throw ErrorMapping.classify(event.error)
    }
}

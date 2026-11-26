package dev.soussight.ai_logic_hybrid

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emitAll
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.withTimeout

/**
 * `androidModel = auto` (the default): use the best Gemini Nano that actually answers.
 *
 * A preview model's status alone cannot be trusted: on a Pixel 9 the Nano 4 preview
 * (`nano-v4-full`) reports `available`, yet every generate fails with ML Kit NOT_AVAILABLE (8).
 * So, once per engine (one app run):
 * 1. Check the preview's status. Anything but `available` means STABLE.
 * 2. If it is available, send a tiny `onlyOnDevice` probe ([PROBE_PROMPT], [PROBE_MAX_TOKENS]).
 *    Only an on-device answer within [probeTimeoutMs] selects PREVIEW; any failure selects STABLE.
 * 3. The decision is cached. The check runs detached from whichever call started it, so a caller
 *    that times out or is cancelled stops waiting without abandoning the check; every caller
 *    shares the one answer.
 *
 * If a later generate on PREVIEW fails with NOT_AVAILABLE, the decision becomes STABLE and the
 * request is retried once on STABLE with `onlyOnDevice`. That retry never reaches the cloud (the
 * SDK builds no cloud client for ONLY_ON_DEVICE) and never widens the mode: `onlyInCloud` never
 * runs on-device, never waits for the local check, and is never retried. A caller cancelled before
 * the late failure arrives gets no retry. Explicit `preview`, `previewFast` and `stable` pass
 * through untouched, with no probe and no retry.
 *
 * The probe and retry carry no cook data. [log] gets the decision (options, status, model name,
 * error class and code, latency) and never prompt or response text.
 */
class AutoModelEngine(
    private val inner: HybridEngine,
    private val probeTimeoutMs: Long = PROBE_TIMEOUT_MS,
    /** Debug builds only: also probe STABLE when it is chosen, so logcat shows it answering. */
    private val verifyChoice: Boolean = false,
    private val log: (String) -> Unit = {},
    private val nanoTime: () -> Long = System::nanoTime,
) : HybridEngine {

    private val lock = Any()
    @Volatile private var chosen: AndroidModelOption? = null
    private var pending: Deferred<AndroidModelOption>? = null

    /** The cached decision; null until `auto` has been resolved. */
    val decision: AndroidModelOption? get() = chosen

    override fun modelOption(config: HybridConfig): AndroidModelOption? =
        if (config.androidModel == AndroidModelOption.AUTO) chosen else config.androidModel

    override suspend fun availability(config: HybridConfig, withImage: Boolean): AvailabilityResult {
        val concrete = concrete(config)
        return inner.availability(concrete, withImage).copy(modelOption = concrete.androidModel)
    }

    override fun prepare(config: HybridConfig, withImage: Boolean): Flow<Double?> =
        if (config.androidModel != AndroidModelOption.AUTO) {
            inner.prepare(config, withImage)
        } else {
            flow {
                val concrete = concrete(config)
                log("auto: preparing ${concrete.androidModel.wire}")
                emitAll(inner.prepare(concrete, withImage))
            }
        }

    override suspend fun generate(config: HybridConfig, request: GenerateRequest): GenerateResult {
        if (config.androidModel != AndroidModelOption.AUTO) return inner.generate(config, request)
        if (request.mode == HybridMode.ONLY_IN_CLOUD) {
            // Never runs on-device, so it must not wait for the local check or its probe. The SDK
            // builds only a cloud provider for this mode; the option just has to be concrete.
            return inner.generate(config.copy(androidModel = chosen ?: AndroidModelOption.STABLE), request)
        }
        val option = resolve(config)
        try {
            return inner.generate(config.copy(androidModel = option), request)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            if (option != AndroidModelOption.PREVIEW || !ErrorMapping.isModelNotAvailable(e)) throw e
            // A native call that ignored cancellation may fail late; a caller that was cancelled
            // or timed out meanwhile must not start another generation.
            currentCoroutineContext().ensureActive()
            chosen = AndroidModelOption.STABLE
            log("auto: preview failed mid-session (${describe(e)}); using stable for this run, retrying once on-device")
            // Narrowed to onlyOnDevice: the retry may only run on this device.
            val retry = request.copy(mode = HybridMode.ONLY_ON_DEVICE)
            return inner.generate(config.copy(androidModel = AndroidModelOption.STABLE), retry)
        }
    }

    private suspend fun concrete(config: HybridConfig): HybridConfig =
        if (config.androidModel == AndroidModelOption.AUTO) {
            config.copy(androidModel = resolve(config))
        } else {
            config
        }

    /** Single-flight: concurrent callers wait for one check and share its answer. */
    internal suspend fun resolve(config: HybridConfig): AndroidModelOption {
        chosen?.let { return it }
        val context = currentCoroutineContext().minusKey(Job)
        val job = synchronized(lock) {
            chosen?.let { return it }
            pending ?: CoroutineScope(context + SupervisorJob())
                .async { decide(config).also { chosen = it } }
                .also { pending = it }
        }
        return try {
            chosen ?: job.await()
        } catch (e: CancellationException) {
            // The caller was cancelled (the check goes on), or the check itself was cancelled:
            // then it is not a decision, and the next caller starts a new one.
            if (job.isCancelled) synchronized(lock) { if (pending === job) pending = null }
            throw e
        }
    }

    private suspend fun decide(config: HybridConfig): AndroidModelOption {
        val preview = config.copy(androidModel = AndroidModelOption.PREVIEW)
        val status = try {
            inner.availability(preview, withImage = false)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            log("auto: preview status check failed (${describe(e)}); using stable")
            return verified(config, AndroidModelOption.STABLE)
        }
        if (status.status != OnDeviceStatus.AVAILABLE) {
            log("auto: preview is ${status.status.wire} (${status.reason}); using stable")
            return verified(config, AndroidModelOption.STABLE)
        }
        val outcome = probe(preview)
        return if (outcome == null) {
            log("auto: preview ${status.modelLabel ?: "(unnamed)"} answered on-device; using preview")
            AndroidModelOption.PREVIEW
        } else {
            log("auto: preview ${status.modelLabel ?: "(unnamed)"} is available but cannot answer ($outcome); using stable")
            verified(config, AndroidModelOption.STABLE)
        }
    }

    /** In debug builds, shows in logcat whether the chosen option answers; never changes it. */
    private suspend fun verified(config: HybridConfig, option: AndroidModelOption): AndroidModelOption {
        if (verifyChoice) {
            val outcome = probe(config.copy(androidModel = option))
            if (outcome != null) log("auto: ${option.wire} did not answer the debug probe ($outcome)")
        }
        return option
    }

    /** Null when [config]'s model answered on-device; otherwise why not. Cancellation propagates. */
    private suspend fun probe(config: HybridConfig): String? {
        val start = nanoTime()
        fun ms() = (nanoTime() - start) / 1_000_000
        // Detached so the deadline holds even if the native call ignores cancellation.
        val call = CoroutineScope(currentCoroutineContext().minusKey(Job) + SupervisorJob())
            .async { inner.generate(config, probeRequest()) }
        return try {
            val result = withTimeout(probeTimeoutMs) { call.await() }
            if (result.source == InferenceSourceWire.ON_DEVICE) {
                log(
                    "auto: probe option=${config.androidModel.wire} source=${result.source.wire} " +
                        "model=${result.modelLabel ?: "(not reported)"} latencyMs=${ms()}",
                )
                null
            } else {
                "source ${result.source.wire} after ${ms()} ms"
            }
        } catch (e: TimeoutCancellationException) {
            "no answer within $probeTimeoutMs ms"
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            "${describe(e)} after ${ms()} ms"
        } finally {
            call.cancel()
        }
    }

    private fun probeRequest() = GenerateRequest(
        requestId = PROBE_REQUEST_ID,
        mode = HybridMode.ONLY_ON_DEVICE,
        feature = PROBE_FEATURE,
        systemInstruction = null,
        parts = listOf(HybridPart.Text(PROBE_PROMPT)),
        jsonSchema = null,
        maxOutputTokens = PROBE_MAX_TOKENS,
        timeoutMs = probeTimeoutMs,
    )

    private fun describe(e: Throwable): String {
        val mapped = ErrorMapping.classify(e)
        val notAvailable = if (ErrorMapping.isModelNotAvailable(e)) ", NOT_AVAILABLE" else ""
        return "${e.javaClass.simpleName}: ${mapped.code.wire}$notAvailable"
    }

    companion object {
        const val PROBE_PROMPT = "Reply with OK"
        const val PROBE_MAX_TOKENS = 4
        const val PROBE_TIMEOUT_MS = 8_000L
        const val PROBE_REQUEST_ID = "auto-model-probe"
        const val PROBE_FEATURE = "auto_model_probe"
    }
}

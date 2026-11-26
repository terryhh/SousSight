package dev.soussight.ai_logic_hybrid

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
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
 * 1. Check the preview's status (and name) within [statusTimeoutMs]. Anything but `available`,
 *    an error or no answer in time means STABLE; a late answer is discarded.
 * 2. If it is available, send a tiny `onlyOnDevice` probe ([PROBE_PROMPT], [PROBE_MAX_TOKENS]).
 *    Only a nonblank on-device answer within [probeTimeoutMs] selects PREVIEW; anything else
 *    selects STABLE.
 * 3. The decision is cached. The check runs in [scope] (the plugin's lifetime), not in whichever
 *    call started it: a caller that times out or is cancelled stops waiting without abandoning
 *    the check, every caller shares the one answer, and detaching the plugin cancels it.
 *
 * Later, PREVIEW gives way to STABLE (never the reverse) when:
 * - an availability check finds PREVIEW `unavailable` while STABLE is `available`; or
 * - a generate on PREVIEW fails with NOT_AVAILABLE. That request is then retried once on STABLE
 *   with `onlyOnDevice`, unless its caller was cancelled meanwhile. The retry never reaches the
 *   cloud (the SDK builds no cloud client for ONLY_ON_DEVICE) and never widens the mode.
 * `onlyInCloud` never runs on-device, never waits for the local check and is never retried.
 * Requests are validated before the check, so invalid input makes no backend call at all.
 * Explicit `preview`, `previewFast` and `stable` pass through untouched: no probe, no retry.
 *
 * Privacy: the probe sends only the fixed [PROBE_PROMPT]. The retry replays the cook's own
 * request (text and image) on this device only. [log] gets options, status, model name, error
 * class and code, and latency; never prompt or response text.
 */
class AutoModelEngine(
    private val inner: HybridEngine,
    /** Owns the shared check and probes; cancelled when the plugin detaches. */
    private val scope: CoroutineScope,
    private val probeTimeoutMs: Long = PROBE_TIMEOUT_MS,
    private val statusTimeoutMs: Long = STATUS_TIMEOUT_MS,
    /** Debug builds only: also probe STABLE when it is chosen, so logcat shows it answering. */
    internal val verifyChoice: Boolean = false,
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
        if (config.androidModel != AndroidModelOption.AUTO) {
            return inner.availability(config, withImage).copy(modelOption = config.androidModel)
        }
        var option = resolve(config)
        // The selection only moves PREVIEW -> STABLE, so this settles within two rounds; a third
        // covers a downgrade racing the stable check.
        repeat(3) {
            var answer = inner.availability(config.copy(androidModel = option), withImage)
            if (option == AndroidModelOption.PREVIEW && answer.status == OnDeviceStatus.UNAVAILABLE) {
                val stable = inner.availability(config.copy(androidModel = AndroidModelOption.STABLE), withImage)
                if (stable.status == OnDeviceStatus.AVAILABLE) {
                    downgrade("preview became ${answer.status.wire} (${answer.reason}) while stable is available")
                    option = AndroidModelOption.STABLE
                    answer = stable
                }
            }
            // Report only what is still selected: a downgrade may have landed during the await.
            val now = chosen ?: option
            if (now == option) return answer.copy(modelOption = option)
            option = now
        }
        return AvailabilityResult(OnDeviceStatus.UNAVAILABLE, Reasons.MODEL_NOT_READY)
    }

    override fun prepare(config: HybridConfig, withImage: Boolean): Flow<Double?> =
        if (config.androidModel != AndroidModelOption.AUTO) {
            inner.prepare(config, withImage)
        } else {
            flow {
                val option = resolve(config)
                log("auto: preparing ${option.wire}")
                emitAll(inner.prepare(config.copy(androidModel = option), withImage))
            }
        }

    override suspend fun generate(config: HybridConfig, request: GenerateRequest): GenerateResult {
        if (config.androidModel != AndroidModelOption.AUTO) return inner.generate(config, request)
        // Before the check: invalid input fails with no backend call (DESIGN §4).
        InputRules.validate(request)
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
            downgrade("preview failed mid-session (${describe(e)})")
            log("auto: retrying once on stable, on-device only")
            val retry = request.copy(mode = HybridMode.ONLY_ON_DEVICE)
            return inner.generate(config.copy(androidModel = AndroidModelOption.STABLE), retry)
        }
    }

    private fun downgrade(why: String) {
        val changed = synchronized(lock) {
            (chosen == AndroidModelOption.PREVIEW).also { if (it) chosen = AndroidModelOption.STABLE }
        }
        if (changed) log("auto: $why; using stable for this run")
    }

    /** Single-flight: concurrent callers wait for one check and share its answer. */
    internal suspend fun resolve(config: HybridConfig): AndroidModelOption {
        chosen?.let { return it }
        val job = synchronized(lock) {
            chosen?.let { return it }
            pending?.takeUnless { it.isCancelled }
                ?: scope.async {
                    val option = decide(config)
                    synchronized(lock) { chosen ?: option.also { chosen = it } }
                }.also { pending = it }
        }
        return chosen ?: job.await()
    }

    private suspend fun decide(config: HybridConfig): AndroidModelOption {
        val preview = config.copy(androidModel = AndroidModelOption.PREVIEW)
        val status = try {
            bounded(statusTimeoutMs) { inner.availability(preview, withImage = false) }
        } catch (e: TimeoutCancellationException) {
            log("auto: preview status gave no answer within $statusTimeoutMs ms; using stable")
            return verified(config, AndroidModelOption.STABLE)
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
        return try {
            val result = bounded(probeTimeoutMs) { inner.generate(config, probeRequest()) }
            when {
                result.source != InferenceSourceWire.ON_DEVICE -> "source ${result.source.wire} after ${ms()} ms"
                result.text.isBlank() -> "blank answer after ${ms()} ms"
                else -> {
                    log(
                        "auto: probe option=${config.androidModel.wire} source=${result.source.wire} " +
                            "model=${result.modelLabel ?: "(not reported)"} latencyMs=${ms()}",
                    )
                    null
                }
            }
        } catch (e: TimeoutCancellationException) {
            "no answer within $probeTimeoutMs ms"
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            "${describe(e)} after ${ms()} ms"
        }
    }

    /**
     * [block] in [scope] under a deadline that holds even if the native call ignores
     * cancellation; whatever it returns after the deadline is discarded.
     */
    private suspend fun <T> bounded(timeoutMs: Long, block: suspend () -> T): T {
        val call = scope.async { block() }
        try {
            return withTimeout(timeoutMs) { call.await() }
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
        const val STATUS_TIMEOUT_MS = 3_000L
        const val PROBE_REQUEST_ID = "auto-model-probe"
        const val PROBE_FEATURE = "auto_model_probe"
    }
}

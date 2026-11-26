package dev.soussight.ai_logic_hybrid

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emitAll
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout

/**
 * `androidModel = auto` (the default): use the best Gemini Nano that actually answers.
 *
 * A preview model's status alone cannot be trusted: on a Pixel 9 the Nano 4 preview
 * (`nano-v4-full`) reports `available`, yet every generate fails with ML Kit NOT_AVAILABLE (8).
 *
 * **Selection happens at startup only, never inside a request.** STABLE is in use until a
 * background check, started by `configure` and again after `prepare`, proves PREVIEW: its status
 * is `available` (within [statusTimeoutMs]) and a fixed-prompt `onlyOnDevice` probe
 * ([PROBE_PROMPT], [PROBE_MAX_TOKENS]) returns nonblank text from the device within
 * [probeTimeoutMs]. A preview that fails its probe is not tried again this run. `generate` never
 * waits for the check: it uses whatever is selected when it is called.
 *
 * PREVIEW gives way to STABLE (never the reverse) when a generate on it fails with
 * NOT_AVAILABLE (that request is retried once on STABLE, `onlyOnDevice`, unless its caller was
 * cancelled), when a `preferOnDevice` answer on it came from the cloud and a background probe
 * confirms it cannot answer (that answer keeps its cloud provenance), or when availability finds
 * it gone while STABLE is ready.
 *
 * Availability reports the selected model when it is ready; otherwise the best recoverable state
 * of either model (downloading, then downloadable), so setup is never hidden, and `prepare`
 * downloads that model. Every status lookup and probe runs in [scope] (the plugin's lifetime,
 * cancelled on detach) on [work] (off the main thread) under its own deadline.
 *
 * `onlyInCloud` is never retried. Explicit `preview`, `previewFast` and `stable` pass through.
 *
 * Privacy: probes send only [PROBE_PROMPT]. The retry replays the cook's request (text and
 * image) on this device only. [log] gets options, status, model name, error class and code, and
 * latency; never prompt or response text.
 */
class AutoModelEngine(
    private val inner: HybridEngine,
    /** Owns the check and probes; cancelled when the plugin detaches. */
    private val scope: CoroutineScope,
    private val probeTimeoutMs: Long = PROBE_TIMEOUT_MS,
    private val statusTimeoutMs: Long = STATUS_TIMEOUT_MS,
    /** Where status lookups and probes run; never the main thread in production. */
    private val work: CoroutineDispatcher = Dispatchers.IO,
    /** Debug builds only: probe STABLE too when the check keeps it, so logcat shows it answering. */
    internal val verifyChoice: Boolean = false,
    private val log: (String) -> Unit = {},
    private val nanoTime: () -> Long = System::nanoTime,
) : HybridEngine {

    private val lock = Any()
    @Volatile private var selected = AndroidModelOption.STABLE
    @Volatile private var previewBroken = false
    private var check: Job? = null
    private var recheck: Job? = null

    /** The option `auto` uses right now. */
    val decision: AndroidModelOption get() = selected

    /** The startup check, if one was started (tests). */
    internal val checkJob: Job? get() = synchronized(lock) { check }

    /** The background probe after a cloud answer on PREVIEW, if one was started (tests). */
    internal val recheckJob: Job? get() = synchronized(lock) { recheck }

    override fun modelOption(config: HybridConfig): AndroidModelOption =
        if (config.androidModel == AndroidModelOption.AUTO) selected else config.androidModel

    override fun configured(config: HybridConfig) {
        if (config.androidModel == AndroidModelOption.AUTO) startCheck(config)
    }

    override suspend fun availability(config: HybridConfig, withImage: Boolean): AvailabilityResult {
        if (config.androidModel != AndroidModelOption.AUTO) {
            return inner.availability(config, withImage).copy(modelOption = config.androidModel)
        }
        // Report only what is still selected after the lookups (a downgrade may land meanwhile).
        repeat(3) {
            val option = selected
            val answer = report(config, option, withImage)
            if (selected == option || answer.modelOption == selected) return answer
        }
        return AvailabilityResult(OnDeviceStatus.UNAVAILABLE, Reasons.MODEL_NOT_READY)
    }

    override fun prepare(config: HybridConfig, withImage: Boolean): Flow<Double?> =
        if (config.androidModel != AndroidModelOption.AUTO) {
            inner.prepare(config, withImage)
        } else {
            flow {
                val target = availability(config, withImage).modelOption ?: AndroidModelOption.STABLE
                log("auto: preparing ${target.wire}")
                emitAll(inner.prepare(config.copy(androidModel = target), withImage))
                // A freshly downloaded preview must pass the probe before it is used.
                startCheck(config)
            }
        }

    override suspend fun generate(config: HybridConfig, request: GenerateRequest): GenerateResult {
        if (config.androidModel != AndroidModelOption.AUTO) return inner.generate(config, request)
        val option = selected // never waits for selection
        try {
            val result = inner.generate(config.copy(androidModel = option), request)
            if (option == AndroidModelOption.PREVIEW &&
                request.mode == HybridMode.PREFER_ON_DEVICE &&
                result.source == InferenceSourceWire.CLOUD
            ) {
                recheckPreview(config)
            }
            return result
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            if (option != AndroidModelOption.PREVIEW ||
                request.mode == HybridMode.ONLY_IN_CLOUD ||
                !ErrorMapping.isModelNotAvailable(e)
            ) {
                throw e
            }
            // A native call that ignored cancellation may fail late; a caller that was cancelled
            // or timed out meanwhile must not start another generation.
            currentCoroutineContext().ensureActive()
            previewUnusable("preview failed mid-session (${describe(e)}); retrying once on stable, on-device only")
            val retry = request.copy(mode = HybridMode.ONLY_ON_DEVICE)
            return inner.generate(config.copy(androidModel = AndroidModelOption.STABLE), retry)
        }
    }

    /** Starts the background check unless PREVIEW is in use, known broken, or being checked. */
    internal fun startCheck(config: HybridConfig): Job? = synchronized(lock) {
        if (selected == AndroidModelOption.PREVIEW || previewBroken || check?.isActive == true) {
            return@synchronized check
        }
        scope.launch(work) { runCheck(config) }.also { check = it }
    }

    private suspend fun runCheck(config: HybridConfig) {
        val preview = config.copy(androidModel = AndroidModelOption.PREVIEW)
        val status = status(preview)
        if (status?.status != OnDeviceStatus.AVAILABLE) {
            log("auto: preview is ${status?.status?.wire ?: "unknown"}; stable stays in use")
            verify(config)
            return
        }
        val name = status.modelLabel ?: "(unnamed)"
        val outcome = probe(preview)
        if (outcome == null) {
            val used = synchronized(lock) {
                (!previewBroken).also { if (it) selected = AndroidModelOption.PREVIEW }
            }
            if (used) log("auto: preview $name answered on-device; using preview")
        } else {
            previewUnusable("preview $name is available but cannot answer ($outcome)")
            verify(config)
        }
    }

    /** After a `preferOnDevice` answer on PREVIEW came from the cloud: one background probe. */
    private fun recheckPreview(config: HybridConfig) = synchronized(lock) {
        if (selected != AndroidModelOption.PREVIEW || recheck?.isActive == true) return@synchronized
        recheck = scope.launch(work) {
            val outcome = probe(config.copy(androidModel = AndroidModelOption.PREVIEW))
            if (outcome != null) {
                previewUnusable("a preferOnDevice answer came from the cloud and preview cannot answer ($outcome)")
            } else {
                log("auto: a preferOnDevice answer came from the cloud, but preview answers on-device; keeping it")
            }
        }
    }

    private fun previewUnusable(why: String) {
        synchronized(lock) {
            previewBroken = true
            selected = AndroidModelOption.STABLE
        }
        log("auto: $why; using stable for this run")
    }

    /**
     * The selected model's state when it is ready, else the best recoverable state of either
     * (downloading, then downloadable; ties keep the selected one), never a broken preview.
     */
    private suspend fun report(config: HybridConfig, option: AndroidModelOption, withImage: Boolean): AvailabilityResult {
        val mine = status(config.copy(androidModel = option), withImage)
            ?: AvailabilityResult(OnDeviceStatus.UNAVAILABLE, Reasons.MODEL_NOT_READY)
        if (mine.status == OnDeviceStatus.AVAILABLE) return mine.copy(modelOption = option)
        val other = if (option == AndroidModelOption.PREVIEW) {
            AndroidModelOption.STABLE
        } else {
            AndroidModelOption.PREVIEW.takeUnless { previewBroken }
        } ?: return mine.copy(modelOption = option)
        val theirs = status(config.copy(androidModel = other), withImage)
            ?: return mine.copy(modelOption = option)
        if (theirs.status == OnDeviceStatus.AVAILABLE) {
            if (other == AndroidModelOption.STABLE) {
                // The selected preview is gone and stable is ready.
                synchronized(lock) { if (selected == AndroidModelOption.PREVIEW) selected = AndroidModelOption.STABLE }
                log("auto: preview is ${mine.status.wire}; stable is ready; using stable")
                return theirs.copy(modelOption = AndroidModelOption.STABLE)
            }
            // An unproven preview is never reported ready; make sure it gets its probe.
            startCheck(config)
            return mine.copy(modelOption = option)
        }
        return if (rank(theirs.status) > rank(mine.status)) theirs.copy(modelOption = other)
        else mine.copy(modelOption = option)
    }

    private fun rank(status: OnDeviceStatus) = when (status) {
        OnDeviceStatus.DOWNLOADING -> 2
        OnDeviceStatus.DOWNLOADABLE -> 1
        else -> 0
    }

    /** In debug builds, shows in logcat whether STABLE answers; never changes the selection. */
    private suspend fun verify(config: HybridConfig) {
        if (!verifyChoice) return
        val outcome = probe(config.copy(androidModel = AndroidModelOption.STABLE))
        if (outcome != null) log("auto: stable did not answer the debug probe ($outcome)")
    }

    /** One bounded status lookup; null on error or timeout (logged). */
    private suspend fun status(config: HybridConfig, withImage: Boolean = false): AvailabilityResult? = try {
        bounded(statusTimeoutMs) { inner.availability(config, withImage) }
    } catch (e: TimeoutCancellationException) {
        log("auto: ${config.androidModel.wire} status gave no answer within $statusTimeoutMs ms")
        null
    } catch (e: CancellationException) {
        throw e
    } catch (e: Throwable) {
        log("auto: ${config.androidModel.wire} status check failed (${describe(e)})")
        null
    }

    /** Null when [config]'s model answered on-device with text; otherwise why not. */
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
     * [block] in [scope] on [work] under a deadline that holds even if the native call ignores
     * cancellation; whatever it returns after the deadline is discarded.
     */
    private suspend fun <T> bounded(timeoutMs: Long, block: suspend () -> T): T {
        val call = scope.async(work) { block() }
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

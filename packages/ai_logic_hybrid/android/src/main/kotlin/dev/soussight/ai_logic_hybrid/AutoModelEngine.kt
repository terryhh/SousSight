package dev.soussight.ai_logic_hybrid

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout

/**
 * `androidModel = auto` (the default): use Gemini Nano 4 (PREVIEW) only where it already works.
 *
 * A preview model's status alone cannot be trusted: on a Pixel 9 the Nano 4 preview
 * (`nano-v4-full`) reports `available`, yet every generate fails with ML Kit NOT_AVAILABLE (8).
 *
 * **Selection happens once, at startup, and only ever away from PREVIEW.** STABLE is in use
 * unless the check started by the first `configure` finds PREVIEW already `available` (status
 * within [statusTimeoutMs]) and a fixed-prompt `onlyOnDevice` probe ([PROBE_PROMPT],
 * [PROBE_MAX_TOKENS]) returns nonblank text from the device within [probeTimeoutMs]. Auto never
 * downloads, installs or promotes PREVIEW later. Availability, `prepare` and `generate` all use
 * the option selected at that moment; `generate` never waits for the check.
 *
 * PREVIEW gives way to STABLE for later requests when a generate on it fails with NOT_AVAILABLE
 * (the error is returned as is, so the ledger records the failed on-device attempt), or when a
 * `preferOnDevice` answer on it came from the cloud and a background probe confirms PREVIEW
 * cannot answer (that answer keeps its cloud provenance). Explicit `preview`, `previewFast`
 * and `stable` pass through untouched.
 *
 * The check and probes run in [scope] (the plugin's lifetime, cancelled on detach) on [work]
 * (off the main thread), each under its own deadline. Privacy: probes send only [PROBE_PROMPT];
 * [log] gets options, status, model name, error class and code, and latency, never prompt or
 * response text.
 */
class AutoModelEngine(
    private val inner: HybridEngine,
    /** Owns the check and probes; cancelled when the plugin detaches. */
    private val scope: CoroutineScope,
    private val probeTimeoutMs: Long = PROBE_TIMEOUT_MS,
    private val statusTimeoutMs: Long = STATUS_TIMEOUT_MS,
    /** Where the startup check and probes run; never the main thread in production. */
    private val work: CoroutineDispatcher = Dispatchers.IO,
    /** Debug builds only: probe STABLE too when it is kept, so logcat shows it answering. */
    internal val verifyChoice: Boolean = false,
    private val log: (String) -> Unit = {},
    private val nanoTime: () -> Long = System::nanoTime,
) : HybridEngine {

    private val lock = Any()
    @Volatile private var selected = AndroidModelOption.STABLE
    private var check: Job? = null
    private var recheck: Job? = null

    /** The option `auto` uses right now. */
    val decision: AndroidModelOption get() = selected

    /** The startup check, once started (tests). */
    internal val checkJob: Job? get() = synchronized(lock) { check }

    /** The background probe after a cloud answer on PREVIEW, if one was started (tests). */
    internal val recheckJob: Job? get() = synchronized(lock) { recheck }

    override fun modelOption(config: HybridConfig): AndroidModelOption =
        if (config.androidModel == AndroidModelOption.AUTO) selected else config.androidModel

    /** The first `configure` with `auto` starts the one startup check. */
    override fun configured(config: HybridConfig) {
        if (config.androidModel != AndroidModelOption.AUTO) return
        synchronized(lock) {
            if (check == null) check = scope.launch(work) { runCheck(config) }
        }
    }

    override suspend fun availability(config: HybridConfig, withImage: Boolean): AvailabilityResult {
        if (config.androidModel != AndroidModelOption.AUTO) {
            return inner.availability(config, withImage).copy(modelOption = config.androidModel)
        }
        val option = selected
        val answer = inner.availability(config.copy(androidModel = option), withImage)
        // Report only what is still selected: PREVIEW may have given way during the lookup (the
        // one transition there is, so one more lookup settles it).
        val now = selected
        return if (now == option) answer.copy(modelOption = option)
        else inner.availability(config.copy(androidModel = now), withImage).copy(modelOption = now)
    }

    /** Under auto this is STABLE's setup (PREVIEW is only ever used when it is already ready). */
    override fun prepare(config: HybridConfig, withImage: Boolean): Flow<Double?> =
        inner.prepare(config.copy(androidModel = modelOption(config)), withImage)

    override suspend fun generate(config: HybridConfig, request: GenerateRequest): GenerateResult {
        if (config.androidModel != AndroidModelOption.AUTO) return inner.generate(config, request)
        val option = selected // never waits for the check
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
            if (option == AndroidModelOption.PREVIEW &&
                request.mode != HybridMode.ONLY_IN_CLOUD &&
                ErrorMapping.isModelNotAvailable(e)
            ) {
                // No retry here: the caller sees this attempt's real outcome.
                previewUnusable("preview failed mid-session (${describe(e)})")
            }
            throw e
        }
    }

    private suspend fun runCheck(config: HybridConfig) {
        val preview = config.copy(androidModel = AndroidModelOption.PREVIEW)
        val status = status(preview)
        if (status?.status != OnDeviceStatus.AVAILABLE) {
            log("auto: preview is ${status?.status?.wire ?: "unknown"}; using stable")
            verify(config)
            return
        }
        val name = status.modelLabel ?: "(unnamed)"
        val outcome = probe(preview)
        if (outcome == null) {
            selected = AndroidModelOption.PREVIEW
            log("auto: preview $name answered on-device; using preview")
        } else {
            log("auto: preview $name is available but cannot answer ($outcome); using stable")
            verify(config)
        }
    }

    /** After a `preferOnDevice` answer on PREVIEW came from the cloud: one background probe. */
    private fun recheckPreview(config: HybridConfig) = synchronized(lock) {
        if (recheck != null) return@synchronized
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
        selected = AndroidModelOption.STABLE
        log("auto: $why; using stable for this run")
    }

    /** In debug builds, shows in logcat whether STABLE answers; never changes the selection. */
    private suspend fun verify(config: HybridConfig) {
        if (!verifyChoice) return
        val outcome = probe(config.copy(androidModel = AndroidModelOption.STABLE))
        if (outcome != null) log("auto: stable did not answer the debug probe ($outcome)")
    }

    /** One bounded status lookup; null on error or timeout (logged). */
    private suspend fun status(config: HybridConfig): AvailabilityResult? = try {
        bounded(statusTimeoutMs) { inner.availability(config, withImage = false) }
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

package dev.soussight.ai_logic_hybrid

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
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
 * `androidModel = auto` (the default): use Gemini Nano 4 (PREVIEW) only where it already works.
 *
 * A preview model's status alone cannot be trusted: on a Pixel 9 the Nano 4 preview
 * (`nano-v4-full`) reports `available`, yet every generate fails with ML Kit NOT_AVAILABLE (8).
 *
 * **Startup selection, then a one-way ratchet.** The first `configure` waits for the selection,
 * at most [selectionTimeoutMs] in all: PREVIEW only if its status is already `available` and a
 * fixed-prompt `onlyOnDevice` probe ([PROBE_PROMPT], [PROBE_MAX_TOKENS]) returns nonblank text
 * from the device; anything else, or no answer in time, means STABLE. So the selection is final
 * before the app's first readiness read.
 *
 * After that the only change is PREVIEW to STABLE, permanently: when PREVIEW reports anything
 * but `available` (or its status check fails), or when a call on it fails (code 8 included).
 * The failing call returns its own error (no hidden retry); later calls use STABLE. Nothing is
 * ever re-checked or promoted back, and auto never downloads PREVIEW: `prepare` only sets up
 * STABLE. Availability reports the selected model's own status. Explicit `preview`,
 * `previewFast` and `stable` pass through untouched.
 *
 * The selection runs in [scope] (the plugin's lifetime, cancelled on detach) on [work] (off the
 * main thread). Privacy: the probe sends only [PROBE_PROMPT]; [log] gets options, status, model
 * name, error class and code, and latency, never prompt or response text.
 */
class AutoModelEngine(
    private val inner: HybridEngine,
    /** Owns the startup selection; cancelled when the plugin detaches. */
    private val scope: CoroutineScope,
    private val selectionTimeoutMs: Long = SELECTION_TIMEOUT_MS,
    /** Where the selection runs; never the main thread in production. */
    private val work: CoroutineDispatcher = Dispatchers.IO,
    /** Debug builds only: probe STABLE too when it is kept, so logcat shows it answering. */
    internal val verifyChoice: Boolean = false,
    private val log: (String) -> Unit = {},
    private val nanoTime: () -> Long = System::nanoTime,
) : HybridEngine {

    private val lock = Any()
    @Volatile private var selected = AndroidModelOption.STABLE
    private var selection: Deferred<Unit>? = null

    /** The option `auto` uses right now. */
    val decision: AndroidModelOption get() = selected

    override fun modelOption(config: HybridConfig): AndroidModelOption =
        if (config.androidModel == AndroidModelOption.AUTO) selected else config.androidModel

    /** The first `configure` with `auto` runs the selection; every caller waits for it. */
    override suspend fun configured(config: HybridConfig) {
        if (config.androidModel != AndroidModelOption.AUTO) return
        val job = synchronized(lock) {
            selection ?: scope.async(work) { select(config) }.also { selection = it }
        }
        job.await()
    }

    override suspend fun availability(config: HybridConfig, withImage: Boolean): AvailabilityResult {
        if (config.androidModel != AndroidModelOption.AUTO) {
            return inner.availability(config, withImage).copy(modelOption = config.androidModel)
        }
        if (selected == AndroidModelOption.PREVIEW) {
            val preview = try {
                inner.availability(config.copy(androidModel = AndroidModelOption.PREVIEW), withImage)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                demote("preview status check failed (${describe(e)})")
                null
            }
            if (preview != null && preview.status != OnDeviceStatus.AVAILABLE) {
                demote("preview is ${preview.status.wire} (${preview.reason})")
            }
            // Published only if preview is still selected after the lookup.
            if (preview != null && selected == AndroidModelOption.PREVIEW) {
                return preview.copy(modelOption = AndroidModelOption.PREVIEW)
            }
        }
        // STABLE from here on: the ratchet never moves back.
        return inner.availability(config.copy(androidModel = AndroidModelOption.STABLE), withImage)
            .copy(modelOption = AndroidModelOption.STABLE)
    }

    override fun prepare(config: HybridConfig, withImage: Boolean): Flow<Double?> =
        if (config.androidModel != AndroidModelOption.AUTO) {
            inner.prepare(config, withImage)
        } else if (selected == AndroidModelOption.STABLE) {
            // Final: nothing to look up first.
            inner.prepare(config.copy(androidModel = AndroidModelOption.STABLE), withImage)
        } else {
            flow {
                // A selected preview is ready or gets demoted here; preview is never downloaded.
                if (availability(config, withImage).modelOption == AndroidModelOption.PREVIEW) {
                    emit(1.0)
                } else {
                    emitAll(inner.prepare(config.copy(androidModel = AndroidModelOption.STABLE), withImage))
                }
            }
        }

    override suspend fun generate(config: HybridConfig, request: GenerateRequest): GenerateResult {
        if (config.androidModel != AndroidModelOption.AUTO) return inner.generate(config, request)
        val option = selected // never waits for the selection
        try {
            return inner.generate(config.copy(androidModel = option), request)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            // The cook's own input or a cloud-only call says nothing about preview.
            if (option == AndroidModelOption.PREVIEW &&
                request.mode != HybridMode.ONLY_IN_CLOUD &&
                ErrorMapping.classify(e).code != HybridErrorCode.UNSUPPORTED_INPUT
            ) {
                demote("a call on preview failed (${describe(e)})")
            }
            throw e
        }
    }

    private fun demote(why: String) {
        if (selected != AndroidModelOption.PREVIEW) return
        selected = AndroidModelOption.STABLE
        log("auto: $why; using stable for the rest of this run")
    }

    /** Sets [selected] to PREVIEW only if the bounded check proves it in time. */
    private suspend fun select(config: HybridConfig) {
        val start = nanoTime()
        // Detached under the deadline so a native call that ignores cancellation cannot hold
        // configure; a late answer is discarded.
        val check = scope.async(work) { previewWorks(config) }
        val works = try {
            withTimeout(selectionTimeoutMs) { check.await() }
        } catch (e: TimeoutCancellationException) {
            log("auto: no selection within $selectionTimeoutMs ms; using stable")
            false
        } finally {
            check.cancel()
        }
        if (works) {
            selected = AndroidModelOption.PREVIEW
            log("auto: using preview (selected in ${(nanoTime() - start) / 1_000_000} ms)")
        } else if (verifyChoice) {
            // Not awaited: configure does not wait for a debug log line.
            verifyJob = scope.launch(work) { verify(config) }
        }
    }

    /** Preview's status is already `available` and it answers the probe on-device. */
    private suspend fun previewWorks(config: HybridConfig): Boolean {
        val preview = config.copy(androidModel = AndroidModelOption.PREVIEW)
        val status = try {
            inner.availability(preview, withImage = false)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            log("auto: preview status check failed (${describe(e)}); using stable")
            return false
        }
        if (status.status != OnDeviceStatus.AVAILABLE) {
            log("auto: preview is ${status.status.wire}; using stable")
            return false
        }
        // A lookup that ignored cancellation may return after the deadline or a detach; then
        // no probe is sent.
        currentCoroutineContext().ensureActive()
        val outcome = probe(preview)
        if (outcome != null) {
            log("auto: preview ${status.modelLabel ?: "(unnamed)"} is available but cannot answer ($outcome); using stable")
        }
        return outcome == null
    }

    /** Debug builds: shows in logcat whether STABLE answers; never changes the selection. */
    internal var verifyJob: kotlinx.coroutines.Job? = null
        private set

    private suspend fun verify(config: HybridConfig) {
        val outcome = try {
            withTimeout(selectionTimeoutMs) { probe(config.copy(androidModel = AndroidModelOption.STABLE)) }
        } catch (e: TimeoutCancellationException) {
            "no answer within $selectionTimeoutMs ms"
        }
        if (outcome != null) log("auto: stable did not answer the debug probe ($outcome)")
    }

    /** Null when [config]'s model answered on-device with text; otherwise why not. */
    private suspend fun probe(config: HybridConfig): String? {
        val start = nanoTime()
        fun ms() = (nanoTime() - start) / 1_000_000
        return try {
            val result = inner.generate(config, probeRequest())
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
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            "${describe(e)} after ${ms()} ms"
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
        timeoutMs = selectionTimeoutMs,
    )

    private fun describe(e: Throwable): String {
        val mapped = ErrorMapping.classify(e)
        val notAvailable = if (ErrorMapping.isModelNotAvailable(e)) ", NOT_AVAILABLE" else ""
        return "${e.javaClass.simpleName}: ${mapped.code.wire}$notAvailable"
    }

    companion object {
        const val PROBE_PROMPT = "Reply with OK"
        const val PROBE_MAX_TOKENS = 4
        /** The whole startup selection, status lookup and probe together. */
        const val SELECTION_TIMEOUT_MS = 5_000L
        const val PROBE_REQUEST_ID = "auto-model-probe"
        const val PROBE_FEATURE = "auto_model_probe"
    }
}

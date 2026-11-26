package dev.soussight.ai_logic_hybrid

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.withTimeout

/**
 * Devices Google documents as running Gemini Nano 4, the model behind the `preview` option.
 * Source: ML Kit GenAI overview, "Gemini Nano 4" device list
 * (https://developers.google.com/ml-kit/genai), checked 2026-11-26. That page names devices by
 * marketing name. Only Google Pixel phones are listed here because their `Build.MODEL` is the
 * marketing name; other makers report model codes (e.g. Samsung `SM-S931B`) that the page does
 * not give, so they are left out rather than guessed. A device not listed uses `stable`.
 */
object NanoDeviceList {
    private val pixels = setOf(
        "Pixel 10", "Pixel 10 Pro", "Pixel 10 Pro XL", "Pixel 10 Pro Fold",
        "Pixel 11", "Pixel 11 Pro", "Pixel 11 Pro XL", "Pixel 11 Pro Fold",
    )

    fun supportsNano4(manufacturer: String?, model: String?): Boolean =
        manufacturer.equals("Google", ignoreCase = true) && model?.trim() in pixels
}

/** The model the plugin runs and why, as shown to the cook. */
data class ModelChoice(val option: AndroidModelOption, val reason: String)

/**
 * `androidModel = deviceList` (the default): decided once, at `configure`. A device on
 * [NanoDeviceList] gets one status check of `preview`, bounded by [timeoutMs]: `available`
 * means `preview`; anything else, an error or no answer in time means `stable`. A device off
 * the list uses `stable` with no check. No probe, no later switching.
 */
class DeviceListChooser(
    private val manufacturer: String?,
    private val model: String?,
    private val timeoutMs: Long = STATUS_TIMEOUT_MS,
    /** The status check runs here, never on the main thread. */
    private val work: CoroutineDispatcher = Dispatchers.IO,
) {
    private val device get() = "${manufacturer.orEmpty()} ${model.orEmpty()}".trim()

    /** [scope] owns the check (the plugin's lifetime); a late answer is discarded. */
    suspend fun choose(scope: CoroutineScope, engine: HybridEngine, config: HybridConfig): ModelChoice {
        if (!NanoDeviceList.supportsNano4(manufacturer, model)) {
            return ModelChoice(AndroidModelOption.STABLE, "not on the Gemini Nano 4 device list ($device) → stable")
        }
        val check = scope.async(work) {
            engine.availability(config.copy(androidModel = AndroidModelOption.PREVIEW), withImage = false)
        }
        val status = try {
            withTimeout(timeoutMs) { check.await() }.status
        } catch (e: TimeoutCancellationException) {
            null
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            null
        } finally {
            check.cancel()
        }
        return if (status == OnDeviceStatus.AVAILABLE) {
            ModelChoice(AndroidModelOption.PREVIEW, "device list: $model → preview")
        } else {
            val seen = status?.wire ?: "no answer"
            ModelChoice(AndroidModelOption.STABLE, "device list: $model, but preview is $seen → stable")
        }
    }

    companion object {
        const val STATUS_TIMEOUT_MS = 3_000L
    }
}

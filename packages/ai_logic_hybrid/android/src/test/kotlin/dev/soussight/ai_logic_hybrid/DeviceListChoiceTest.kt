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
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext

internal class DeviceListChoiceTest {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val config = HybridConfig("m", AndroidModelOption.DEVICE_LIST, listOf("en"))

    @AfterTest
    fun tearDown() = scope.cancel()

    private class StatusEngine(val status: suspend () -> AvailabilityResult) : HybridEngine {
        val asked = CopyOnWriteArrayList<AndroidModelOption>()
        override suspend fun availability(config: HybridConfig, withImage: Boolean): AvailabilityResult {
            asked += config.androidModel
            return status()
        }
        override fun prepare(config: HybridConfig, withImage: Boolean): Flow<Double?> = flowOf(1.0)
        override suspend fun generate(config: HybridConfig, request: GenerateRequest): GenerateResult =
            error("no generation during the choice")
    }

    private fun pixel10(timeoutMs: Long = 2_000) = DeviceListChooser("Google", "Pixel 10", timeoutMs)

    @Test
    fun theListNamesOnlyDocumentedNano4Pixels() {
        for (model in listOf("Pixel 10", "Pixel 10 Pro", "Pixel 10 Pro XL", "Pixel 10 Pro Fold", "Pixel 11", "Pixel 11 Pro Fold")) {
            assertTrue(NanoDeviceList.supportsNano4("Google", model), model)
        }
        assertTrue(NanoDeviceList.supportsNano4("google", " Pixel 10 "))
        for ((maker, model) in listOf("Google" to "Pixel 9", "Google" to "Pixel 9 Pro", "samsung" to "SM-S931B", "Other" to "Pixel 10", null to null)) {
            assertFalse(NanoDeviceList.supportsNano4(maker, model), "$maker $model")
        }
    }

    @Test
    fun onListAndAvailableMeansPreview() = runBlocking<Unit> {
        val engine = StatusEngine { AvailabilityResult(OnDeviceStatus.AVAILABLE) }
        val choice = pixel10().choose(scope, engine, config)
        assertEquals(ModelChoice(AndroidModelOption.PREVIEW, "device list: Pixel 10 → preview"), choice)
        assertEquals(listOf(AndroidModelOption.PREVIEW), engine.asked.toList(), "one preview status check")
    }

    @Test
    fun onListButNotAvailableMeansStable() = runBlocking<Unit> {
        for (status in listOf(OnDeviceStatus.DOWNLOADABLE, OnDeviceStatus.DOWNLOADING, OnDeviceStatus.UNAVAILABLE)) {
            val choice = pixel10().choose(scope, StatusEngine { AvailabilityResult(status) }, config)
            assertEquals(AndroidModelOption.STABLE, choice.option, "$status")
            assertEquals("device list: Pixel 10, but preview is ${status.wire} → stable", choice.reason)
        }
        val throws = pixel10().choose(scope, StatusEngine { error("AICore died") }, config)
        assertEquals(ModelChoice(AndroidModelOption.STABLE, "device list: Pixel 10, but preview is no answer → stable"), throws)
    }

    @Test
    fun onListButTheCheckTimesOutMeansStable() = runBlocking<Unit> {
        assertEquals(3_000L, DeviceListChooser.STATUS_TIMEOUT_MS)
        val release = CompletableDeferred<Unit>()
        // A native check that ignores cancellation, then would say available.
        val engine = StatusEngine {
            withContext(NonCancellable) { release.await() }
            AvailabilityResult(OnDeviceStatus.AVAILABLE)
        }
        val start = System.nanoTime()
        val choice = pixel10(timeoutMs = 50).choose(scope, engine, config)
        assertTrue((System.nanoTime() - start) / 1_000_000 < 2_000)
        assertEquals(AndroidModelOption.STABLE, choice.option)
        release.complete(Unit)
    }

    @Test
    fun offListMeansStableWithNoCheck() = runBlocking<Unit> {
        val engine = StatusEngine { AvailabilityResult(OnDeviceStatus.AVAILABLE) }
        val choice = DeviceListChooser("Google", "Pixel 9").choose(scope, engine, config)
        assertEquals(ModelChoice(AndroidModelOption.STABLE, "not on the Gemini Nano 4 device list (Google Pixel 9) → stable"), choice)
        assertTrue(engine.asked.isEmpty())
    }
}

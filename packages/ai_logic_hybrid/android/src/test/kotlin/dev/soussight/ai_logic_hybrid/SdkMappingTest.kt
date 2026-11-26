package dev.soussight.ai_logic_hybrid

import com.google.firebase.ai.InferenceMode
import com.google.firebase.ai.InferenceSource
import com.google.firebase.ai.OnDeviceModelOption
import com.google.firebase.ai.OnDeviceModelStatus
import com.google.firebase.ai.type.PublicPreviewAPI
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

@OptIn(PublicPreviewAPI::class)
internal class SdkMappingTest {
    @Test
    fun modesMapOneToOne() {
        assertEquals(InferenceMode.PREFER_ON_DEVICE, SdkMapping.mode(HybridMode.PREFER_ON_DEVICE))
        assertEquals(InferenceMode.ONLY_ON_DEVICE, SdkMapping.mode(HybridMode.ONLY_ON_DEVICE))
        assertEquals(InferenceMode.PREFER_IN_CLOUD, SdkMapping.mode(HybridMode.PREFER_IN_CLOUD))
        assertEquals(InferenceMode.ONLY_IN_CLOUD, SdkMapping.mode(HybridMode.ONLY_IN_CLOUD))
    }

    @Test
    fun modelOptions() {
        assertEquals(OnDeviceModelOption.PREVIEW, SdkMapping.option(AndroidModelOption.PREVIEW))
        assertEquals(OnDeviceModelOption.PREVIEW_FAST, SdkMapping.option(AndroidModelOption.PREVIEW_FAST))
        assertEquals(OnDeviceModelOption.STABLE, SdkMapping.option(AndroidModelOption.STABLE))
        // auto is resolved by AutoModelEngine; it never reaches the SDK.
        assertEquals(
            HybridErrorCode.FAILED,
            assertFailsWith<HybridError> { SdkMapping.option(AndroidModelOption.AUTO) }.code,
        )
    }

    @Test
    fun sourceComesFromTheSdkOrFails() {
        assertEquals(InferenceSourceWire.ON_DEVICE, SdkMapping.source(InferenceSource.ON_DEVICE))
        assertEquals(InferenceSourceWire.CLOUD, SdkMapping.source(InferenceSource.IN_CLOUD))
        assertEquals(HybridErrorCode.FAILED, assertFailsWith<HybridError> { SdkMapping.source(null) }.code)
    }

    @Test
    fun statuses() {
        assertEquals(OnDeviceStatus.AVAILABLE, SdkMapping.status(OnDeviceModelStatus.AVAILABLE))
        assertEquals(OnDeviceStatus.DOWNLOADABLE, SdkMapping.status(OnDeviceModelStatus.DOWNLOADABLE))
        assertEquals(OnDeviceStatus.DOWNLOADING, SdkMapping.status(OnDeviceModelStatus.DOWNLOADING))
        assertEquals(OnDeviceStatus.UNAVAILABLE, SdkMapping.status(OnDeviceModelStatus.UNAVAILABLE))
    }

    @Test
    fun downloadProgressFractions() {
        val p = DownloadProgress()
        assertEquals(0.0, p.fraction(DownloadEvent.Started(200)))
        assertEquals(0.5, p.fraction(DownloadEvent.Progress(100)))
        assertEquals(1.0, p.fraction(DownloadEvent.Progress(500)))
        assertEquals(1.0, p.fraction(DownloadEvent.Completed))
        val unknown = DownloadProgress()
        assertEquals(null, unknown.fraction(DownloadEvent.Progress(10)))
        assertEquals(null, unknown.fraction(DownloadEvent.Started(0)))
        val e = assertFailsWith<HybridError> {
            unknown.fraction(DownloadEvent.Failed(RuntimeException(com.google.mlkit.genai.common.GenAiException("disk", null, 501))))
        }
        assertEquals(HybridErrorCode.UNAVAILABLE, e.code)
    }
}

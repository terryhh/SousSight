package dev.soussight.ai_logic_hybrid

import com.google.firebase.ai.type.FirebaseAIOnDeviceNotAvailableException
import com.google.firebase.ai.type.PublicPreviewAPI
import com.google.firebase.ai.type.QuotaExceededException
import com.google.firebase.ai.type.ServerException
import com.google.mlkit.genai.common.GenAiException
import java.net.UnknownHostException
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertSame
import kotlin.test.assertTrue
import com.google.firebase.ai.ondevice.interop.FirebaseAIOnDeviceNotAvailableException as InteropNotAvailable

@OptIn(PublicPreviewAPI::class)
internal class ErrorMappingTest {
    private fun genAi(code: Int) = GenAiException("ml kit $code", null, code)

    // The SDK's exception constructors are Kotlin-internal; build them the way the SDK does.
    private inline fun <reified T : Throwable> sdk(message: String): T =
        T::class.java.getDeclaredConstructor(String::class.java, Throwable::class.java)
            .newInstance(message, null)

    @Test
    fun mlKitCodes() {
        val expected = mapOf(
            GenAiException.ErrorCode.BUSY to HybridErrorCode.BUSY,
            GenAiException.ErrorCode.PER_APP_BATTERY_USE_QUOTA_EXCEEDED to HybridErrorCode.QUOTA,
            GenAiException.ErrorCode.BACKGROUND_USE_BLOCKED to HybridErrorCode.BLOCKED,
            GenAiException.ErrorCode.CANCELLED to HybridErrorCode.CANCELLED,
            GenAiException.ErrorCode.NOT_AVAILABLE to HybridErrorCode.UNAVAILABLE,
            GenAiException.ErrorCode.NEEDS_SYSTEM_UPDATE to HybridErrorCode.UNAVAILABLE,
            GenAiException.ErrorCode.AICORE_INCOMPATIBLE to HybridErrorCode.UNAVAILABLE,
            GenAiException.ErrorCode.NOT_ENOUGH_DISK_SPACE to HybridErrorCode.UNAVAILABLE,
            GenAiException.ErrorCode.REQUEST_TOO_LARGE to HybridErrorCode.UNSUPPORTED_INPUT,
            GenAiException.ErrorCode.INVALID_INPUT_IMAGE to HybridErrorCode.UNSUPPORTED_INPUT,
            GenAiException.ErrorCode.UNKNOWN to HybridErrorCode.FAILED,
            GenAiException.ErrorCode.RESPONSE_GENERATION_ERROR to HybridErrorCode.FAILED,
        )
        for ((code, wire) in expected) assertEquals(wire, ErrorMapping.genAiCode(code), "code $code")
        // Spot-check the raw values against ML Kit genai-common 1.0.0-beta5.
        assertEquals(9, GenAiException.ErrorCode.BUSY)
        assertEquals(27, GenAiException.ErrorCode.PER_APP_BATTERY_USE_QUOTA_EXCEEDED)
        assertEquals(30, GenAiException.ErrorCode.BACKGROUND_USE_BLOCKED)
    }

    @Test
    fun findsTheMlKitCauseUnderSdkWrappers() {
        // firebase-ai-ondevice wraps BUSY etc. in an "unknown" on-device exception.
        val wrapped = RuntimeException("Unknown on-device exception", RuntimeException("x", genAi(GenAiException.ErrorCode.BUSY)))
        assertEquals(HybridErrorCode.BUSY, ErrorMapping.classify(wrapped).code)
        val quota = RuntimeException(genAi(GenAiException.ErrorCode.PER_APP_BATTERY_USE_QUOTA_EXCEEDED))
        assertEquals(HybridErrorCode.QUOTA, ErrorMapping.classify(quota).code)
    }

    @Test
    fun cloudErrors() {
        assertEquals(HybridErrorCode.QUOTA, ErrorMapping.classify(sdk<QuotaExceededException>("quota exceeded")).code)
        assertEquals(
            HybridErrorCode.ATTESTATION,
            ErrorMapping.classify(sdk<ServerException>("Firebase App Check token is invalid.")).code,
        )
        assertEquals(HybridErrorCode.BUSY, ErrorMapping.classify(sdk<ServerException>("The model is overloaded.")).code)
        assertEquals(HybridErrorCode.FAILED, ErrorMapping.classify(sdk<ServerException>("Internal error")).code)
        assertEquals(
            HybridErrorCode.NETWORK,
            ErrorMapping.classify(RuntimeException("Something unexpected happened.", UnknownHostException("x"))).code,
        )
        assertEquals(HybridErrorCode.FAILED, ErrorMapping.classify(IllegalStateException("?")).code)
    }

    @Test
    fun hybridErrorsPassThrough() {
        val e = HybridError(HybridErrorCode.UNSUPPORTED_INPUT, "no")
        assertSame(e, ErrorMapping.classify(e))
    }

    @Test
    fun statusReasons() {
        assertEquals(
            Reasons.NEEDS_SYSTEM_UPDATE,
            ErrorMapping.statusReason(genAi(GenAiException.ErrorCode.NEEDS_SYSTEM_UPDATE)),
        )
        assertEquals(
            Reasons.DEVICE_NOT_ELIGIBLE,
            ErrorMapping.statusReason(RuntimeException(genAi(GenAiException.ErrorCode.AICORE_INCOMPATIBLE))),
        )
        assertEquals(Reasons.MODEL_NOT_READY, ErrorMapping.statusReason(IllegalStateException()))
    }

    @Test
    fun modelNotAvailableIsMlKitCode8OrTheTypedSdkException() {
        assertEquals(8, GenAiException.ErrorCode.NOT_AVAILABLE)
        // What firebase-ai 18.2.0 throws for ML Kit code 8 (the Pixel 9 Nano 4 preview failure):
        // typed exception -> interop exception -> GenAiException(8).
        val sdkChain = FirebaseAIOnDeviceNotAvailableException(
            InteropNotAvailable("Feature 652 not found", genAi(GenAiException.ErrorCode.NOT_AVAILABLE)),
        )
        assertTrue(ErrorMapping.isModelNotAvailable(sdkChain))
        assertEquals(HybridErrorCode.UNAVAILABLE, ErrorMapping.classify(sdkChain).code)
        assertTrue(ErrorMapping.isModelNotAvailable(RuntimeException(genAi(GenAiException.ErrorCode.NOT_AVAILABLE))))
        // The typed exception alone (codes 604 / -101 map to it too).
        assertTrue(
            ErrorMapping.isModelNotAvailable(FirebaseAIOnDeviceNotAvailableException(InteropNotAvailable("x", null))),
        )
        assertFalse(ErrorMapping.isModelNotAvailable(genAi(GenAiException.ErrorCode.BUSY)))
        assertFalse(ErrorMapping.isModelNotAvailable(genAi(GenAiException.ErrorCode.NEEDS_SYSTEM_UPDATE)))
        assertFalse(ErrorMapping.isModelNotAvailable(HybridError(HybridErrorCode.UNAVAILABLE, Reasons.MODEL_NOT_READY)))
        assertFalse(ErrorMapping.isModelNotAvailable(IllegalStateException("?")))
    }
}

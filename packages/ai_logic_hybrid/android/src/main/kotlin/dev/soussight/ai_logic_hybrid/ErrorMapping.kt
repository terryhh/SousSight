package dev.soussight.ai_logic_hybrid

import com.google.firebase.ai.type.ContentBlockedException
import com.google.firebase.ai.type.FirebaseAIException
import com.google.firebase.ai.type.FirebaseAIOnDeviceInvalidRequestException
import com.google.firebase.ai.type.FirebaseAIOnDeviceNotAvailableException
import com.google.firebase.ai.type.PromptBlockedException
import com.google.firebase.ai.type.PublicPreviewAPI
import com.google.firebase.ai.type.QuotaExceededException
import com.google.firebase.ai.type.RequestTimeoutException
import com.google.firebase.ai.type.UnsupportedUserLocationException
import com.google.mlkit.genai.common.GenAiException
import java.io.IOException

/**
 * SDK failures to [HybridErrorCode]s.
 *
 * firebase-ai-ondevice 16.0.0-beta08 maps only some ML Kit codes to typed exceptions; BUSY,
 * PER_APP_BATTERY_USE_QUOTA_EXCEEDED, BACKGROUND_USE_BLOCKED and CANCELLED arrive as an
 * "unknown" on-device exception whose cause is the ML Kit [GenAiException]. So the cause chain
 * is searched for that first.
 */
object ErrorMapping {
    fun classify(t: Throwable): HybridError {
        if (t is HybridError) return t
        val chain = causeChain(t)
        val message = t.message ?: t.javaClass.simpleName

        chain.firstOrNull { it is GenAiException }?.let {
            val code = genAiCode((it as GenAiException).errorCode)
            return HybridError(code, it.message ?: message, t)
        }
        for (e in chain) {
            sdkCode(e)?.let { return HybridError(it, e.message ?: message, t) }
        }
        if (chain.any { it is IOException }) return HybridError(HybridErrorCode.NETWORK, message, t)
        return HybridError(HybridErrorCode.FAILED, message, t)
    }

    /** ML Kit GenAI error codes (GenAiException.ErrorCode, genai-common 1.0.0-beta5). */
    fun genAiCode(code: Int): HybridErrorCode = when (code) {
        GenAiException.ErrorCode.BUSY -> HybridErrorCode.BUSY
        GenAiException.ErrorCode.PER_APP_BATTERY_USE_QUOTA_EXCEEDED -> HybridErrorCode.QUOTA
        GenAiException.ErrorCode.BACKGROUND_USE_BLOCKED -> HybridErrorCode.BLOCKED
        GenAiException.ErrorCode.CANCELLED -> HybridErrorCode.CANCELLED
        GenAiException.ErrorCode.NOT_AVAILABLE,
        GenAiException.ErrorCode.NEEDS_SYSTEM_UPDATE,
        GenAiException.ErrorCode.AICORE_INCOMPATIBLE,
        GenAiException.ErrorCode.NOT_ENOUGH_DISK_SPACE -> HybridErrorCode.UNAVAILABLE
        GenAiException.ErrorCode.REQUEST_TOO_LARGE,
        GenAiException.ErrorCode.REQUEST_TOO_SMALL,
        GenAiException.ErrorCode.INVALID_INPUT_IMAGE,
        GenAiException.ErrorCode.NOT_SUPPORTED -> HybridErrorCode.UNSUPPORTED_INPUT
        else -> HybridErrorCode.FAILED
    }

    /**
     * True when the on-device model said it cannot run at all: ML Kit `NOT_AVAILABLE` (8) anywhere
     * in the cause chain, or the SDK's typed not-available exception (firebase-ai-ondevice beta08
     * maps ML Kit codes 8, 604 and -101 to it, keeping the GenAiException as the cause). On the
     * Pixel 9 every Nano 4 preview generate fails this way although its status is `available`.
     */
    @OptIn(PublicPreviewAPI::class)
    fun isModelNotAvailable(t: Throwable): Boolean = causeChain(t).any {
        (it is GenAiException && it.errorCode == GenAiException.ErrorCode.NOT_AVAILABLE) ||
            it is FirebaseAIOnDeviceNotAvailableException
    }

    /** `reason` for an availability check that threw instead of returning a status. */
    fun statusReason(t: Throwable): String {
        val genAi = causeChain(t).firstOrNull { it is GenAiException } as GenAiException?
        return when (genAi?.errorCode) {
            GenAiException.ErrorCode.NEEDS_SYSTEM_UPDATE -> Reasons.NEEDS_SYSTEM_UPDATE
            GenAiException.ErrorCode.AICORE_INCOMPATIBLE,
            GenAiException.ErrorCode.NOT_SUPPORTED -> Reasons.DEVICE_NOT_ELIGIBLE
            else -> Reasons.MODEL_NOT_READY
        }
    }

    @OptIn(PublicPreviewAPI::class)
    private fun sdkCode(e: Throwable): HybridErrorCode? = when (e) {
        is QuotaExceededException -> HybridErrorCode.QUOTA
        is PromptBlockedException,
        is ContentBlockedException,
        is UnsupportedUserLocationException -> HybridErrorCode.BLOCKED
        is RequestTimeoutException -> HybridErrorCode.TIMEOUT
        is FirebaseAIOnDeviceNotAvailableException -> HybridErrorCode.UNAVAILABLE
        is FirebaseAIOnDeviceInvalidRequestException -> HybridErrorCode.UNSUPPORTED_INPUT
        is FirebaseAIException -> serverMessageCode(e.message)
        else -> null
    }

    /** The SDK reports backend errors as text (ServerException); match the stable phrases. */
    internal fun serverMessageCode(message: String?): HybridErrorCode? {
        val m = message?.lowercase() ?: return null
        return when {
            "app check" in m || "appcheck" in m || "app_check" in m -> HybridErrorCode.ATTESTATION
            "overloaded" in m -> HybridErrorCode.BUSY
            else -> null
        }
    }

    private fun causeChain(t: Throwable): List<Throwable> {
        val seen = mutableListOf<Throwable>()
        var cur: Throwable? = t
        while (cur != null && seen.none { it === cur } && seen.size < 12) {
            seen += cur
            cur = cur.cause
        }
        return seen
    }
}

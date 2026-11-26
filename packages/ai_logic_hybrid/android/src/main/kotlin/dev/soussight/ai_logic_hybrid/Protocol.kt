package dev.soussight.ai_logic_hybrid

// The channel protocol in docs/buildhybridai/DESIGN.md §4 ("Wire format"). Enum values travel as
// their Dart names. Must match MethodChannelHybridInference and contract.dart on the Dart side.
// Nothing in this file touches Android or the Firebase SDK, so it runs in JVM unit tests.

enum class HybridMode(val wire: String) {
    PREFER_ON_DEVICE("preferOnDevice"),
    ONLY_ON_DEVICE("onlyOnDevice"),
    PREFER_IN_CLOUD("preferInCloud"),
    ONLY_IN_CLOUD("onlyInCloud");

    companion object {
        fun fromWire(value: Any?): HybridMode =
            entries.firstOrNull { it.wire == value }
                ?: throw HybridError(HybridErrorCode.UNSUPPORTED_MODE, "Unknown mode: $value")
    }
}

enum class AndroidModelOption(val wire: String) {
    PREVIEW("preview"),
    PREVIEW_FAST("previewFast"),
    STABLE("stable");

    companion object {
        fun fromWire(value: Any?): AndroidModelOption =
            entries.firstOrNull { it.wire == value }
                ?: throw HybridError(HybridErrorCode.FAILED, "Unknown androidModel: $value")
    }
}

enum class OnDeviceStatus(val wire: String) {
    AVAILABLE("available"),
    DOWNLOADABLE("downloadable"),
    DOWNLOADING("downloading"),
    UNAVAILABLE("unavailable"),
}

enum class InferenceSourceWire(val wire: String) {
    ON_DEVICE("onDevice"),
    CLOUD("cloud"),
}

enum class HybridErrorCode(val wire: String) {
    UNAVAILABLE("unavailable"),
    UNSUPPORTED_INPUT("unsupportedInput"),
    UNSUPPORTED_MODE("unsupportedMode"),
    BUSY("busy"),
    QUOTA("quota"),
    BLOCKED("blocked"),
    NETWORK("network"),
    ATTESTATION("attestation"),
    TIMEOUT("timeout"),
    CANCELLED("cancelled"),
    FAILED("failed"),
}

/** Travels to Dart as a PlatformException whose `code` is [code]'s wire name. */
class HybridError(val code: HybridErrorCode, message: String, cause: Throwable? = null) :
    Exception(message, cause)

/** Stable `reason` codes the app maps to cook-facing text (lib/trust/). */
object Reasons {
    const val BRIDGE_UNAVAILABLE = "bridge_unavailable"
    const val NOT_CONFIGURED = "not_configured"
    const val DEVICE_NOT_ELIGIBLE = "device_not_eligible"
    const val NOT_ENROLLED = "not_enrolled"
    const val MODEL_NOT_READY = "model_not_ready"
    const val NEEDS_SYSTEM_UPDATE = "needs_system_update"
}

data class HybridConfig(
    val cloudModel: String,
    val androidModel: AndroidModelOption,
    val languages: List<String>,
)

sealed class HybridPart {
    data class Text(val text: String) : HybridPart()

    class InlineData(val bytes: ByteArray, val mimeType: String) : HybridPart() {
        val isImage: Boolean get() = mimeType.startsWith("image/")
        val isAudio: Boolean get() = mimeType.startsWith("audio/")
    }
}

data class GenerateRequest(
    val requestId: String,
    val mode: HybridMode,
    val feature: String,
    val systemInstruction: String?,
    val parts: List<HybridPart>,
    val jsonSchema: Map<String, Any?>?,
    val maxOutputTokens: Int,
    val timeoutMs: Long,
) {
    val images: List<HybridPart.InlineData>
        get() = parts.filterIsInstance<HybridPart.InlineData>().filter { it.isImage }
}

data class AvailabilityResult(
    val status: OnDeviceStatus,
    val reason: String? = null,
    val modelLabel: String? = null,
    /** The concrete option this answer is about (what `auto` chose); null if none was checked. */
    val modelOption: AndroidModelOption? = null,
)

data class GenerateResult(
    val text: String,
    val source: InferenceSourceWire,
    /** Name the SDK reported for the model that answered; never the requested option. */
    val modelLabel: String?,
)

object Protocol {
    const val METHOD_CHANNEL = "dev.soussight/ai_logic_hybrid"
    const val PREPARE_CHANNEL = "dev.soussight/ai_logic_hybrid/prepare"

    fun parseConfig(args: Any?): HybridConfig {
        val m = args.asMap("configure")
        val cloudModel = m["cloudModel"] as? String
        if (cloudModel.isNullOrBlank()) bad("configure: cloudModel is required")
        val languages = (m["languages"] as? List<*>)?.map {
            it as? String ?: bad("configure: languages must be strings")
        } ?: listOf("en")
        return HybridConfig(
            cloudModel = cloudModel,
            // Default: the device's supported (stable) Gemini Nano; preview is an explicit opt-in.
            androidModel = AndroidModelOption.fromWire(m["androidModel"] ?: AndroidModelOption.STABLE.wire),
            languages = languages,
        )
    }

    fun parseWithImage(args: Any?): Boolean =
        (args as? Map<*, *>)?.get("withImage") as? Boolean ?: false

    fun parseRequestId(args: Any?): String? = (args as? Map<*, *>)?.get("requestId") as? String

    fun parseGenerate(args: Any?): GenerateRequest {
        val m = args.asMap("generate")
        val requestId = m["requestId"] as? String
        if (requestId.isNullOrEmpty()) bad("generate: requestId is required")
        val mode = HybridMode.fromWire(m["mode"])
        val feature = m["feature"] as? String ?: bad("generate: feature is required")
        val systemInstruction = m["systemInstruction"]?.let {
            it as? String ?: bad("generate: systemInstruction must be a string")
        }
        val rawParts = m["parts"] as? List<*> ?: bad("generate: parts is required")
        val parts = rawParts.map(::parsePart)
        @Suppress("UNCHECKED_CAST")
        val schema = m["jsonSchema"]?.let {
            (it as? Map<*, *>)?.takeIf { s -> s.keys.all { k -> k is String } }
                as Map<String, Any?>? ?: bad("generate: jsonSchema must be a map")
        }
        // Range-checked before narrowing: a Long such as 2^32 + 1 must not become 1.
        val rawMax = m["maxOutputTokens"] ?: bad("generate: maxOutputTokens is required")
        if (rawMax !is Int && rawMax !is Long) bad("generate: maxOutputTokens must be an integer")
        val wideMax = (rawMax as Number).toLong()
        if (wideMax !in 1..Int.MAX_VALUE.toLong()) bad("generate: maxOutputTokens must be between 1 and ${Int.MAX_VALUE}")
        val maxOutputTokens = wideMax.toInt()
        val timeoutMs = (m["timeoutMs"] as? Number)?.toLong()
            ?: bad("generate: timeoutMs is required")
        if (timeoutMs <= 0) bad("generate: timeoutMs must be positive")
        return GenerateRequest(
            requestId = requestId,
            mode = mode,
            feature = feature,
            systemInstruction = systemInstruction,
            parts = parts,
            jsonSchema = schema,
            maxOutputTokens = maxOutputTokens,
            timeoutMs = timeoutMs,
        )
    }

    private fun parsePart(raw: Any?): HybridPart {
        val p = raw as? Map<*, *> ?: bad("generate: each part must be a map")
        return when (p["type"]) {
            "text" -> HybridPart.Text(p["text"] as? String ?: bad("generate: text part needs text"))
            "inlineData" -> HybridPart.InlineData(
                bytes = p["bytes"] as? ByteArray ?: bad("generate: inlineData needs bytes"),
                mimeType = p["mimeType"] as? String ?: bad("generate: inlineData needs mimeType"),
            )
            else -> throw HybridError(
                HybridErrorCode.UNSUPPORTED_INPUT,
                "Unknown part type: ${p["type"]}",
            )
        }
    }

    /**
     * DESIGN §4 capabilities for Gemini Nano through AICore. Limits are Docs-level. [modelOption]
     * is the configured option in use, or null before `configure`.
     */
    fun capabilities(modelOption: AndroidModelOption? = null): Map<String, Any?> = mapOf(
        "platform" to "android",
        "local" to mapOf(
            "modelFamily" to "Gemini Nano",
            "modelOption" to modelOption?.wire,
            "supportsImage" to true,
            // The SDK sends a manual schema only to the cloud model; on-device structured output
            // needs a compile-time @Generable class. Local runs get the schema in the prompt and
            // the caller validates (as on iOS).
            "supportsJsonSchema" to false,
            "maxTotalTokens" to InputRules.LOCAL_MAX_TOTAL_TOKENS,
            "defaultOutputReserve" to InputRules.DEFAULT_OUTPUT_RESERVE,
            "imageTokenEstimate" to InputRules.IMAGE_TOKEN_ESTIMATE,
            "validatedLanguages" to listOf("en", "ko"),
        ),
        "maxImages" to InputRules.MAX_IMAGES,
        "maxImageBytes" to InputRules.MAX_IMAGE_BYTES,
        "maxImageDimension" to InputRules.MAX_IMAGE_DIMENSION,
        "supportedModes" to HybridMode.entries.map { it.wire },
    )

    fun availabilityMap(a: AvailabilityResult): Map<String, Any?> = mapOf(
        "status" to a.status.wire,
        "reason" to a.reason,
        "modelLabel" to a.modelLabel,
        "modelOption" to a.modelOption?.wire,
    )

    fun resultMap(requestId: String, r: GenerateResult): Map<String, Any?> = mapOf(
        "requestId" to requestId,
        "text" to r.text,
        "source" to r.source.wire,
        "modelLabel" to r.modelLabel,
    )

    fun fractionEvent(fraction: Double?): Map<String, Any?> = mapOf("fraction" to fraction)

    private fun Any?.asMap(method: String): Map<*, *> =
        this as? Map<*, *> ?: bad("$method: arguments must be a map")

    private fun bad(message: String): Nothing = throw HybridError(HybridErrorCode.FAILED, message)
}

/** Attachment limits (every route) and the local token budget (local runs only), DESIGN §4. */
object InputRules {
    const val MAX_IMAGES = 1
    const val MAX_IMAGE_BYTES = 1024 * 1024
    const val MAX_IMAGE_DIMENSION = 768
    const val LOCAL_MAX_TOTAL_TOKENS = 4000
    const val DEFAULT_OUTPUT_RESERVE = 256
    const val IMAGE_TOKEN_ESTIMATE = 1000

    /** Checks that need no decoding. Throws `unsupportedInput` before any SDK call. */
    fun validate(request: GenerateRequest) {
        if (request.parts.isEmpty()) unsupported("No parts")
        val inline = request.parts.filterIsInstance<HybridPart.InlineData>()
        for (part in inline) {
            when {
                part.isImage -> if (part.bytes.size > MAX_IMAGE_BYTES) {
                    unsupported("Image is ${part.bytes.size} bytes; the limit is $MAX_IMAGE_BYTES")
                }
                part.isAudio -> if (request.mode != HybridMode.ONLY_IN_CLOUD) {
                    // The on-device model takes text and one Bitmap only; a mode that may run
                    // locally cannot carry audio.
                    unsupported("Audio is only accepted with onlyInCloud")
                }
                else -> unsupported("Unsupported attachment type ${part.mimeType}")
            }
        }
        if (request.images.size > MAX_IMAGES) {
            unsupported("At most $MAX_IMAGES image per request")
        }
        if (request.mode == HybridMode.ONLY_ON_DEVICE) {
            val estimate = estimateLocalTokens(request)
            if (estimate > LOCAL_MAX_TOTAL_TOKENS) {
                unsupported("Local budget: about $estimate tokens; the limit is $LOCAL_MAX_TOTAL_TOKENS")
            }
        }
    }

    fun checkDimensions(width: Int, height: Int) {
        if (width <= 0 || height <= 0) unsupported("Image could not be decoded")
        if (width > MAX_IMAGE_DIMENSION || height > MAX_IMAGE_DIMENSION) {
            unsupported("Image is ${width}x$height; the limit is $MAX_IMAGE_DIMENSION px")
        }
    }

    /** Same formula as the Dart policy's estimateLocalTokens (DESIGN §4). */
    fun estimateLocalTokens(request: GenerateRequest): Long {
        // Long: a huge maxOutputTokens must not wrap negative and pass the budget.
        var chars = (request.systemInstruction?.length ?: 0).toLong()
        for (part in request.parts) if (part is HybridPart.Text) chars += part.text.length
        request.jsonSchema?.let { chars += JsonText.encode(it).length }
        val textTokens = (chars + 3) / 4
        return textTokens + request.images.size.toLong() * IMAGE_TOKEN_ESTIMATE + request.maxOutputTokens
    }

    private fun unsupported(message: String): Nothing =
        throw HybridError(HybridErrorCode.UNSUPPORTED_INPUT, message)
}

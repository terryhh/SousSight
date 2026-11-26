package dev.soussight.ai_logic_hybrid

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import com.google.firebase.Firebase
import com.google.firebase.ai.DownloadStatus
import com.google.firebase.ai.FirebaseAI
import com.google.firebase.ai.GenerativeModel
import com.google.firebase.ai.InferenceMode
import com.google.firebase.ai.InferenceSource
import com.google.firebase.ai.OnDeviceConfig
import com.google.firebase.ai.OnDeviceExtension
import com.google.firebase.ai.OnDeviceModelOption
import com.google.firebase.ai.OnDeviceModelStatus
import com.google.firebase.ai.ai
import com.google.firebase.ai.type.GenerationConfig
import com.google.firebase.ai.type.GenerativeBackend
import com.google.firebase.ai.type.PublicPreviewAPI
import com.google.firebase.ai.type.content
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow

/** Mappings between the wire enums and Firebase AI Logic's types (DESIGN §4 mode table). */
@OptIn(PublicPreviewAPI::class)
object SdkMapping {
    fun mode(mode: HybridMode): InferenceMode = when (mode) {
        HybridMode.PREFER_ON_DEVICE -> InferenceMode.PREFER_ON_DEVICE
        HybridMode.ONLY_ON_DEVICE -> InferenceMode.ONLY_ON_DEVICE
        HybridMode.PREFER_IN_CLOUD -> InferenceMode.PREFER_IN_CLOUD
        HybridMode.ONLY_IN_CLOUD -> InferenceMode.ONLY_IN_CLOUD
    }

    fun option(option: AndroidModelOption): OnDeviceModelOption = when (option) {
        AndroidModelOption.PREVIEW -> OnDeviceModelOption.PREVIEW
        AndroidModelOption.PREVIEW_FAST -> OnDeviceModelOption.PREVIEW_FAST
        AndroidModelOption.STABLE -> OnDeviceModelOption.STABLE
        // AutoModelEngine resolves `auto` before any engine call; reaching the SDK with it is a bug.
        AndroidModelOption.AUTO ->
            throw HybridError(HybridErrorCode.FAILED, "androidModel auto must be resolved first")
    }

    /** The SDK's own report. Anything else is not inferred: the call fails. */
    fun source(source: InferenceSource?): InferenceSourceWire = when (source) {
        InferenceSource.ON_DEVICE -> InferenceSourceWire.ON_DEVICE
        InferenceSource.IN_CLOUD -> InferenceSourceWire.CLOUD
        else -> throw HybridError(HybridErrorCode.FAILED, "SDK reported no inference source")
    }

    fun status(status: OnDeviceModelStatus): OnDeviceStatus = when (status) {
        OnDeviceModelStatus.AVAILABLE -> OnDeviceStatus.AVAILABLE
        OnDeviceModelStatus.DOWNLOADABLE -> OnDeviceStatus.DOWNLOADABLE
        OnDeviceModelStatus.DOWNLOADING -> OnDeviceStatus.DOWNLOADING
        else -> OnDeviceStatus.UNAVAILABLE
    }

    fun download(status: DownloadStatus): DownloadEvent = when (status) {
        is DownloadStatus.DownloadStarted -> DownloadEvent.Started(status.bytesToDownload)
        is DownloadStatus.DownloadInProgress -> DownloadEvent.Progress(status.totalBytesDownloaded)
        is DownloadStatus.DownloadCompleted -> DownloadEvent.Completed
        is DownloadStatus.DownloadFailed -> DownloadEvent.Failed(status.exception)
        else -> DownloadEvent.Failed(IllegalStateException("Unknown download status"))
    }
}

/** Decodes attachments; an interface so tests never need android.graphics. */
interface ImageCodec {
    /** (width, height), or null when the bytes are not a decodable image. */
    fun bounds(bytes: ByteArray): Pair<Int, Int>?
    fun decode(bytes: ByteArray): Bitmap?
}

object AndroidImageCodec : ImageCodec {
    override fun bounds(bytes: ByteArray): Pair<Int, Int>? {
        val o = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, o)
        return if (o.outWidth > 0 && o.outHeight > 0) o.outWidth to o.outHeight else null
    }

    override fun decode(bytes: ByteArray): Bitmap? = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
}

/**
 * Firebase AI Logic hybrid inference (`firebase-ai` + `firebase-ai-ondevice`), Gemini Developer
 * API backend. Model instances carry mode, system instruction and generation config, so one is
 * built per request; nothing is reused across a different configuration.
 *
 * Verified in firebase-ai 18.2.0 sources: ONLY_ON_DEVICE builds only the on-device provider (no
 * cloud client exists on that model); PREFER_ON_DEVICE falls back to cloud on any on-device
 * FirebaseAI exception; PREFER_IN_CLOUD uses on-device only when the network check fails. The
 * on-device provider ignores `generationConfig` (schema, MIME type, maxOutputTokens) and reads
 * OnDeviceConfig.maxOutputTokens instead.
 */
@OptIn(PublicPreviewAPI::class)
class FirebaseHybridEngine(
    private val codec: ImageCodec = AndroidImageCodec,
    private val ai: () -> FirebaseAI = { Firebase.ai(backend = GenerativeBackend.googleAI()) },
) : HybridEngine {

    private var statusModelKey: Pair<String, AndroidModelOption>? = null
    private var statusModel: GenerativeModel? = null

    override suspend fun availability(config: HybridConfig, withImage: Boolean): AvailabilityResult {
        // Gemini Nano through AICore takes text and one Bitmap; neither the SDK nor ML Kit
        // exposes a separate image capability, so image availability is text availability.
        val ext = extension(config) ?: return AvailabilityResult(
            OnDeviceStatus.UNAVAILABLE, Reasons.BRIDGE_UNAVAILABLE,
        )
        val status = try {
            SdkMapping.status(ext.checkStatus())
        } catch (e: Exception) {
            return AvailabilityResult(OnDeviceStatus.UNAVAILABLE, ErrorMapping.statusReason(e))
        }
        return when (status) {
            OnDeviceStatus.AVAILABLE -> AvailabilityResult(status, modelLabel = modelName(ext))
            OnDeviceStatus.DOWNLOADABLE, OnDeviceStatus.DOWNLOADING ->
                AvailabilityResult(status, Reasons.MODEL_NOT_READY)
            OnDeviceStatus.UNAVAILABLE ->
                AvailabilityResult(status, unavailableReason(config))
        }
    }

    /**
     * Preview models need the AICore Developer Preview (Docs). If the STABLE model is usable or
     * obtainable while the preview one is unavailable, the device is eligible and the likely cause
     * is enrolment; otherwise the device is not eligible.
     */
    private suspend fun unavailableReason(config: HybridConfig): String {
        if (config.androidModel == AndroidModelOption.STABLE) return Reasons.DEVICE_NOT_ELIGIBLE
        val stable = extension(config.copy(androidModel = AndroidModelOption.STABLE), cache = false)
            ?: return Reasons.DEVICE_NOT_ELIGIBLE
        val stableStatus = try {
            SdkMapping.status(stable.checkStatus())
        } catch (e: Exception) {
            return ErrorMapping.statusReason(e)
        }
        return if (stableStatus == OnDeviceStatus.UNAVAILABLE) Reasons.DEVICE_NOT_ELIGIBLE
        else Reasons.NOT_ENROLLED
    }

    override fun prepare(config: HybridConfig, withImage: Boolean): Flow<Double?> = flow {
        val ext = extension(config)
            ?: throw HybridError(HybridErrorCode.UNAVAILABLE, Reasons.BRIDGE_UNAVAILABLE)
        when (SdkMapping.status(ext.checkStatus())) {
            OnDeviceStatus.AVAILABLE -> {
                emit(1.0)
                return@flow
            }
            OnDeviceStatus.UNAVAILABLE ->
                throw HybridError(HybridErrorCode.UNAVAILABLE, unavailableReason(config))
            OnDeviceStatus.DOWNLOADABLE, OnDeviceStatus.DOWNLOADING -> Unit
        }
        val progress = DownloadProgress()
        var completed = false
        ext.download().collect { status ->
            val event = SdkMapping.download(status)
            emit(progress.fraction(event))
            if (event == DownloadEvent.Completed) completed = true
        }
        if (!completed && SdkMapping.status(ext.checkStatus()) != OnDeviceStatus.AVAILABLE) {
            throw HybridError(HybridErrorCode.FAILED, "Download ended before the model was ready")
        }
    }

    override suspend fun generate(config: HybridConfig, request: GenerateRequest): GenerateResult {
        // Every input check comes before any SDK call: rules, schema, then each image's size and
        // a full decode (once; the bitmap is reused below).
        InputRules.validate(request)
        val schema = request.jsonSchema
        // Converted for every mode so an unsupported schema fails the same way everywhere; only
        // the cloud provider reads it (the on-device provider ignores generationConfig).
        val cloudSchema = schema?.let { SchemaMapping.toSchema(it) }
        val maySendLocally = request.mode != HybridMode.ONLY_IN_CLOUD
        val bitmaps = request.images.associateWith { part ->
            val (w, h) = codec.bounds(part.bytes)
                ?: throw HybridError(HybridErrorCode.UNSUPPORTED_INPUT, "Image could not be decoded")
            InputRules.checkDimensions(w, h)
            // The on-device provider accepts only TextPart and ImagePart(Bitmap).
            if (maySendLocally) {
                codec.decode(part.bytes)
                    ?: throw HybridError(HybridErrorCode.UNSUPPORTED_INPUT, "Image could not be decoded")
            } else {
                null
            }
        }
        val prompt = content {
            for (part in request.parts) {
                when (part) {
                    is HybridPart.Text -> text(part.text)
                    is HybridPart.InlineData -> if (part.isImage) {
                        bitmaps[part]?.let { image(it) } ?: inlineData(part.bytes, part.mimeType)
                    } else {
                        inlineData(part.bytes, part.mimeType) // audio: onlyInCloud (validated)
                    }
                }
            }
            if (schema != null && maySendLocally) text(SchemaMapping.localInstruction(schema))
        }

        val generationConfig = GenerationConfig.Builder().apply {
            maxOutputTokens = request.maxOutputTokens
            if (cloudSchema != null) {
                responseMimeType = "application/json"
                responseSchema = cloudSchema
            }
        }.build()
        val model = ai().generativeModel(
            modelName = config.cloudModel,
            generationConfig = generationConfig,
            systemInstruction = request.systemInstruction?.let { content { text(it) } },
            onDeviceConfig = OnDeviceConfig(
                mode = SdkMapping.mode(request.mode),
                maxOutputTokens = request.maxOutputTokens,
                modelOption = SdkMapping.option(config.androidModel),
            ),
        )

        if (request.mode == HybridMode.ONLY_ON_DEVICE) {
            // ONLY_ON_DEVICE has no cloud provider in the SDK; checking readiness first gives a
            // precise `unavailable` instead of a generic SDK error.
            val ext = model.onDeviceExtension
                ?: throw HybridError(HybridErrorCode.UNAVAILABLE, Reasons.BRIDGE_UNAVAILABLE)
            val status = SdkMapping.status(ext.checkStatus())
            if (status != OnDeviceStatus.AVAILABLE) {
                throw HybridError(
                    HybridErrorCode.UNAVAILABLE,
                    if (status == OnDeviceStatus.UNAVAILABLE) unavailableReason(config)
                    else Reasons.MODEL_NOT_READY,
                )
            }
        }

        val response = model.generateContent(prompt)
        val source = SdkMapping.source(response.inferenceSource)
        if (request.mode == HybridMode.ONLY_ON_DEVICE && source != InferenceSourceWire.ON_DEVICE) {
            throw HybridError(HybridErrorCode.FAILED, "onlyOnDevice result reported source ${source.wire}")
        }
        val text = response.text
            ?: throw HybridError(HybridErrorCode.FAILED, "Model returned no text")
        // On-device: ML Kit's getBaseModelName(); cloud: the modelVersion the backend returned.
        return GenerateResult(text, source, response.modelVersion?.takeIf { it.isNotBlank() })
    }

    // Synchronized: auto's model check calls this off the main thread.
    @Synchronized
    private fun extension(config: HybridConfig, cache: Boolean = true): OnDeviceExtension? {
        val key = config.cloudModel to config.androidModel
        if (cache) statusModel?.takeIf { statusModelKey == key }?.let { return it.onDeviceExtension }
        val model = try {
            ai().generativeModel(
                modelName = config.cloudModel,
                onDeviceConfig = OnDeviceConfig(
                    mode = InferenceMode.ONLY_ON_DEVICE,
                    modelOption = SdkMapping.option(config.androidModel),
                ),
            )
        } catch (e: IllegalStateException) {
            // No default FirebaseApp yet.
            throw HybridError(HybridErrorCode.UNAVAILABLE, Reasons.BRIDGE_UNAVAILABLE, e)
        }
        if (cache) {
            statusModelKey = key
            statusModel = model
        }
        return model.onDeviceExtension
    }

    private suspend fun modelName(ext: OnDeviceExtension): String? =
        try {
            ext.getModelName().takeIf { it.isNotBlank() }
        } catch (e: Exception) {
            null
        }
}

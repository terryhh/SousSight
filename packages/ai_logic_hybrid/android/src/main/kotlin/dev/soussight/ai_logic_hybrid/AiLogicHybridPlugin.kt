package dev.soussight.ai_logic_hybrid

import android.os.Build
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/**
 * Android backend of the hybrid inference bridge (DESIGN §4): method channel
 * `dev.soussight/ai_logic_hybrid` and event channel `dev.soussight/ai_logic_hybrid/prepare`,
 * over Firebase AI Logic (`firebase-ai` + `firebase-ai-ondevice`). Errors are PlatformExceptions
 * whose code is a HybridErrorCode name. The plugin knows nothing about cooking or privacy; the
 * app's dispatcher decides the mode.
 */
class AiLogicHybridPlugin internal constructor(
    private val engineFactory: () -> HybridEngine,
    private val chooser: DeviceListChooser,
) : FlutterPlugin, MethodCallHandler, EventChannel.StreamHandler {

    constructor() : this({ FirebaseHybridEngine() }, DeviceListChooser(Build.MANUFACTURER, Build.MODEL))

    private var channel: MethodChannel? = null
    private var prepareChannel: EventChannel? = null
    private var scope: CoroutineScope? = null
    private var generator: GenerateCoordinator? = null
    private var preparer: PrepareCoordinator? = null
    private var engine: HybridEngine? = null

    /** Always concrete (preview, previewFast or stable): deviceList is resolved at configure. */
    @Volatile private var config: HybridConfig? = null
    @Volatile private var choice: ModelChoice? = null
    /** The one device-list decision per attachment. */
    private var decision: Deferred<ModelChoice>? = null
    private var configureSeq = 0

    /** The engine while attached (tests). */
    internal val currentEngine: HybridEngine? get() = engine

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) =
        attach(binding.binaryMessenger, Dispatchers.Main.immediate)

    /** Everything [onAttachedToEngine] does once it has read the binding. */
    internal fun attach(messenger: BinaryMessenger, dispatcher: CoroutineDispatcher) {
        val scope = CoroutineScope(SupervisorJob() + dispatcher)
        val engine = engineFactory()
        this.scope = scope
        this.engine = engine
        generator = GenerateCoordinator(scope, engine, { config })
        preparer = PrepareCoordinator(scope, engine, { config })
        channel = MethodChannel(messenger, Protocol.METHOD_CHANNEL).also {
            it.setMethodCallHandler(this)
        }
        prepareChannel = EventChannel(messenger, Protocol.PREPARE_CHANNEL).also {
            it.setStreamHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) = detach()

    internal fun detach() {
        channel?.setMethodCallHandler(null)
        prepareChannel?.setStreamHandler(null)
        generator?.cancelAll()
        scope?.cancel()
        channel = null
        prepareChannel = null
        generator = null
        preparer = null
        engine = null
        scope = null
        // A later attachment must configure again; nothing runs under this one's settings.
        config = null
        choice = null
        decision = null
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        val reply = result.asReply()
        when (call.method) {
            "configure" -> configure(call.arguments, reply)
            "capabilities" -> reply.success(Protocol.capabilities(config?.androidModel, choice?.reason))
            "availability" -> availability(call.arguments, reply)
            "generate" -> generator?.start(call.arguments, reply)
                ?: reply.error(HybridErrorCode.UNAVAILABLE.wire, Reasons.BRIDGE_UNAVAILABLE)
            "cancel" -> {
                generator?.cancel(Protocol.parseRequestId(call.arguments))
                reply.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /**
     * Explicit options apply at once. `deviceList` is decided once per attachment (a bounded
     * status check at most) and configure is answered after it, so the first readiness read
     * sees the final choice. Only the latest configure call is applied.
     */
    private fun configure(args: Any?, reply: Reply) {
        val parsed = try {
            Protocol.parseConfig(args)
        } catch (e: HybridError) {
            reply.error(e.code.wire, e.message)
            return
        }
        val seq = ++configureSeq
        if (parsed.androidModel != AndroidModelOption.DEVICE_LIST) {
            apply(parsed, ModelChoice(parsed.androidModel, "set explicitly → ${parsed.androidModel.wire}"))
            reply.success(null)
            return
        }
        val engine = engine
        val scope = scope
        if (engine == null || scope == null) {
            apply(parsed, ModelChoice(AndroidModelOption.STABLE, "no bridge → stable"))
            reply.success(null)
            return
        }
        val pending = decision ?: scope.async { chooser.choose(scope, engine, parsed) }.also { decision = it }
        scope.launch {
            try {
                val chosen = pending.await()
                if (seq == configureSeq) apply(parsed, chosen)
            } finally {
                reply.success(null)
            }
        }
    }

    private fun apply(parsed: HybridConfig, chosen: ModelChoice) {
        config = parsed.copy(androidModel = chosen.option)
        choice = chosen
    }

    private fun availability(args: Any?, reply: Reply) {
        val snapshot = config
        val engine = engine
        val scope = scope
        if (snapshot == null || engine == null || scope == null) {
            val reason = if (snapshot == null) Reasons.NOT_CONFIGURED else Reasons.BRIDGE_UNAVAILABLE
            reply.success(Protocol.availabilityMap(AvailabilityResult(OnDeviceStatus.UNAVAILABLE, reason)))
            return
        }
        val withImage = Protocol.parseWithImage(args)
        scope.launch {
            val answer = try {
                currentAvailability(engine, { config }, snapshot, withImage)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                val mapped = ErrorMapping.classify(e)
                if (mapped.code == HybridErrorCode.UNAVAILABLE) {
                    AvailabilityResult(OnDeviceStatus.UNAVAILABLE, mapped.message)
                } else {
                    reply.error(mapped.code.wire, mapped.message)
                    return@launch
                }
            }
            reply.success(Protocol.availabilityMap(answer.copy(modelChoice = choice?.reason)))
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        val preparer = preparer
        if (preparer == null) {
            events.error(HybridErrorCode.UNAVAILABLE.wire, Reasons.BRIDGE_UNAVAILABLE, null)
            return
        }
        preparer.onListen(arguments, object : PrepareSink {
            override fun success(event: Any?) = events.success(event)
            override fun error(code: String, message: String?) = events.error(code, message, null)
            override fun endOfStream() = events.endOfStream()
        })
    }

    override fun onCancel(arguments: Any?) {
        preparer?.onCancel()
    }

    private fun Result.asReply(): Reply = object : Reply {
        override fun success(value: Any?) = this@asReply.success(value)
        override fun error(code: String, message: String?) = this@asReply.error(code, message, null)
    }
}

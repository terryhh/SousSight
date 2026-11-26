package dev.soussight.ai_logic_hybrid

import android.content.pm.ApplicationInfo
import android.util.Log
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
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
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
    private val engineFactory: (debuggable: Boolean, scope: CoroutineScope) -> HybridEngine,
) : FlutterPlugin, MethodCallHandler, EventChannel.StreamHandler {

    constructor() : this({ debuggable, scope -> defaultEngine(debuggable, scope) })

    private var channel: MethodChannel? = null
    private var prepareChannel: EventChannel? = null
    private var scope: CoroutineScope? = null
    private var generator: GenerateCoordinator? = null
    private var preparer: PrepareCoordinator? = null
    private var engine: HybridEngine? = null

    @Volatile private var config: HybridConfig? = null

    /** The engine while attached (tests). */
    internal val currentEngine: HybridEngine? get() = engine

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val flags = binding.applicationContext.applicationInfo.flags
        attach(binding.binaryMessenger, debuggable = (flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0)
    }

    /** Everything [onAttachedToEngine] does once it has read the binding. */
    internal fun attach(
        messenger: BinaryMessenger,
        debuggable: Boolean,
        dispatcher: CoroutineDispatcher = Dispatchers.Main.immediate,
    ) {
        val scope = CoroutineScope(SupervisorJob() + dispatcher)
        // The engine's own background work (auto's model check) lives and dies with this scope.
        val engine = engineFactory(debuggable, scope)
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
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        val reply = result.asReply()
        when (call.method) {
            "configure" -> try {
                val parsed = Protocol.parseConfig(call.arguments)
                config = parsed
                engine?.configured(parsed)
                reply.success(null)
            } catch (e: HybridError) {
                reply.error(e.code.wire, e.message)
            }
            "capabilities" -> reply.success(capabilities(config, engine))
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
            reply.success(Protocol.availabilityMap(answer))
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

    internal companion object {
        const val LOG_TAG = "AiLogicHybrid"

        /** Production engine: `auto` selection over Firebase AI Logic, logging to logcat. */
        fun defaultEngine(
            debuggable: Boolean,
            scope: CoroutineScope,
            log: (String) -> Unit = { Log.i(LOG_TAG, it) },
        ): HybridEngine = AutoModelEngine(
            FirebaseHybridEngine(),
            scope,
            // Debug builds also confirm the chosen model answers, for device verification.
            verifyChoice = debuggable,
            log = log,
        )

        /** Capabilities with the option in use: null until configured and, for auto, chosen. */
        fun capabilities(config: HybridConfig?, engine: HybridEngine?): Map<String, Any?> =
            Protocol.capabilities(config?.let { engine?.modelOption(it) })
    }
}

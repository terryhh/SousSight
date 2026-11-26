package dev.soussight.soussight

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var player: PcmPlayer? = null
    private var token = 0

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PCM_PLAYER_CHANNEL).also {
            it.setMethodCallHandler { call, result ->
                // Calls from a closed session carry an old token and are ignored.
                val current = call.argument<Int>("token") == token && player != null
                when (call.method) {
                    "open" -> {
                        player?.release()
                        player = null
                        val sampleRate = call.argument<Int>("sampleRate") ?: 24000
                        try {
                            player = PcmPlayer(sampleRate)
                            token += 1
                            result.success(token)
                        } catch (error: Exception) {
                            result.error("pcm_player", error.message, null)
                        }
                    }
                    "feed" -> {
                        val pcm = call.argument<ByteArray>("pcm")
                        if (current && pcm != null) player?.feed(pcm)
                        result.success(null)
                    }
                    "interrupt" -> {
                        if (current) player?.interrupt()
                        result.success(null)
                    }
                    "close" -> {
                        if (current) {
                            player?.release()
                            player = null
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        channel?.setMethodCallHandler(null)
        channel = null
        player?.release()
        player = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    private companion object {
        const val PCM_PLAYER_CHANNEL = "dev.soussight/pcm_player"
    }
}

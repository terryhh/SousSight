package dev.soussight.soussight

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Streams PCM16 mono audio (the Live coach's voice) to the speaker.
 *
 * Writes happen on one background thread in 20 ms slices so [interrupt] can
 * drop queued speech almost immediately: it bumps the generation (queued
 * writes skip themselves) and flushes what AudioTrack already holds.
 */
class PcmPlayer(private val sampleRate: Int) {
    private val writer: ExecutorService = Executors.newSingleThreadExecutor()
    private val track: AudioTrack
    private val sliceBytes = sampleRate / 50 * BYTES_PER_SAMPLE

    @Volatile private var generation = 0
    @Volatile private var released = false

    init {
        val minBuffer = AudioTrack.getMinBufferSize(
            sampleRate,
            AudioFormat.CHANNEL_OUT_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        require(minBuffer > 0) { "Unsupported playback sample rate $sampleRate" }
        track = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build(),
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setSampleRate(sampleRate)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .build(),
            )
            // At least 200 ms so network jitter does not underrun.
            .setBufferSizeInBytes(maxOf(minBuffer, sampleRate / 5 * BYTES_PER_SAMPLE))
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
        if (track.state != AudioTrack.STATE_INITIALIZED) {
            track.release()
            writer.shutdown()
            throw IllegalStateException("AudioTrack did not initialize")
        }
        track.play()
    }

    fun feed(pcm: ByteArray) {
        if (released) return
        val queuedAt = generation
        writer.execute {
            var offset = 0
            // Even byte count: a PCM16 sample is never split.
            val end = pcm.size - pcm.size % BYTES_PER_SAMPLE
            while (offset < end && queuedAt == generation && !released) {
                val length = minOf(sliceBytes, end - offset)
                val written = track.write(pcm, offset, length, AudioTrack.WRITE_BLOCKING)
                if (written <= 0) break
                offset += written
            }
        }
    }

    /** Drops queued and buffered speech; the player stays ready for more. */
    @Synchronized
    fun interrupt() {
        if (released) return
        generation += 1
        track.pause()
        track.flush()
        track.play()
    }

    @Synchronized
    fun release() {
        if (released) return
        released = true
        generation += 1
        track.pause()
        track.flush()
        // Released on the writer thread, after any in-flight slice returns.
        writer.execute { track.release() }
        writer.shutdown()
    }

    private companion object {
        const val BYTES_PER_SAMPLE = 2
    }
}

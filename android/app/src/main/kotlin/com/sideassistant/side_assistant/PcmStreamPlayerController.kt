package com.sideassistant.side_assistant

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Build
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

class PcmStreamPlayerController {
    private val executor = Executors.newSingleThreadExecutor()
    private val generation = AtomicInteger(0)
    @Volatile
    private var audioTrack: AudioTrack? = null
    @Volatile
    private var currentSampleRate: Int = 0
    private val activeWrites = AtomicInteger(0)

    @Synchronized
    private fun ensureAudioTrack(sampleRate: Int): AudioTrack? {
        val existing = audioTrack
        if (existing != null && existing.state == AudioTrack.STATE_INITIALIZED && currentSampleRate == sampleRate) {
            if (existing.playState != AudioTrack.PLAYSTATE_PLAYING) {
                try {
                    existing.play()
                } catch (_: Exception) {}
            }
            return existing
        }
        releaseTrackLocked()
        return try {
            val minBuf = AudioTrack.getMinBufferSize(
                sampleRate,
                AudioFormat.CHANNEL_OUT_MONO,
                AudioFormat.ENCODING_PCM_16BIT
            ).coerceAtLeast(sampleRate / 5 * 2) // 至少 200ms 缓冲防抖

            val attrs = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                .build()

            val format = AudioFormat.Builder()
                .setSampleRate(sampleRate)
                .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .build()

            val builder = AudioTrack.Builder()
                .setAudioAttributes(attrs)
                .setAudioFormat(format)
                .setBufferSizeInBytes(minBuf)
                .setTransferMode(AudioTrack.MODE_STREAM)

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                builder.setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
            }

            val track = builder.build()
            track.play()
            audioTrack = track
            currentSampleRate = sampleRate
            track
        } catch (_: Exception) {
            null
        }
    }

    fun feed(pcmBytes: ByteArray, sampleRate: Int) {
        if (pcmBytes.isEmpty()) return
        val gen = generation.get()
        activeWrites.incrementAndGet()
        executor.execute {
            try {
                if (gen != generation.get()) return@execute
                val track = ensureAudioTrack(sampleRate) ?: return@execute
                var offset = 0
                while (offset < pcmBytes.size && gen == generation.get()) {
                    val step = (pcmBytes.size - offset).coerceAtMost(4800)
                    val written = track.write(pcmBytes, offset, step, AudioTrack.WRITE_BLOCKING)
                    if (written <= 0) break
                    offset += written
                }
            } catch (_: Exception) {
            } finally {
                activeWrites.decrementAndGet()
            }
        }
    }

    @Synchronized
    fun stopImmediate() {
        generation.incrementAndGet()
        val track = audioTrack ?: return
        try {
            track.pause()
            track.flush()
            track.play()
        } catch (_: Exception) {
        }
    }

    fun isPlaying(): Boolean {
        return activeWrites.get() > 0
    }

    @Synchronized
    private fun releaseTrackLocked() {
        val track = audioTrack
        audioTrack = null
        currentSampleRate = 0
        if (track != null) {
            try {
                track.pause()
                track.flush()
                track.release()
            } catch (_: Exception) {
            }
        }
    }

    fun dispose() {
        generation.incrementAndGet()
        releaseTrackLocked()
        executor.shutdownNow()
    }
}

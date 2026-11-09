package com.sideassistant.side_assistant

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Build
import android.os.SystemClock
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

class PcmStreamPlayerController(private val context: Context) {
    private val audioManager =
        context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val executor = Executors.newSingleThreadExecutor()
    private val generation = AtomicInteger(0)

    @Volatile
    private var audioTrack: AudioTrack? = null

    @Volatile
    private var currentSampleRate: Int = 0

    private val activeWrites = AtomicInteger(0)

    @Volatile
    private var playbackUntilElapsedMs: Long = 0L

    @Volatile
    private var communicationModeActive: Boolean = false

    private fun ensureCommunicationModeLocked() {
        if (communicationModeActive) return
        try {
            audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val currentDevice = audioManager.communicationDevice
                if (currentDevice == null || currentDevice.type == AudioDeviceInfo.TYPE_BUILTIN_EARPIECE) {
                    val speaker = audioManager.availableCommunicationDevices.firstOrNull {
                        it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
                    }
                    if (speaker != null) {
                        audioManager.setCommunicationDevice(speaker)
                    }
                }
            } else {
                @Suppress("DEPRECATION")
                if (!audioManager.isBluetoothScoOn && !audioManager.isWiredHeadsetOn) {
                    @Suppress("DEPRECATION")
                    audioManager.isSpeakerphoneOn = true
                }
            }
            communicationModeActive = true
        } catch (_: Exception) {
        }
    }

    @Synchronized
    private fun ensureTrackLocked(sampleRate: Int): AudioTrack? {
        ensureCommunicationModeLocked()
        val existing = audioTrack
        if (existing != null && existing.state == AudioTrack.STATE_INITIALIZED && currentSampleRate == sampleRate) {
            if (existing.playState != AudioTrack.PLAYSTATE_PLAYING) {
                try {
                    existing.play()
                } catch (_: Exception) {
                }
            }
            return existing
        }
        releaseTrackLocked()
        return try {
            val minBufferSize = AudioTrack.getMinBufferSize(
                sampleRate,
                AudioFormat.CHANNEL_OUT_MONO,
                AudioFormat.ENCODING_PCM_16BIT
            )
            // 至少 500ms 缓冲防抖 (sampleRate / 2 * 2 字节)
            val bufferSize = minBufferSize.coerceAtLeast(sampleRate / 2 * 2)

            val attrs = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
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
                .setBufferSizeInBytes(bufferSize)
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
        val durationMs = ((pcmBytes.size / 2) * 1000L) / sampleRate.coerceAtLeast(8000)
        val now = SystemClock.elapsedRealtime()
        val base = if (playbackUntilElapsedMs > now) playbackUntilElapsedMs else (now + 120L)
        playbackUntilElapsedMs = base + durationMs

        val gen = generation.get()
        activeWrites.incrementAndGet()
        executor.execute {
            try {
                if (gen != generation.get()) return@execute
                val track = ensureTrackLocked(sampleRate) ?: return@execute
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
        playbackUntilElapsedMs = 0L
        val track = audioTrack ?: return
        try {
            track.pause()
            track.flush()
            track.play()
        } catch (_: Exception) {
        }
    }

    fun isPlaying(): Boolean {
        return activeWrites.get() > 0 || SystemClock.elapsedRealtime() < playbackUntilElapsedMs
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

    @Synchronized
    fun release() {
        generation.incrementAndGet()
        playbackUntilElapsedMs = 0L
        releaseTrackLocked()
        if (communicationModeActive) {
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    audioManager.clearCommunicationDevice()
                } else {
                    @Suppress("DEPRECATION")
                    audioManager.isSpeakerphoneOn = false
                }
                audioManager.mode = AudioManager.MODE_NORMAL
            } catch (_: Exception) {
            }
            communicationModeActive = false
        }
        executor.shutdownNow()
    }

    fun dispose() {
        release()
    }
}

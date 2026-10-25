package com.sideassistant.side_assistant

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageFormat
import android.graphics.Matrix
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.media.ExifInterface
import android.os.Handler
import android.os.Looper
import android.util.Size
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import java.io.ByteArrayOutputStream
import java.io.File
import kotlin.math.roundToInt

/** 一次抓拍的结果：原图文件 + 可选压缩后的上传字节。 */
class CaptureResult(val file: File, val jpegBytes: ByteArray)

/**
 * 后台拍照控制器。
 *
 * 关键点：CameraX 通常绑定在 Activity 的生命周期上，Activity 退到后台（onStop）后
 * 相机会被解绑，后台再拍照必然失败。这里使用一个独立于 Activity、始终保持 RESUMED
 * 的 LifecycleOwner，把 ImageCapture 绑定到它上面；只要进程存活 + 前台服务带有
 * camera 类型，就能在后台继续使用系统摄像头。
 */
class BackgroundCameraController(private val context: Context) {

    companion object {
        private const val OPEN_TIMEOUT_MS = 12_000L
        private const val CAPTURE_TIMEOUT_MS = 15_000L

        /** 未指定分辨率时的默认目标（CameraX 会按设备支持档位就近选）。 */
        private val DEFAULT_TARGET_SIZE = Size(1600, 1200)
    }

    private val mainExecutor = ContextCompat.getMainExecutor(context)
    private val mainHandler = Handler(Looper.getMainLooper())

    private var cameraProvider: ProcessCameraProvider? = null
    private var imageCapture: ImageCapture? = null
    private var lifecycleOwner: CameraLifecycleOwner? = null
    private var currentLensDirection: String? = null
    private var currentTargetSize: Size = DEFAULT_TARGET_SIZE

    /** 每次 open/close 递增，用于丢弃过期的异步回调。 */
    private var generation = 0
    private var opening = false

    fun hasPermission(): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) ==
            PackageManager.PERMISSION_GRANTED

    /**
     * 打开并绑定指定镜头。
     *
     * @param targetWidth/targetHeight 期望的 JPEG 分辨率；传 0 表示使用默认目标（1600×1200）
     *   并按设备支持档位就近选择。
     * 回调固定切回主线程。
     */
    fun open(
        lensDirection: String,
        targetWidth: Int = 0,
        targetHeight: Int = 0,
        callback: (Result<Unit>) -> Unit
    ) {
        mainExecutor.execute {
            val targetSize =
                if (targetWidth > 0 && targetHeight > 0) Size(targetWidth, targetHeight)
                else DEFAULT_TARGET_SIZE
            if (!hasPermission()) {
                callback(Result.failure(SecurityException("未授予相机权限")))
                return@execute
            }
            if (imageCapture != null &&
                currentLensDirection == lensDirection &&
                currentTargetSize == targetSize
            ) {
                callback(Result.success(Unit))
                return@execute
            }
            if (opening) {
                callback(Result.failure(IllegalStateException("相机正在打开中")))
                return@execute
            }

            opening = true
            val openGeneration = ++generation
            unbindInternal()

            var completed = false
            val finish: (Result<Unit>) -> Unit = { result ->
                if (!completed) {
                    completed = true
                    opening = false
                    callback(result)
                }
            }
            val timeout = Runnable {
                finish(Result.failure(IllegalStateException("打开相机超时")))
            }
            mainHandler.postDelayed(timeout, OPEN_TIMEOUT_MS)

            val future = ProcessCameraProvider.getInstance(context)
            future.addListener({
                try {
                    val provider = future.get()
                    if (openGeneration != generation) {
                        // 期间已 close 或重新 open，丢弃本次结果。
                        mainHandler.removeCallbacks(timeout)
                        finish(Result.failure(IllegalStateException("相机打开已取消")))
                        return@addListener
                    }

                    val owner = CameraLifecycleOwner()
                    val selector = lensSelector(lensDirection)
                    val capture = ImageCapture.Builder()
                        .setCaptureMode(ImageCapture.CAPTURE_MODE_MINIMIZE_LATENCY)
                        .setResolutionSelector(
                            ResolutionSelector.Builder()
                                .setResolutionStrategy(
                                    ResolutionStrategy(
                                        targetSize,
                                        ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER
                                    )
                                )
                                .build()
                        )
                        .build()

                    provider.unbindAll()
                    provider.bindToLifecycle(owner, selector, capture)

                    cameraProvider = provider
                    lifecycleOwner = owner
                    imageCapture = capture
                    currentLensDirection = lensDirection
                    currentTargetSize = targetSize

                    mainHandler.removeCallbacks(timeout)
                    finish(Result.success(Unit))
                } catch (e: Exception) {
                    mainHandler.removeCallbacks(timeout)
                    unbindInternal()
                    finish(Result.failure(e))
                }
            }, mainExecutor)
        }
    }

    /**
     * 使用当前已绑定的会话抓拍一张 JPEG，回调固定切回主线程。
     *
     * @param sendShortEdge > 0 时，返回的 [CaptureResult.jpegBytes] 会按短边缩放到该值
     *   （原图文件保持不变），用于降低视觉模型请求的延迟。
     */
    fun capture(sendShortEdge: Int = 0, callback: (Result<CaptureResult>) -> Unit) {
        mainExecutor.execute {
            if (!hasPermission()) {
                callback(Result.failure(SecurityException("未授予相机权限")))
                return@execute
            }
            val capture = imageCapture
            if (capture == null) {
                callback(Result.failure(IllegalStateException("相机尚未打开")))
                return@execute
            }

            val resolution = capture.resolutionInfo?.resolution
            android.util.Log.i(
                "SideAssistantCamera",
                "拍照分辨率: ${resolution?.width}x${resolution?.height} " +
                    "(请求目标 ${currentTargetSize.width}x${currentTargetSize.height}, " +
                    "镜头=$currentLensDirection)"
            )

            val file = File(context.cacheDir, "sa_capture_${System.currentTimeMillis()}.jpg")
            val options = ImageCapture.OutputFileOptions.Builder(file).build()

            var completed = false
            val finish: (Result<CaptureResult>) -> Unit = { result ->
                if (!completed) {
                    completed = true
                    callback(result)
                }
            }
            val timeout = Runnable {
                finish(Result.failure(IllegalStateException("拍照超时")))
            }
            mainHandler.postDelayed(timeout, CAPTURE_TIMEOUT_MS)

            capture.takePicture(
                options,
                mainExecutor,
                object : ImageCapture.OnImageSavedCallback {
                    override fun onImageSaved(outputFileResults: ImageCapture.OutputFileResults) {
                        mainHandler.removeCallbacks(timeout)
                        if (file.exists() && file.length() > 0) {
                            val bytes = try {
                                encodeForUpload(file, sendShortEdge)
                            } catch (e: Exception) {
                                android.util.Log.w(
                                    "SideAssistantCamera",
                                    "上传图压缩失败，改用原图: ${e.message}"
                                )
                                file.readBytes()
                            }
                            if (sendShortEdge > 0) {
                                android.util.Log.i(
                                    "SideAssistantCamera",
                                    "上传图: ${bytes.size / 1024}KB " +
                                        "(原图 ${file.length() / 1024}KB, " +
                                        "短边目标 ${sendShortEdge}px)"
                                )
                            }
                            finish(Result.success(CaptureResult(file, bytes)))
                        } else {
                            finish(Result.failure(IllegalStateException("拍照结果为空")))
                        }
                    }

                    override fun onError(exception: ImageCaptureException) {
                        mainHandler.removeCallbacks(timeout)
                        finish(Result.failure(exception))
                    }
                }
            )
        }
    }

    fun close() {
        mainExecutor.execute {
            generation++
            opening = false
            unbindInternal()
        }
    }

    /**
     * 读取目标镜头真实支持的 JPEG 输出档位。
     *
     * 结果直接来自 Camera2 的 SCALER_STREAM_CONFIGURATION_MAP，因此每一项都是
     * 本机硬件实际可拍照的分辨率，避免设置里出现选了也无效的档位。
     */
    fun getSupportedResolutions(
        lensDirection: String,
        callback: (Result<List<Map<String, Int>>>) -> Unit
    ) {
        mainExecutor.execute {
            try {
                val manager =
                    context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
                val desiredFacing = if (lensDirection == "front") {
                    CameraCharacteristics.LENS_FACING_FRONT
                } else {
                    CameraCharacteristics.LENS_FACING_BACK
                }

                var characteristics: CameraCharacteristics? = null
                for (cameraId in manager.cameraIdList) {
                    val candidate = manager.getCameraCharacteristics(cameraId)
                    if (candidate.get(CameraCharacteristics.LENS_FACING) == desiredFacing) {
                        characteristics = candidate
                        break
                    }
                }
                val cameraCharacteristics = characteristics
                    ?: throw IllegalStateException(
                        if (lensDirection == "front") "未找到前置摄像头" else "未找到后置摄像头"
                    )

                val streamConfig = cameraCharacteristics.get(
                    CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP
                ) ?: throw IllegalStateException("无法读取摄像头能力")

                val sizes = streamConfig.getOutputSizes(ImageFormat.JPEG)
                    ?.filter { it.width >= 640 && it.height >= 480 }
                    ?.distinctBy { "${it.width}x${it.height}" }
                    ?.sortedByDescending { it.width.toLong() * it.height.toLong() }
                    .orEmpty()

                callback(Result.success(sizes.map { size ->
                    mapOf("width" to size.width, "height" to size.height)
                }))
            } catch (e: Exception) {
                callback(Result.failure(e))
            }
        }
    }

    private fun lensSelector(lensDirection: String): CameraSelector =
        if (lensDirection == "front") CameraSelector.DEFAULT_FRONT_CAMERA
        else CameraSelector.DEFAULT_BACK_CAMERA

    /**
     * 把原图按“短边 = targetShortEdge”等比缩放并重新编码为 JPEG。
     *
     * - 先按 EXIF 方向把图转正，避免竖拍照片发给模型时是横的；
     * - 用 inSampleSize 先做一次快速降采样，避免整张 12MP 图完整解码进内存；
     * - 只在原图确实更大时才处理，否则直接返回原字节。
     */
    private fun encodeForUpload(file: File, targetShortEdge: Int): ByteArray {
        if (targetShortEdge <= 0) return file.readBytes()

        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.absolutePath, bounds)
        val srcWidth = bounds.outWidth
        val srcHeight = bounds.outHeight
        if (srcWidth <= 0 || srcHeight <= 0) return file.readBytes()

        val srcShortEdge = minOf(srcWidth, srcHeight)
        if (srcShortEdge <= targetShortEdge) return file.readBytes()

        var sampleSize = 1
        while (srcShortEdge / (sampleSize * 2) >= targetShortEdge) {
            sampleSize *= 2
        }
        val decodeOptions = BitmapFactory.Options().apply { inSampleSize = sampleSize }
        val decoded = BitmapFactory.decodeFile(file.absolutePath, decodeOptions)
            ?: return file.readBytes()

        val oriented = applyExifOrientation(file, decoded)
        val shortEdge = minOf(oriented.width, oriented.height)
        val scale = targetShortEdge.toFloat() / shortEdge
        val targetWidth = maxOf(1, (oriented.width * scale).roundToInt())
        val targetHeight = maxOf(1, (oriented.height * scale).roundToInt())

        val scaled = if (oriented.width == targetWidth && oriented.height == targetHeight) {
            oriented
        } else {
            Bitmap.createScaledBitmap(oriented, targetWidth, targetHeight, true)
        }

        val output = ByteArrayOutputStream()
        scaled.compress(Bitmap.CompressFormat.JPEG, 88, output)
        if (scaled !== oriented) scaled.recycle()
        if (oriented !== decoded) oriented.recycle()
        decoded.recycle()
        return output.toByteArray()
    }

    /** 按 EXIF 方向把解码后的位图转正；无方向信息时原样返回。 */
    private fun applyExifOrientation(file: File, bitmap: Bitmap): Bitmap {
        val orientation = try {
            ExifInterface(file.absolutePath).getAttributeInt(
                ExifInterface.TAG_ORIENTATION,
                ExifInterface.ORIENTATION_NORMAL
            )
        } catch (_: Exception) {
            ExifInterface.ORIENTATION_NORMAL
        }

        val matrix = Matrix()
        when (orientation) {
            ExifInterface.ORIENTATION_ROTATE_90 -> matrix.postRotate(90f)
            ExifInterface.ORIENTATION_ROTATE_180 -> matrix.postRotate(180f)
            ExifInterface.ORIENTATION_ROTATE_270 -> matrix.postRotate(270f)
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.postScale(-1f, 1f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.postScale(1f, -1f)
            ExifInterface.ORIENTATION_TRANSPOSE -> {
                matrix.postRotate(90f)
                matrix.postScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_TRANSVERSE -> {
                matrix.postRotate(270f)
                matrix.postScale(-1f, 1f)
            }
            else -> return bitmap
        }

        return try {
            Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
        } catch (_: Exception) {
            bitmap
        }
    }

    private fun unbindInternal() {
        try {
            cameraProvider?.unbindAll()
        } catch (_: Exception) {
        }
        try {
            lifecycleOwner?.destroy()
        } catch (_: Exception) {
        }
        cameraProvider = null
        lifecycleOwner = null
        imageCapture = null
        currentLensDirection = null
    }

    /** 不依赖 Activity 的生命周期宿主，始终保持 RESUMED 以便后台持续使用相机。 */
    private class CameraLifecycleOwner : LifecycleOwner {
        private val registry = LifecycleRegistry(this)

        override val lifecycle: Lifecycle
            get() = registry

        init {
            registry.currentState = Lifecycle.State.RESUMED
        }

        fun destroy() {
            registry.currentState = Lifecycle.State.DESTROYED
        }
    }
}

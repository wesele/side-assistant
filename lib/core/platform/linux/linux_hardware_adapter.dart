import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../../models/device_options.dart';
import 'linux_audio_capture_service.dart';
import 'linux_audio_device_service.dart';
import 'linux_audio_playback_service.dart';
import 'linux_camera_capture_service.dart';
import 'linux_system_metrics_service.dart';
import 'linux_system_tts_service.dart';

export 'linux_audio_capture_service.dart'
    show LinuxMicRecordStream, LinuxAudioCaptureService;
export 'linux_audio_device_service.dart' show LinuxAudioDeviceService;
export 'linux_audio_playback_service.dart'
    show LinuxPlaybackHandle, LinuxAudioPlaybackService;
export 'linux_camera_capture_service.dart' show LinuxCameraCaptureService;
export 'linux_system_metrics_service.dart' show LinuxSystemMetricsService;
export 'linux_system_tts_service.dart' show LinuxSystemTtsService;

/// Linux 无头服务端硬件适配器统一 Facade：
/// 保持 100% 接口与行为向后兼容，内部将各硬件域委托至专属服务：
/// - 音频输入/输出设备与混音器 -> [LinuxAudioDeviceService]
/// - 音频播放与转码 -> [LinuxAudioPlaybackService]
/// - 麦克风录音与流式采集 -> [LinuxAudioCaptureService]
/// - V4L2 摄像头枚举与抓拍 -> [LinuxCameraCaptureService]
/// - CPU 性能监控指标 -> [LinuxSystemMetricsService]
/// - 离线系统 TTS 兜底 -> [LinuxSystemTtsService]
class LinuxHardwareAdapter {
  LinuxHardwareAdapter._();

  /// 枚举 Linux 上的麦克风输入设备
  static Future<List<AudioInputDeviceOption>> listInputDevices() =>
      LinuxAudioDeviceService.listInputDevices();

  /// 当前系统默认录音源名（自动模式下判断内置/蓝牙音源用）
  static Future<String> defaultInputSourceName() =>
      LinuxAudioDeviceService.defaultSourceName();

  /// 枚举 Linux 上的扬声器输出设备
  static Future<List<AudioOutputDeviceOption>> listOutputDevices() =>
      LinuxAudioDeviceService.listOutputDevices();

  /// 当前音量百分比缓存
  static int get currentVolumePercent =>
      LinuxAudioDeviceService.currentVolumePercent;

  /// 读取 Linux 服务器当前扬声器音量百分比（0 - 150）
  static Future<int> getOutputVolume({String outputDeviceId = ''}) =>
      LinuxAudioDeviceService.getOutputVolume(outputDeviceId: outputDeviceId);

  /// 设置 Linux 服务器扬声器播放音量百分比（0 - 150）
  static Future<void> setOutputVolume(
    int volumePercent, {
    String outputDeviceId = '',
  }) =>
      LinuxAudioDeviceService.setOutputVolume(
        volumePercent,
        outputDeviceId: outputDeviceId,
      );

  /// 启动 16kHz 16-bit 单声道 PCM 麦克风实时流
  static Future<LinuxMicRecordStream> startMicStream({
    String deviceId = '',
    int sampleRate = 16000,
    int numChannels = 1,
  }) =>
      LinuxAudioCaptureService.startMicStream(
        deviceId: deviceId,
        sampleRate: sampleRate,
        numChannels: numChannels,
      );

  /// 录制 WAV 文件（用于手动按住对讲录音）
  static Future<Process> startWavFileRecording({
    required String filePath,
    String deviceId = '',
    int sampleRate = 16000,
    int numChannels = 1,
  }) =>
      LinuxAudioCaptureService.startWavFileRecording(
        filePath: filePath,
        deviceId: deviceId,
        sampleRate: sampleRate,
        numChannels: numChannels,
      );

  /// 枚举 Linux 上的本地 V4L2 摄像头设备
  static Future<List<LinuxCameraDeviceOption>> listCameraDevices() =>
      LinuxCameraCaptureService.listCameraDevices();

  /// 使用 V4L2 + ffmpeg 从本地摄像头抓拍一帧 JPEG
  static Future<(Uint8List bytes, String filePath)> captureV4l2Photo({
    String configuredDevice = '',
    int targetWidth = 0,
    int targetHeight = 0,
    int sendShortEdge = 0,
  }) =>
      LinuxCameraCaptureService.captureV4l2Photo(
        configuredDevice: configuredDevice,
        targetWidth: targetWidth,
        targetHeight: targetHeight,
        sendShortEdge: sendShortEdge,
      );

  /// 在服务器端扬声器播放音频文件（支持 WAV 与 MP3）
  static Future<LinuxPlaybackHandle> playAudioFile(
    String filePath, {
    String outputDeviceId = '',
    int? volumePercent,
    String? cleanupFilePath,
  }) =>
      LinuxAudioPlaybackService.playAudioFile(
        filePath,
        outputDeviceId: outputDeviceId,
        volumePercent: volumePercent,
        cleanupFilePath: cleanupFilePath,
      );

  /// 播放内存中的 WAV 字节
  static Future<LinuxPlaybackHandle> playWavBytes(
    Uint8List wavBytes, {
    String outputDeviceId = '',
    String tag = 'tone',
  }) =>
      LinuxAudioPlaybackService.playWavBytes(
        wavBytes,
        outputDeviceId: outputDeviceId,
        tag: tag,
      );

  /// 终止所有正在运行的播放子进程
  static Future<void> killRunningPlayProcesses() =>
      LinuxAudioPlaybackService.killRunningPlayProcesses();

  /// Linux 系统级离线 TTS 兜底（基于 espeak-ng 生成 WAV 后走扬声器播放）
  static Future<LinuxPlaybackHandle?> speakSystemTts(
    String text, {
    double speed = 1.0,
    String outputDeviceId = '',
  }) =>
      LinuxSystemTtsService.speakSystemTts(
        text,
        speed: speed,
        outputDeviceId: outputDeviceId,
      );

  /// 从 /proc/stat 内容解析瞬时 CPU 时间计数 (active, total)
  static (int active, int total)? parseProcStatCpuCounters(String content) =>
      LinuxSystemMetricsService.parseProcStatCpuCounters(content);

  /// 重置 CPU 计算计数器（主要用于单元测试隔离）
  static void resetCpuUsageCountersForTest() =>
      LinuxSystemMetricsService.resetCpuUsageCountersForTest();

  /// 获取 Linux 系统当前实时的 CPU 占用百分比 (0.0 - 100.0)
  static double getCpuUsagePercent({String procStatPath = '/proc/stat'}) =>
      LinuxSystemMetricsService.getCpuUsagePercent(procStatPath: procStatPath);
}

/// 向后兼容的别名，便于已有代码无缝兼容
typedef LinuxHardwareService = LinuxHardwareAdapter;

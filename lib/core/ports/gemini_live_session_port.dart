import 'dart:async';
import 'dart:typed_data';

import '../models/app_settings.dart';
import '../models/camera_capture_result.dart';
import '../models/chat_message.dart';

/// Gemini 3.8 Live 端到端全双工会话端口 (Outbound Port)
///
/// 将实时音频上推 (16kHz PCM)、多模态图像帧上传、原生工具调用 (Google Search /
/// LightRAG / 拍照)、双向实时转写字幕及原生 24kHz 音频直出统一封装在纯 Dart 抽象契约后。
abstract class GeminiLiveSessionPort {
  /// 连接是否已完成握手 (setupComplete) 并可收发实时流
  bool get isReady;

  /// 会话是否处于激活工作态
  bool get isActive;

  /// 当前是否正在播放云端直出的原生语音流
  bool get isSpeakingOutput;

  /// 最近一次连接或协议错误描述
  String? get lastError;

  /// 用户语音实时转写回调 (inputAudioTranscription)
  void Function(String text, {required bool isFinal})? onInputTranscription;

  /// 助手语音实时转写回调 (outputAudioTranscription)
  void Function(String deltaText, String fullText, {required bool isFinal})?
      onOutputTranscription;

  /// 收到云端 24kHz PCM 语音分片回调
  void Function(Uint8List pcm24kBytes)? onAudioOutputChunk;

  /// 助手开始新的一轮语音回复
  void Function()? onModelTurnStarted;

  /// 本轮交互完成 (turnComplete)
  void Function()? onTurnCompleted;

  /// 用户开口打断 (interrupted == true)
  void Function()? onInterrupted;

  /// 连接/工作状态提示变更
  void Function(String statusHint)? onStatusHintChanged;

  /// 工具调用视觉抓拍回调
  Future<CameraCaptureResult?> Function()? onCapturePhoto;

  /// 工具调用状态提示回调 (如 "正在搜索..." / "正在调用相机拍照...")
  void Function(String toolName, String query)? onToolCall;

  /// 建立或确保 Live WebSocket 连接就绪
  Future<bool> connect();

  /// 主动断开 Live WebSocket 连接并停止音频输出
  Future<void> disconnect();

  /// 持续喂入麦克风 16kHz 单声道 Float32 PCM 采样
  void feedAudioSamples(Float32List samples, {int sampleRate = 16000});

  /// 发送手动按住对讲录制的音频文件
  Future<void> sendAudioFile(String filePath);

  /// 直接发送用户文本消息（支持可选附图）
  Future<void> sendClientText(
    String text, {
    Uint8List? imageBytes,
    String? imagePath,
  });

  /// 实时向當前会话推送一帧 JPEG 图像
  Future<void> sendRealtimeImage(Uint8List jpegBytes);

  /// 立即终止当前正在播放的助手语音输出
  Future<void> stopSpeaking();

  /// 试听原生音色 (创建临时探针连接并朗读试听文本)
  Future<void> previewVoice({
    required String voice,
    String? text,
    String? apiKey,
    String? model,
  });

  /// 同步/重置会话历史上下文（用于新建会话或切换历史会话）
  Future<void> syncSessionContext(
    List<ChatMessage> history, {
    bool resetSession = false,
  });

  /// 热更新设置（若关键连接参数变更则自动重连）
  void applySettings(AppSettings newSettings);

  /// 释放所有网络与音频播放资源
  void dispose();
}

/// 空实现（用于未启用或单测隔离）
class NullGeminiLiveSessionPort implements GeminiLiveSessionPort {
  @override
  bool get isReady => false;

  @override
  bool get isActive => false;

  @override
  bool get isSpeakingOutput => false;

  @override
  String? get lastError => null;

  @override
  void Function(String text, {required bool isFinal})? onInputTranscription;

  @override
  void Function(String deltaText, String fullText, {required bool isFinal})?
      onOutputTranscription;

  @override
  void Function(Uint8List pcm24kBytes)? onAudioOutputChunk;

  @override
  void Function()? onModelTurnStarted;

  @override
  void Function()? onTurnCompleted;

  @override
  void Function()? onInterrupted;

  @override
  void Function(String statusHint)? onStatusHintChanged;

  @override
  Future<CameraCaptureResult?> Function()? onCapturePhoto;

  @override
  void Function(String toolName, String query)? onToolCall;

  @override
  Future<bool> connect() async => false;

  @override
  Future<void> disconnect() async {}

  @override
  void feedAudioSamples(Float32List samples, {int sampleRate = 16000}) {}

  @override
  Future<void> sendAudioFile(String filePath) async {}

  @override
  Future<void> sendClientText(
    String text, {
    Uint8List? imageBytes,
    String? imagePath,
  }) async {}

  @override
  Future<void> sendRealtimeImage(Uint8List jpegBytes) async {}

  @override
  Future<void> stopSpeaking() async {}

  @override
  Future<void> previewVoice({
    required String voice,
    String? text,
    String? apiKey,
    String? model,
  }) async {}

  @override
  Future<void> syncSessionContext(
    List<ChatMessage> history, {
    bool resetSession = false,
  }) async {}

  @override
  void applySettings(AppSettings newSettings) {}

  @override
  void dispose() {}
}

/// Gemini 3.8 Live 会话工厂注册表
class GeminiLiveSessionFactoryRegistry {
  static GeminiLiveSessionPort Function(AppSettings settings)? defaultFactory;
}

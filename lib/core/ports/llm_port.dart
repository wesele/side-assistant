import 'dart:typed_data';

import '../models/chat_message.dart';
import '../models/domain_configs.dart';

/// 大语言模型服务端口 (LLM Port)
///
/// 定义文本流式对话、多模态视觉问答与推理能力契约。
abstract interface class LlmPort {
  void applyConfig(LlmConfig config);

  Future<String?> describeImage(Uint8List imageBytes);

  Stream<String> sendChatStream({
    required String newUserContent,
    required List<ChatMessage> history,
    Uint8List? imageBytes,
    String? sessionId,
    void Function(String toolName, String query)? onToolCall,
    Future<Uint8List?> Function()? onCapturePhoto,
    bool isDialogueIntentMode = false,
    bool isInContinuousMode = false,
  });

  Future<String> sendChat({
    required List<ChatMessage> history,
    required String newUserContent,
    String? sessionId,
    Uint8List? imageBytes,
  });
}

/// 大模型工厂注册表 (Composition Root SPI 扩展点)
class LlmFactoryRegistry {
  static LlmPort Function(dynamic settings)? defaultFactory;
}

/// 纯内存/空操作大模型兜底实现
class NoopLlmPort implements LlmPort {
  const NoopLlmPort();

  @override
  void applyConfig(LlmConfig config) {}

  @override
  Future<String?> describeImage(Uint8List imageBytes) async => null;

  @override
  Stream<String> sendChatStream({
    required String newUserContent,
    required List<ChatMessage> history,
    Uint8List? imageBytes,
    String? sessionId,
    void Function(String toolName, String query)? onToolCall,
    Future<Uint8List?> Function()? onCapturePhoto,
    bool isDialogueIntentMode = false,
    bool isInContinuousMode = false,
  }) async* {
    yield '{"intent":"chat","should_reply":true,"reply":"[Noop]"}';
  }

  @override
  Future<String> sendChat({
    required List<ChatMessage> history,
    required String newUserContent,
    String? sessionId,
    Uint8List? imageBytes,
  }) async =>
      '{"intent":"chat","should_reply":true,"reply":"[Noop]"}';
}

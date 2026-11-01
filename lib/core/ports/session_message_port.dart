import 'dart:typed_data';

import '../models/chat_message.dart';
import '../models/chat_session.dart';
import 'knowledge_port.dart';

export '../models/chat_message.dart';
export '../models/chat_session.dart';

/// 消息对元组记录（包含新增的用户消息ID、占位助手消息ID及其索引）
typedef AppendedMessagePair = ({
  String userMsgId,
  String assistantMsgId,
  int assistantMsgIndex,
});

/// 会话状态与增量消息管理契约端口 (Session Message Port)
///
/// 遵循接口隔离原则 (ISP)，将活动会话标识获取、消息历史检索、
/// 用户/助手消息原子追加与流式内容更新、图片持久化及生命周期切换
/// 从具体会话管理中抽象为轻量级契约。
/// 对话编排协调器只依赖此端口，与具体的会话持久化与导出解耦。
/// 纯 Dart 契约，零 `dart:ui` 或 `package:flutter` 依赖。
abstract interface class SessionMessagePort {
  /// 当前活动会话 ID
  String get currentSessionId;

  /// 当前活动会话的全量消息快照
  List<ChatMessage> get messages;

  /// 原子追加用户消息与助手空白占位消息
  ///
  /// 返回元组记录 [AppendedMessagePair]，包含用户消息 ID、助手消息 ID 及其在列表中的首选索引。
  AppendedMessagePair appendUserAndPlaceholderMessage(
    String userText, {
    String? imagePath,
  });

  /// 流式增量更新指定助手消息的内容
  ///
  /// [assistantMsgId] 助手消息唯一标识。
  /// [preferredIndex] 首选索引，优先以 O(1) 命中更新；若不匹配则自动全量查找。
  /// [content] 最新累积的助手文本。
  /// [isStreaming] 是否正在流式生成中。
  void updateAssistantMessageContent(
    String assistantMsgId,
    int preferredIndex,
    String content, {
    bool isStreaming = false,
  });

  /// 更新指定消息的关联多模态图片路径
  void updateMessageImagePath(String messageId, String imagePath);

  /// 持久化多模态图片至应用数据目录并返回安全存储路径
  Future<String?> persistImage({
    required String sessionId,
    required String messageId,
    String? sourcePath,
    Uint8List? imageBytes,
  });

  /// 同步持久化当前活动会话
  Future<ChatSession?> syncCurrentSession({bool persist = true});

  /// 开启全新会话并自动归档当前会话
  Future<ChatSession?> startNewSession();

  /// 切换当前活动会话
  Future<ChatSession?> switchSession(String sessionId);

  /// 更新关联的知识库/LightRAG 归档服务引用
  void updateLightRagService(KnowledgePort? service);
}

import '../models/chat_session.dart';

/// 外部知识库/知识图谱服务端口 (Knowledge Port)
///
/// 定义历史会话自动归档与知识增强检索的交互契约。
abstract interface class KnowledgePort {
  Future<void> retryPending();
  Future<void> archiveSession(ChatSession session);

  /// 检索知识库上下文，仅返回检索到的上下文纯文本（交由大模型组织回答）
  ///
  /// [query] 检索查询语句或关键词。
  /// [mode] 检索模式，默认 `'mix'`（图谱+向量混合；亦支持 `'local'`、`'global'`、`'naive'` 等；兼容 `'hybrid'` 别名）。
  Future<String> queryContext(String query, {String mode = 'mix'});
}

/// 知识库服务工厂注册表 (Composition Root SPI 扩展点)
class KnowledgeFactoryRegistry {
  static KnowledgePort Function({
    required String baseUrl,
    required Future<String?> Function(dynamic imageBytes) describeImage,
  })? defaultFactory;
}

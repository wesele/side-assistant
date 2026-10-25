import 'chat_message.dart';

class ChatSession {
  final String id;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<ChatMessage> messages;

  ChatSession({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    required List<ChatMessage> messages,
  }) : messages = List.unmodifiable(messages);

  /// 截取首条用户消息前 20 个字符作为默认标题
  static String generateDefaultTitle(String firstUserMessage) {
    final normalized =
        firstUserMessage.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.isEmpty) return '新对话';
    final runes = normalized.runes.toList();
    if (runes.length <= 20) {
      return normalized;
    }
    return String.fromCharCodes(runes.take(20));
  }

  /// 检查会话标题或任意消息内容是否匹配搜索关键字
  bool matchesQuery(String rawQuery) {
    final q = rawQuery.trim().toLowerCase();
    if (q.isEmpty) return true;
    if (title.toLowerCase().contains(q)) return true;
    for (final msg in messages) {
      if (msg.content.toLowerCase().contains(q)) return true;
    }
    return false;
  }

  ChatSession copyWith({
    String? id,
    String? title,
    DateTime? createdAt,
    DateTime? updatedAt,
    List<ChatMessage>? messages,
  }) {
    return ChatSession(
      id: id ?? this.id,
      title: title ?? this.title,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      messages: messages ?? this.messages,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'messages': messages.map((m) => m.toMap()).toList(),
    };
  }

  factory ChatSession.fromMap(Map<String, dynamic> map) {
    final rawMessages = (map['messages'] as List<dynamic>?) ?? const [];
    final parsedCreated = DateTime.tryParse((map['createdAt'] as String?) ?? '') ??
        DateTime.now();
    final parsedUpdated = DateTime.tryParse((map['updatedAt'] as String?) ?? '') ??
        parsedCreated;
    return ChatSession(
      id: map['id'] as String,
      title: (map['title'] as String?)?.trim().isNotEmpty == true
          ? map['title'] as String
          : '新对话',
      createdAt: parsedCreated,
      updatedAt: parsedUpdated,
      messages: rawMessages
          .whereType<Map<String, dynamic>>()
          .map(ChatMessage.fromMap)
          .toList(),
    );
  }
}

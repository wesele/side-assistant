class ChatMessage {
  final String id;
  final String role; // 'system', 'user', 'assistant'
  final String content;
  final DateTime timestamp;
  final String? sessionId;

  ChatMessage({
    required this.id,
    required this.role,
    required this.content,
    required this.timestamp,
    this.sessionId,
  });

  Map<String, dynamic> toOpenAiMessage() {
    return {
      'role': role,
      'content': content,
    };
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'role': role,
      'content': content,
      'timestamp': timestamp.toIso8601String(),
      'sessionId': sessionId,
    };
  }

  factory ChatMessage.fromMap(Map<String, dynamic> map) {
    return ChatMessage(
      id: map['id'] as String,
      role: map['role'] as String,
      content: map['content'] as String,
      timestamp: DateTime.parse(map['timestamp'] as String),
      sessionId: map['sessionId'] as String?,
    );
  }
}

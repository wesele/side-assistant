class ChatMessage {
  final String id;
  final String role; // 'system', 'user', 'assistant'
  final String content;
  final DateTime timestamp;
  final String? sessionId;
  final String? imagePath;
  final bool isUnintended;

  ChatMessage({
    required this.id,
    required this.role,
    required this.content,
    required this.timestamp,
    this.sessionId,
    this.imagePath,
    this.isUnintended = false,
  });

  ChatMessage copyWith({
    String? id,
    String? role,
    String? content,
    DateTime? timestamp,
    String? sessionId,
    String? imagePath,
    bool? isUnintended,
  }) {
    return ChatMessage(
      id: id ?? this.id,
      role: role ?? this.role,
      content: content ?? this.content,
      timestamp: timestamp ?? this.timestamp,
      sessionId: sessionId ?? this.sessionId,
      imagePath: imagePath ?? this.imagePath,
      isUnintended: isUnintended ?? this.isUnintended,
    );
  }

  Map<String, dynamic> toOpenAiMessage() {
    return {
      'role': role,
      'content': isUnintended ? '[背景信息（无交谈意图）] $content' : content,
    };
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'role': role,
      'content': content,
      'timestamp': timestamp.toIso8601String(),
      'sessionId': sessionId,
      'imagePath': imagePath,
      'isUnintended': isUnintended,
    };
  }

  factory ChatMessage.fromMap(Map<String, dynamic> map) {
    return ChatMessage(
      id: map['id'] as String,
      role: map['role'] as String,
      content: map['content'] as String,
      timestamp: DateTime.parse(map['timestamp'] as String),
      sessionId: map['sessionId'] as String?,
      imagePath: map['imagePath'] as String?,
      isUnintended: map['isUnintended'] == true,
    );
  }
}

/// 自定义工具清单元数据模型 (CustomToolManifest)
///
/// 描述用户或 OpenCode 生成的持久化自定义工具的基础规格。
/// 严格遵循纯 Dart 无头规范，禁止依赖 UI 或服务层组件。
class CustomToolManifest {
  /// 工具唯一英文名称/标识符（例如: 'alarm_clock', 'weather_report'）
  final String name;

  /// 工具简短功能描述，用于向大模型提示其用途
  final String summary;

  /// 参数提示与格式说明（例如: 'time: HH:mm, message: 提醒内容'）
  final String parametersHint;

  /// 宿主系统执行该工具的命令模板（例如: 'python3 run.py' 或 'bash run.sh'）
  final String command;

  /// 工具创建时间（ISO 8601 字符串）
  final String createdAt;

  const CustomToolManifest({
    required this.name,
    required this.summary,
    required this.command,
    this.parametersHint = '',
    this.createdAt = '',
  });

  /// 验证工具名称合法性的正则表达式（仅允许 1-64 位的英文字母、数字、下划线及连字符，杜绝路径穿越）
  static final RegExp validNameRegex = RegExp(r'^[a-zA-Z0-9_-]{1,64}$');

  /// 判断给定名称是否为合法的安全工具名
  static bool isValidToolName(String name) =>
      validNameRegex.hasMatch(name.trim());

  /// 从 Map 解析构建清单对象
  factory CustomToolManifest.fromMap(Map<String, dynamic> map) {
    return CustomToolManifest(
      name: (map['name'] as String?)?.trim() ?? '',
      summary: (map['summary'] as String?)?.trim() ?? '',
      command: (map['command'] as String?)?.trim() ?? '',
      parametersHint:
          ((map['parametersHint'] ?? map['parameters_hint']) as String?)
                  ?.trim() ??
              '',
      createdAt:
          ((map['createdAt'] ?? map['created_at']) as String?)?.trim() ?? '',
    );
  }

  /// 转换为 Map 结构，便于序列化为 tool.json
  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'summary': summary,
      'parametersHint': parametersHint,
      'command': command,
      'createdAt': createdAt,
    };
  }

  /// 转换为提示词单行摘要文本
  String toPromptLine() {
    final hint = parametersHint.trim();
    return '- $name: $summary${hint.isNotEmpty ? ' (参数: $hint)' : ''}';
  }

  /// 拷贝并更新属性
  CustomToolManifest copyWith({
    String? name,
    String? summary,
    String? parametersHint,
    String? command,
    String? createdAt,
  }) {
    return CustomToolManifest(
      name: name ?? this.name,
      summary: summary ?? this.summary,
      parametersHint: parametersHint ?? this.parametersHint,
      command: command ?? this.command,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CustomToolManifest &&
          runtimeType == other.runtimeType &&
          name == other.name &&
          summary == other.summary &&
          parametersHint == other.parametersHint &&
          command == other.command &&
          createdAt == other.createdAt;

  @override
  int get hashCode => Object.hash(
        name,
        summary,
        parametersHint,
        command,
        createdAt,
      );

  @override
  String toString() =>
      'CustomToolManifest(name: $name, summary: $summary, command: $command, parametersHint: $parametersHint, createdAt: $createdAt)';
}

import 'dart:convert';

import '../../../core/models/app_settings.dart';
import '../../../core/ports/llm_tool.dart';

/// 记录背景语音（无交谈意图）工具适配器 (RecordBackgroundSpeechTool)
///
/// 当判定主人并非在对助手交谈时调用，将听到的文本作为背景信息记录并保持静默。
class RecordBackgroundSpeechTool implements LlmTool {
  const RecordBackgroundSpeechTool();

  @override
  String get name => 'record_background_speech';

  static const Map<String, dynamic> toolDefinition = {
    'type': 'function',
    'function': {
      'name': 'record_background_speech',
      'description':
          '当判定主人并非在对你说话（如与他人交谈、打电话、自言自语、背景旁白等无交谈意图）时调用，将听到的文本作为背景信息记录并保持静默不回答。',
      'parameters': {
        'type': 'object',
        'properties': {
          'text': {
            'type': 'string',
            'description': '探测到的背景语音/旁白文本',
          },
          'reason': {
            'type': 'string',
            'description': '判定为无交谈意图的简短原因',
          },
        },
        'required': ['text'],
      },
    },
  };

  @override
  Map<String, dynamic> get definition => toolDefinition;

  @override
  bool isEnabled(AppSettings settings, {LlmToolContext? context}) {
    return context?.extra['isDialogueIntentMode'] == true;
  }

  @override
  Future<String> execute(String rawArguments, {LlmToolContext? context}) async {
    final text = extractText(rawArguments);
    return '已记录背景语音: $text';
  }

  /// 健壮提取 text 参数
  static String extractText(String rawArguments) {
    final trimmed = rawArguments.trim();
    if (trimmed.isEmpty) return '';
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map) {
        final t = decoded['text'] ?? decoded['speech'] ?? decoded['content'];
        if (t != null) return t.toString().trim();
      } else if (decoded is String) {
        return decoded.trim();
      }
    } catch (_) {
      final match = RegExp(r'"text"\s*:\s*"([^"]+)"').firstMatch(trimmed);
      if (match != null) {
        return match.group(1)!.trim();
      }
    }
    return trimmed;
  }
}

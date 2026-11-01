/// 触发类型枚举
enum TriggerType {
  none,
  start,
  end,
  reset,
}

/// 触发词匹配结果数据结构
class TriggerMatchResult {
  final TriggerType type;
  final String matchedText;
  final int startIndex;
  final int endIndex;
  final double similarity;
  final String method; // 'exact', 'pinyin', 'semantic_vector'

  TriggerMatchResult({
    required this.type,
    required this.matchedText,
    required this.similarity,
    required this.method,
    this.startIndex = -1,
    this.endIndex = -1,
  });

  factory TriggerMatchResult.none() {
    return TriggerMatchResult(
      type: TriggerType.none,
      matchedText: '',
      similarity: 0.0,
      method: 'none',
      startIndex: -1,
      endIndex: -1,
    );
  }

  bool get isMatched => type != TriggerType.none;
}

/// 一句话完整提问（单次一并包含开始词、提问内容、结束词）
class ExtractedCommand {
  final String startWord;
  final String promptContent;
  final String endWord;

  const ExtractedCommand({
    required this.startWord,
    required this.promptContent,
    required this.endWord,
  });
}

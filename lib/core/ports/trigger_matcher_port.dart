import '../models/trigger_result.dart';

export '../models/trigger_result.dart';

/// 唤醒词与控制指令匹配器端口 (Trigger Matcher Port)
///
/// 定义唤醒词、结束词、连续对话控制指令的匹配与抽取契约。
abstract interface class TriggerMatcherPort {
  List<String> get startWords;
  void warmUp();
  Future<TriggerMatchResult> checkStartWord(String candidate);
  Future<TriggerMatchResult> checkEndWord(String candidate);
  Future<TriggerMatchResult> checkResetWord(String candidate);
  Future<bool> checkExitContinuousWord(String candidate);
  String stripEndWord(String fullText);
  String stripPunctuation(String text, {bool all = false});
  Future<ExtractedCommand?> extractOneShotCommand(String sentence);
}

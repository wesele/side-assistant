import '../../../core/platform/foundation_bridge.dart';
import '../asr_service.dart';
import 'tse_applier.dart';

/// 两遍解码的第二遍：流式端点命中后，用内置 SenseVoice 对整段音频复检。
///
/// 职责边界：
/// - 判断复检是否可跑（第二遍识别器已就绪、未在复检中、音频足够长）；
/// - 复检前跑一次 TSE，并丢弃被 TSE 置零的结果；
/// - 把复检文本通过 [onFinalTranscript] 抛给上层（由上层决定是否采用）。
///
/// 不负责：何时触发复检（端点判定/缓冲重置仍留在 `VoiceListeningService`）。
class FinalPassRunner {
  FinalPassRunner({
    required this.finalAsrService,
    required this.tse,
    this.onFinalTranscript,
  });

  /// 第二遍识别器；运行期可被替换，必须每次读取。
  final AsrService? Function() finalAsrService;
  final TseApplier tse;
  final void Function(String text)? onFinalTranscript;

  bool _busy = false;

  /// 流式负责“快”，内置 SenseVoice 负责“准”。
  Future<void> run(Float32List audio) async {
    final finalAsr = finalAsrService();
    if (finalAsr == null || !finalAsr.isReady) return;
    if (_busy) return;
    if (audio.length < 16000 * 0.2) return;

    _busy = true;
    final sw = Stopwatch()..start();
    try {
      final processedAudio = tse.apply(audio);
      if (TseApplier.isZeroed(processedAudio)) return;
      final text = await finalAsr.transcribeSamples(
        processedAudio,
        sampleRate: 16000,
        fromVad: true,
      );
      sw.stop();
      if (text.isNotEmpty) {
        debugPrint(
          '[VoiceListeningService] 两遍解码复检完成 (${finalAsr.engineName}, '
          '${audio.length ~/ 16}ms, 耗时 ${sw.elapsedMilliseconds}ms): "$text"',
        );
        onFinalTranscript?.call(text);
      }
    } catch (e, st) {
      debugPrint('[VoiceListeningService] 两遍解码异常: $e\n$st');
    } finally {
      _busy = false;
    }
  }
}

import 'pcm_audio_utils.dart';

/// 麦克风电平状态：最近一次 RMS/dBFS/电平与 VAD 指示，附带发射节流。
///
/// 职责边界：
/// - 缓存 [level]/[dbfs]/[vadDetected] 供 `VoiceListeningPort` 直接读取；
/// - 决定是否需要向外抛一次电平事件（VAD 翻转，或距上次发射 ≥90ms），
///   避免每 20~40ms 一个 PCM 包都把 UI 刷一遍。
///
/// 不负责：RMS 计算（见 [PcmAudioUtils]）与 VAD 判定本身。
class MicLevelState {
  double _level = 0.0;
  double _dbfs = -60.0;
  bool _vadDetected = false;
  DateTime _lastEmitAt = DateTime.fromMillisecondsSinceEpoch(0);

  double get level => _level;
  double get dbfs => _dbfs;
  bool get vadDetected => _vadDetected;

  /// 写入一次采样结果，返回是否应当向外发射电平事件。
  bool update(AudioLevel audio, bool vadDetected) {
    final now = DateTime.now();
    final vadChanged = vadDetected != _vadDetected;
    _level = audio.level;
    _dbfs = audio.dbfs;
    _vadDetected = vadDetected;
    if (!vadChanged && now.difference(_lastEmitAt).inMilliseconds < 90) {
      return false;
    }
    _lastEmitAt = now;
    return true;
  }

  /// 停止采集时归零。
  void reset() {
    _level = 0.0;
    _dbfs = -60.0;
    _vadDetected = false;
  }
}

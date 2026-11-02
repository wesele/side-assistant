/// 模型资产可用性判定（供需要真实 ONNX 的测试统一使用）。
///
/// 背景：仓库用 Git LFS 管理 `assets/models/**/*.onnx`。在没有执行
/// `git lfs pull` 的环境（典型如 CI 的 `actions/checkout` 未开 `lfs: true`）里，
/// 这些路径上落地的是一个约 130 字节的指针文本文件，而不是模型本体。
///
/// 此时依赖模型的测试会以「模型缺失 → 初始化静默失败 → 断言拿到空结果」的方式
/// 挂掉，报错信息（如 `Expected: non-empty / Actual: []`）完全指不到根因，
/// 对人和 AI Agent 都是纯噪声。正确做法是**显式 skip**，让报告里出现 `~N`，
/// 一眼看出「不是代码坏了，是资产没拉」。
library;

import 'dart:io';

/// 判定 [path] 是否是一个"真实的"资产文件（而非 LFS 指针或空文件）。
///
/// 默认阈值 4KB：最小的模型（silero_vad.onnx）也有 600KB+，
/// 而 LFS 指针固定 ~130 字节，两者不会混淆。
bool hasRealAsset(String path, {int minBytes = 4096}) {
  final file = File(path);
  return file.existsSync() && file.lengthSync() > minBytes;
}

/// 资产缺失时的统一跳过原因（`skip:` 传字符串即跳过理由）。
const String kSkipNoModel = '需要真实模型文件：未执行 git lfs pull 时该路径只是 LFS 指针';

/// 常用资产路径常量，避免各测试文件里手写字符串。
const String kSileroVad = 'assets/models/silero_vad.onnx';
const String kSenseVoiceModel = 'assets/models/sense-voice/model.int8.onnx';
const String kSenseVoiceTokens = 'assets/models/sense-voice/tokens.txt';
const String kCampplusSpeakerModel =
    'assets/models/speaker/3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx';
const String kZipformerEncoder =
    'assets/models/streaming-zipformer/encoder-epoch-99-avg-1.int8.onnx';
const String kZipformerDecoder =
    'assets/models/streaming-zipformer/decoder-epoch-99-avg-1.onnx';
const String kZipformerJoiner =
    'assets/models/streaming-zipformer/joiner-epoch-99-avg-1.int8.onnx';

/// 直接传给 `test(..., skip: ...)` / `group(..., skip: ...)` 的便捷写法。
Object? skipUnlessAsset(String path) =>
    hasRealAsset(path) ? false : kSkipNoModel;

/// 多个资产必须同时可用时才不跳过（例如 SenseVoice 需要 model + tokens）。
Object? skipUnlessAssets(List<String> paths) =>
    paths.every(hasRealAsset) ? false : kSkipNoModel;

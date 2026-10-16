import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;
import '../../core/models/app_settings.dart';
import 'mfcc_dtw_filter.dart';

abstract class AsrService {
  Future<String> transcribeAudioFile(String filePath, {bool isStandbyWakeCheck = false});
}

/// 基于 OpenAI 规范的云端 Whisper 语音转文字服务
class CloudWhisperAsrService implements AsrService {
  final AppSettings settings;

  CloudWhisperAsrService({required this.settings});

  @override
  Future<String> transcribeAudioFile(String filePath, {bool isStandbyWakeCheck = false}) async {
    final file = File(filePath);
    if (!await file.exists()) {
      return '';
    }

    final baseUrl = settings.openAiBaseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final url = Uri.parse('$baseUrl/audio/transcriptions');

    final request = http.MultipartRequest('POST', url);
    if (settings.openAiApiKey.isNotEmpty) {
      request.headers['Authorization'] = 'Bearer ${settings.openAiApiKey}';
    }

    request.fields['model'] = 'whisper-1';
    request.fields['language'] = 'zh';
    request.files.add(await http.MultipartFile.fromPath('file', filePath));

    final streamedResponse = await request.send().timeout(const Duration(seconds: 15));
    final response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode >= 200 && response.statusCode < 300) {
      final data = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      return (data['text'] as String?)?.trim() ?? '';
    } else {
      throw Exception('ASR API Error ${response.statusCode}: ${response.body}');
    }
  }
}

/// 本地 SenseVoice / Sherpa-ONNX 离线语音识别服务
class LocalSenseVoiceAsrService implements AsrService {
  final AppSettings settings;
  sherpa_onnx.OfflineRecognizer? _recognizer;
  bool _isInitializing = false;
  bool _isReady = false;

  LocalSenseVoiceAsrService({required this.settings});

  bool get isReady => _isReady;

  Future<void> initialize() async {
    if (_isReady || _isInitializing) return;
    _isInitializing = true;

    try {
      if (Platform.isWindows) {
        // 尝试预加载 bundled onnxruntime.dll 避免与 Windows System32 旧版 DLL 冲突
        final currentDir = Directory.current.path;
        final possibleOrtDlls = [
          '$currentDir\\onnxruntime.dll',
          r'C:\Users\wh101\AppData\Local\Pub\Cache\hosted\pub.dev\sherpa_onnx_windows-1.13.8\windows\onnxruntime.dll',
        ];
        for (final p in possibleOrtDlls) {
          if (File(p).existsSync()) {
            try {
              DynamicLibrary.open(p);
              break;
            } catch (_) {}
          }
        }
      }

      sherpa_onnx.initBindings();

      // 定位模型文件
      final modelPaths = await _resolveModelFiles();
      final modelPath = modelPaths['model']!;
      final tokensPath = modelPaths['tokens']!;
      debugPrint('[LocalSenseVoiceAsrService] 准备加载模型: modelPath=$modelPath (${File(modelPath).existsSync()}), tokensPath=$tokensPath');

      if (!File(modelPath).existsSync() || !File(tokensPath).existsSync()) {
        debugPrint('[LocalSenseVoiceAsrService] 模型或词表文件不存在，初始化中止');
        _isInitializing = false;
        return;
      }

      final modelConfig = sherpa_onnx.OfflineModelConfig(
        senseVoice: sherpa_onnx.OfflineSenseVoiceModelConfig(
          model: modelPath,
          language: 'zh',
          useInverseTextNormalization: true,
        ),
        tokens: tokensPath,
        modelType: 'sense_voice',
        numThreads: 2,
      );

      _recognizer = sherpa_onnx.OfflineRecognizer(
        sherpa_onnx.OfflineRecognizerConfig(model: modelConfig),
      );
      _isReady = true;
      debugPrint('[LocalSenseVoiceAsrService] SenseVoice 离线识别器初始化成功！');
    } catch (e, st) {
      debugPrint('[LocalSenseVoiceAsrService] 初始化异常: $e\n$st');
      _isReady = false;
    } finally {
      _isInitializing = false;
    }
  }

  Future<Map<String, String>> _resolveModelFiles() async {
    // 1. 优先检查相对工程目录 assets (桌面)
    const directModel = 'assets/models/sense-voice/model.int8.onnx';
    const directTokens = 'assets/models/sense-voice/tokens.txt';

    if (File(directModel).existsSync() && File(directTokens).existsSync()) {
      debugPrint('[LocalSenseVoiceAsrService] 命中相对工程目录模型: $directModel');
      return {'model': directModel, 'tokens': directTokens};
    }

    // 2. 检查沙盒目录 (移动端应用内部存储)
    final appDir = await getApplicationDocumentsDirectory();
    final localModel = File('${appDir.path}/sense-voice/model.int8.onnx');
    final localTokens = File('${appDir.path}/sense-voice/tokens.txt');

    if (localModel.existsSync() && localTokens.existsSync() && localModel.lengthSync() > 10000000) {
      debugPrint('[LocalSenseVoiceAsrService] 命中沙盒目录模型: ${localModel.path}');
      return {'model': localModel.path, 'tokens': localTokens.path};
    }

    // 3. 检查公共下载目录 (/sdcard/Download/sense-voice)
    final sdModel = File('/sdcard/Download/sense-voice/model.int8.onnx');
    final sdTokens = File('/sdcard/Download/sense-voice/tokens.txt');
    if (sdModel.existsSync() && sdTokens.existsSync()) {
      debugPrint('[LocalSenseVoiceAsrService] 命中公共存储模型: ${sdModel.path}');
      return {'model': sdModel.path, 'tokens': sdTokens.path};
    }

    // 4. 若直接路径不存在，尝试从 rootBundle 提取
    if (!localModel.existsSync() || !localTokens.existsSync() || localModel.lengthSync() < 10000000) {
      localModel.parent.createSync(recursive: true);
      try {
        debugPrint('[LocalSenseVoiceAsrService] 正在从资产包解压 SenseVoice 模型到沙盒...');
        final modelBytes = await rootBundle.load('assets/models/sense-voice/model.int8.onnx');
        await localModel.writeAsBytes(modelBytes.buffer.asUint8List());
        final tokenBytes = await rootBundle.load('assets/models/sense-voice/tokens.txt');
        await localTokens.writeAsBytes(tokenBytes.buffer.asUint8List());
        debugPrint('[LocalSenseVoiceAsrService] 解压 SenseVoice 模型完成！');
      } catch (e) {
        debugPrint('[LocalSenseVoiceAsrService] 解压模型失败: $e');
      }
    }

    return {'model': localModel.path, 'tokens': localTokens.path};
  }

  @override
  Future<String> transcribeAudioFile(String filePath, {bool isStandbyWakeCheck = false}) async {
    if (!_isReady) {
      await initialize();
    }
    if (_recognizer == null) {
      return '';
    }

    final file = File(filePath);
    if (!await file.exists()) {
      return '';
    }

    try {
      final wave = sherpa_onnx.readWave(filePath);
      if (wave.samples.isEmpty) return '';

      // PCM RMS 与 Peak 能量门控：过滤环境底噪与静音，避免无谓消耗 ONNX 神经网络推理 CPU
      double sumSq = 0.0;
      double peak = 0.0;
      final samples = wave.samples;
      final len = samples.length;
      for (int i = 0; i < len; i++) {
        final absVal = samples[i].abs();
        if (absVal > peak) peak = absVal;
        sumSq += absVal * absVal;
      }
      final rms = len > 0 ? math.sqrt(sumSq / len) : 0.0;
      if (peak < 0.015 && rms < 0.005) {
        // 判定为纯静音或极低环境底噪，直接跳过
        return '';
      }

      // 第二级前置低功耗声学过滤（MFCC + Subsequence DTW）：在待机待唤醒阶段，若声学轨迹与“小曼”模板完全无关则直接阻断，跳过 SenseVoice 解码
      if (isStandbyWakeCheck && settings.enableAcousticWakeFilter) {
        final isPlausible = MfccDtwFilter.checkPlausibleWake(wave.samples);
        if (!isPlausible) {
          debugPrint('[LocalSenseVoiceAsrService] 待机声学过滤器判断不含唤醒特征，跳过神经网络推理');
          return '';
        }
      }

      debugPrint('[LocalSenseVoiceAsrService] 开始推理音频切片: len=$len, peak=${peak.toStringAsFixed(4)}, rms=${rms.toStringAsFixed(4)}');
      final stream = _recognizer!.createStream();
      stream.acceptWaveform(samples: wave.samples, sampleRate: wave.sampleRate);
      _recognizer!.decode(stream);
      final rawResult = _recognizer!.getResult(stream).text;
      stream.free();

      // 去除 SenseVoice 可能携带的标签如 <|zh|>, <|NEUTRAL|>, <|Speech|>
      final cleaned = rawResult.replaceAll(RegExp(r'<\|[^>]+?>'), '').trim();
      debugPrint('[LocalSenseVoiceAsrService] 识别完成 -> 结果: "$cleaned" (原始: "$rawResult")');
      return cleaned;
    } catch (e, st) {
      debugPrint('[LocalSenseVoiceAsrService] 识别过程异常: $e\n$st');
      return '';
    }
  }

  void dispose() {
    _recognizer?.free();
    _recognizer = null;
    _isReady = false;
  }
}

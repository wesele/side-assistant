@Tags(['benchmark'])
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;
import 'package:side_assistant/core/constants/app_constants.dart';
import 'package:side_assistant/core/models/app_settings.dart';
import 'package:side_assistant/services/speech/asr_service.dart';
import 'package:side_assistant/services/speech/gemini_live_asr_service.dart';

import '../tool/cer.dart' as cer;

/// ASR CER 基准测试。
///
/// 用法（PowerShell）：
///   $env:ASR_BENCH_DIR="tool/asr_benchmark_data"
///   $env:ASR_BENCH_ENGINE="sensevoice"   # sensevoice | streaming | gemini_live
///   $env:GEMINI_API_KEY="..."            # gemini_live 可选，留空用内置默认 Key
///   flutter test --tags benchmark test/asr_cer_benchmark_test.dart
///
/// 数据目录格式：
///   manifest.json:
///   [
///     {"wav": "001.wav", "ref": "今天天气怎么样", "wake": false},
///     {"wav": "002.wav", "ref": "晓漫", "wake": true}
///   ]
///
/// 未设置 `ASR_BENCH_DIR`（或目录下没有 manifest.json）时该用例会被标记为
/// skipped 而非通过。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final benchDir = Platform.environment['ASR_BENCH_DIR']?.trim() ?? '';
  final manifestFile = File('$benchDir/manifest.json');
  final String? skipReason = benchDir.isEmpty
      ? '需要 ASR_BENCH_DIR（本地基准数据目录）'
      : (manifestFile.existsSync() ? null : '需要 $benchDir/manifest.json');

  test('ASR CER benchmark', () async {
    if (Platform.isWindows) {
      const ortDll =
          r'C:\Users\wh101\AppData\Local\Pub\Cache\hosted\pub.dev\sherpa_onnx_windows-1.13.8\windows\onnxruntime.dll';
      const sherpaDll =
          r'C:\Users\wh101\AppData\Local\Pub\Cache\hosted\pub.dev\sherpa_onnx_windows-1.13.8\windows\sherpa-onnx-c-api.dll';
      if (File(ortDll).existsSync()) {
        try {
          DynamicLibrary.open(ortDll);
        } catch (_) {}
      }
      if (File(sherpaDll).existsSync()) {
        try {
          DynamicLibrary.open(sherpaDll);
        } catch (_) {}
      }
    }
    sherpa_onnx.initBindings();

    final engine =
        (Platform.environment['ASR_BENCH_ENGINE'] ?? 'sensevoice').trim();
    final envGeminiKey = Platform.environment['GEMINI_API_KEY']?.trim() ?? '';
    final envGeminiModel =
        Platform.environment['GEMINI_ASR_MODEL']?.trim() ?? '';
    final settings = AppSettings(
      asrEngine: engine,
      geminiApiKey: envGeminiKey.isEmpty
          ? AppConstants.defaultGeminiApiKey
          : envGeminiKey,
      geminiAsrModel: envGeminiModel.isEmpty
          ? AppConstants.defaultGeminiAsrModel
          : envGeminiModel,
    );

    final AsrService asr;
    switch (engine) {
      case AppConstants.asrEngineStreaming:
        asr = StreamingZipformerAsrService(settings: settings);
        break;
      case AppConstants.asrEngineGeminiLive:
        asr = GeminiLiveAsrService(settings: settings);
        break;
      case AppConstants.asrEngineSenseVoice:
      default:
        asr = LocalSenseVoiceAsrService(settings: settings);
        break;
    }

    await asr.initialize();
    if (!asr.isReady) {
      markTestSkipped('${asr.engineName} 未就绪（模型缺失？）');
      return;
    }

    final items = (jsonDecode(manifestFile.readAsStringSync()) as List)
        .cast<Map<String, dynamic>>();
    if (items.isEmpty) {
      markTestSkipped('manifest 为空');
      return;
    }

    var totalCer = 0.0;
    var exact = 0;
    var wakeHit = 0;
    var wakeTotal = 0;
    final rows = <String>[];

    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      final wavName = (item['wav'] as String?) ?? '';
      final ref = (item['ref'] as String?) ?? '';
      final wav = File('$benchDir/$wavName');
      if (!wav.existsSync()) {
        rows.add('#${i + 1} 跳过（文件缺失）: $wavName');
        continue;
      }

      final sw = Stopwatch()..start();
      final hyp = await asr.transcribeAudioFile(wav.path);
      sw.stop();

      final value = cer.characterErrorRate(ref, hyp);
      totalCer += value;
      if (cer.isExactMatch(ref, hyp)) exact++;

      if (item['wake'] == true) {
        wakeTotal++;
        if (hyp.contains(settings.startWord) ||
            hyp.contains('晓漫') ||
            hyp.contains('小曼')) {
          wakeHit++;
        }
      }

      rows.add(
        '#${i + 1} CER ${(value * 100).toStringAsFixed(2)}% '
        '(${sw.elapsedMilliseconds}ms)\n'
        '   ref: $ref\n'
        '   hyp: $hyp',
      );
    }

    // ignore: avoid_print
    print('\n===== ASR CER Benchmark (${asr.engineName}) =====');
    for (final row in rows) {
      // ignore: avoid_print
      print(row);
    }
    // ignore: avoid_print
    print('-----------------------------------------------');
    // ignore: avoid_print
    print('样本数: ${items.length}');
    // ignore: avoid_print
    print('平均 CER: ${(totalCer / items.length * 100).toStringAsFixed(2)}%');
    // ignore: avoid_print
    print('整句准确率: ${(exact / items.length * 100).toStringAsFixed(2)}%');
    if (wakeTotal > 0) {
      // ignore: avoid_print
      print(
          '唤醒词命中率: ${(wakeHit / wakeTotal * 100).toStringAsFixed(2)}% ($wakeHit/$wakeTotal)');
    }

    final maxCer = double.tryParse(
      Platform.environment['ASR_BENCH_MAX_CER'] ?? '',
    );
    if (maxCer != null) {
      expect(
        totalCer / items.length,
        lessThanOrEqualTo(maxCer),
        reason: '平均 CER 超过阈值 $maxCer',
      );
    }

    asr.dispose();
  }, timeout: const Timeout(Duration(minutes: 10)), skip: skipReason);
}

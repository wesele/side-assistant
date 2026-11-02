import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:side_assistant/controllers/assistant_controller.dart';
import 'package:side_assistant/core/constants/app_constants.dart';
import 'package:side_assistant/core/models/app_settings.dart';
import 'package:side_assistant/core/ports/asr_port.dart';
import 'package:side_assistant/services/speech/asr_service.dart';

/// 轮询等待识别器加载完成（模型较大，初始化是异步的）。
Future<void> _waitUntilReady(AsrPort asr, {int timeoutSeconds = 90}) async {
  final sw = Stopwatch()..start();
  while (!asr.isReady && sw.elapsed.inSeconds < timeoutSeconds) {
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // AudioRecorder 构造/释放时会在后台异步调用 record 插件，纯测试环境无实现会抛
  // MissingPluginException。这里用 mock 让 AssistantController 能正常构造与销毁。
  const recordChannel = MethodChannel('com.llfbandit.record/messages');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(recordChannel, (MethodCall call) async => null);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(recordChannel, null);
  });

  /// 在测试体内显式销毁，确保 record mock 仍然生效。
  Future<void> disposeController(AssistantController controller) async {
    controller.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }

  group('语音识别引擎可选配置', () {
    test('默认使用高精度离线 SenseVoice 引擎', () async {
      final settings = AppSettings();
      expect(settings.asrEngine, equals(AppConstants.asrEngineSenseVoice));

      final controller = AssistantController(settings: settings, enableDriverServer: false);
      expect(controller.asrService, isA<LocalSenseVoiceAsrService>());
      expect(controller.asrService.isStreaming, isFalse);

      await _waitUntilReady(controller.asrService);
      expect(controller.asrService.isReady, isTrue);
      // 若 SenseVoice 加载失败会自动回退到流式引擎，此时 isStreaming 会变回 true
      expect(controller.asrService.isStreaming, isFalse);

      await disposeController(controller);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('选择 streaming 时使用低延迟流式 Zipformer 引擎', () async {
      final settings = AppSettings(asrEngine: AppConstants.asrEngineStreaming);
      final controller = AssistantController(settings: settings, enableDriverServer: false);

      expect(controller.asrService, isA<StreamingZipformerAsrService>());

      await _waitUntilReady(controller.asrService);
      expect(controller.asrService.isReady, isTrue);
      expect(controller.asrService.isStreaming, isTrue);

      await disposeController(controller);
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}

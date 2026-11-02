import '../core/ports/audio_hardware_port.dart';
import '../core/ports/camera_port.dart';
import '../core/ports/knowledge_port.dart';
import '../core/ports/llm_port.dart';
import '../core/ports/prompt_sound_port.dart';
import '../core/ports/speaker_verification_port.dart';
import '../core/ports/target_speaker_extraction_port.dart';
import '../core/ports/tts_port.dart';
import '../core/ports/voice_listening_port.dart';
import 'automation/app_driver_server.dart';
import 'lightrag/lightrag_service.dart';
import 'llm/llm_service.dart';
import 'speech/asr_engine_factory.dart';
import 'speech/asr_service.dart';
import 'speech/audio_input_device_service.dart';
import 'speech/prompt_sound_service.dart';
import 'speech/speaker_verification_service.dart';
import 'speech/target_speaker_extraction_service.dart';
import 'speech/tts_service.dart';
import 'speech/voice_listening_service.dart';
import 'storage/chat_history_service.dart';
import 'vision/camera_service.dart';

/// 全系统默认服务注册协调器 (Global Services Bootstrapper)
///
/// 遵循六边形架构，负责在服务层将 concrete adapters 注册到 core ports 的 SPI 注册表中，
/// 解除 core 对 services 的逆向硬编码引用。
class ServiceRegistrations {
  static bool _registered = false;

  static void ensureInitialized() {
    if (_registered) return;
    _registered = true;

    AsrEngineFactory.registerDefault();
    AppDriverServer.registerDefault();
    ChatHistoryService.registerDefault();

    LlmFactoryRegistry.defaultFactory = (s) => LlmService(settings: s);
    TtsFactoryRegistry.defaultFactory = (s) => TtsService(settings: s);
    PromptSoundFactoryRegistry.defaultFactory = ({outputDeviceId}) =>
        PromptSoundService(outputDeviceId: outputDeviceId ?? '');
    KnowledgeFactoryRegistry.defaultFactory = (
            {required baseUrl, required describeImage}) =>
        LightRagService(baseUrl: baseUrl, describeImage: describeImage);
    CameraPortRegistry.defaultFactory = (s) => CameraService(settings: s);
    AudioHardwareRegistry.defaultInputDeviceLister =
        () => AudioInputDeviceService.listInputDevices();
    SpeakerVerifierFactoryRegistry.defaultFactory =
        (s) => SpeakerVerificationService(settings: s);
    TargetSpeakerExtractionFactoryRegistry.defaultFactory =
        (s, spk) => TargetSpeakerExtractionService(
              settings: s,
              speakerVerificationService: spk as SpeakerVerificationService,
            );
    VoiceListeningFactoryRegistry.defaultFactory = ({
      required settings,
      required asrService,
      finalAsrService,
      speakerVerificationService,
      onFinalTranscript,
      onTextRecognized,
      onManualRecordingRecognized,
      onAudioLevelChanged,
      onMicTestRecognized,
      onStateChanged,
      isStandbyMode,
      isPlayingMode,
    }) {
      final tse = speakerVerificationService != null
          ? TargetSpeakerExtractionService(
              settings: settings,
              speakerVerificationService:
                  speakerVerificationService as SpeakerVerificationService,
            )
          : null;
      return VoiceListeningService(
        settings: settings,
        asrService: asrService as AsrService,
        finalAsrService: finalAsrService as AsrService?,
        targetSpeakerExtractionService: tse,
        onFinalTranscript: onFinalTranscript,
        onTextRecognized: onTextRecognized ?? (_) {},
        onManualRecordingRecognized: onManualRecordingRecognized,
        onAudioLevelChanged: onAudioLevelChanged,
        onMicTestRecognized: onMicTestRecognized,
        onStateChanged: onStateChanged,
        isStandbyMode: isStandbyMode,
        isPlayingMode: isPlayingMode,
      );
    };
  }
}

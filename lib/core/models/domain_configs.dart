import 'dart:io';
import '../constants/app_constants.dart';

bool _listEquals<T>(List<T>? a, List<T>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null || a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _listListEquals(List<List<double>>? a, List<List<double>>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null || a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (!_listEquals(a[i], b[i])) return false;
  }
  return true;
}

/// 音频、识别（ASR/VAD）、唤醒与声纹子系统领域配置
class AudioConfig {
  final String startWord;
  final String endWord;
  final String resetWord;
  final String exitContinuousWord;
  final String startWordMode;
  final int continuousModeTimeoutMinutes;
  final double similarityThreshold;
  final int silenceTimeoutSeconds;
  final String asrEngine;

  final double vadThreshold;
  final double vadMinSilenceSeconds;
  final double vadMinSpeechSeconds;
  final double vadMaxSpeechSeconds;
  final int preRollMs;
  final int postRollMs;
  final bool enableTwoPass;
  final bool autoSubmitOnTimeout;

  final String geminiApiKey;
  final String geminiAsrModel;

  final String audioInputDeviceId;
  final String audioInputDeviceLabel;
  final String audioOutputDeviceId;
  final String audioOutputDeviceLabel;

  final bool enableSpeakerVerification;
  final double speakerSimilarityThreshold;
  final bool speakerVerifyWakeOnly;
  final double speakerMinSpeechSeconds;
  final String speakerModelPath;
  final List<List<double>> ownerSpeakerEmbeddings;

  final bool enableTargetSpeakerExtraction;
  final double tseSimilarityThreshold;
  final double tseAttenuationDb;

  const AudioConfig({
    this.startWord = AppConstants.defaultStartWord,
    this.endWord = AppConstants.defaultEndWord,
    this.resetWord = AppConstants.defaultResetWord,
    this.exitContinuousWord = AppConstants.defaultExitContinuousWord,
    this.startWordMode = AppConstants.defaultStartWordMode,
    this.continuousModeTimeoutMinutes =
        AppConstants.defaultContinuousModeTimeoutMinutes,
    this.similarityThreshold = AppConstants.defaultSimilarityThreshold,
    this.silenceTimeoutSeconds = AppConstants.defaultSilenceTimeoutSeconds,
    this.asrEngine = AppConstants.defaultAsrEngine,
    this.vadThreshold = AppConstants.defaultVadThreshold,
    this.vadMinSilenceSeconds = AppConstants.defaultVadMinSilenceSeconds,
    this.vadMinSpeechSeconds = AppConstants.defaultVadMinSpeechSeconds,
    this.vadMaxSpeechSeconds = AppConstants.defaultVadMaxSpeechSeconds,
    this.preRollMs = AppConstants.defaultPreRollMs,
    this.postRollMs = AppConstants.defaultPostRollMs,
    this.enableTwoPass = AppConstants.defaultEnableTwoPass,
    this.autoSubmitOnTimeout = AppConstants.defaultAutoSubmitOnTimeout,
    this.geminiApiKey = AppConstants.defaultGeminiApiKey,
    this.geminiAsrModel = AppConstants.defaultGeminiAsrModel,
    this.audioInputDeviceId = '',
    this.audioInputDeviceLabel = '',
    this.audioOutputDeviceId = '',
    this.audioOutputDeviceLabel = '',
    this.enableSpeakerVerification =
        AppConstants.defaultEnableSpeakerVerification,
    this.speakerSimilarityThreshold =
        AppConstants.defaultSpeakerSimilarityThreshold,
    this.speakerVerifyWakeOnly = AppConstants.defaultSpeakerVerifyWakeOnly,
    this.speakerMinSpeechSeconds = AppConstants.defaultSpeakerMinSpeechSeconds,
    this.speakerModelPath = '',
    this.ownerSpeakerEmbeddings = const [],
    this.enableTargetSpeakerExtraction =
        AppConstants.defaultEnableTargetSpeakerExtraction,
    this.tseSimilarityThreshold = AppConstants.defaultTseSimilarityThreshold,
    this.tseAttenuationDb = AppConstants.defaultTseAttenuationDb,
  });

  bool get enableStartWordDetection =>
      startWordMode != AppConstants.startWordModeDisabled;

  List<String> get startWords => splitTriggerWords(startWord);
  List<String> get endWords => splitTriggerWords(endWord);
  List<String> get resetWords => splitTriggerWords(resetWord);
  List<String> get exitContinuousWords => splitTriggerWords(exitContinuousWord);

  static List<String> splitTriggerWords(String raw) {
    final parts = raw.split(RegExp(r'[;；,，\n\r]+'));
    final seen = <String>{};
    final words = <String>[];
    for (final part in parts) {
      final word = part.trim();
      if (word.isEmpty) continue;
      if (seen.add(word)) words.add(word);
    }
    return words;
  }

  AudioConfig copyWith({
    String? startWord,
    String? endWord,
    String? resetWord,
    String? exitContinuousWord,
    String? startWordMode,
    bool? enableStartWordDetection,
    int? continuousModeTimeoutMinutes,
    double? similarityThreshold,
    int? silenceTimeoutSeconds,
    String? asrEngine,
    double? vadThreshold,
    double? vadMinSilenceSeconds,
    double? vadMinSpeechSeconds,
    double? vadMaxSpeechSeconds,
    int? preRollMs,
    int? postRollMs,
    bool? enableTwoPass,
    bool? autoSubmitOnTimeout,
    String? geminiApiKey,
    String? geminiAsrModel,
    String? audioInputDeviceId,
    String? audioInputDeviceLabel,
    String? audioOutputDeviceId,
    String? audioOutputDeviceLabel,
    bool? enableSpeakerVerification,
    double? speakerSimilarityThreshold,
    bool? speakerVerifyWakeOnly,
    double? speakerMinSpeechSeconds,
    String? speakerModelPath,
    List<List<double>>? ownerSpeakerEmbeddings,
    bool? enableTargetSpeakerExtraction,
    double? tseSimilarityThreshold,
    double? tseAttenuationDb,
  }) {
    final newStartWordMode = startWordMode ??
        (enableStartWordDetection != null
            ? (enableStartWordDetection
                ? AppConstants.startWordModeEnabled
                : AppConstants.startWordModeDisabled)
            : this.startWordMode);

    return AudioConfig(
      startWord: startWord ?? this.startWord,
      endWord: endWord ?? this.endWord,
      resetWord: resetWord ?? this.resetWord,
      exitContinuousWord: exitContinuousWord ?? this.exitContinuousWord,
      startWordMode: newStartWordMode,
      continuousModeTimeoutMinutes:
          continuousModeTimeoutMinutes ?? this.continuousModeTimeoutMinutes,
      similarityThreshold: similarityThreshold ?? this.similarityThreshold,
      silenceTimeoutSeconds:
          silenceTimeoutSeconds ?? this.silenceTimeoutSeconds,
      asrEngine: asrEngine ?? this.asrEngine,
      vadThreshold: vadThreshold ?? this.vadThreshold,
      vadMinSilenceSeconds: vadMinSilenceSeconds ?? this.vadMinSilenceSeconds,
      vadMinSpeechSeconds: vadMinSpeechSeconds ?? this.vadMinSpeechSeconds,
      vadMaxSpeechSeconds: vadMaxSpeechSeconds ?? this.vadMaxSpeechSeconds,
      preRollMs: preRollMs ?? this.preRollMs,
      postRollMs: postRollMs ?? this.postRollMs,
      enableTwoPass: enableTwoPass ?? this.enableTwoPass,
      autoSubmitOnTimeout: autoSubmitOnTimeout ?? this.autoSubmitOnTimeout,
      geminiApiKey: geminiApiKey ?? this.geminiApiKey,
      geminiAsrModel: geminiAsrModel ?? this.geminiAsrModel,
      audioInputDeviceId: audioInputDeviceId ?? this.audioInputDeviceId,
      audioInputDeviceLabel:
          audioInputDeviceLabel ?? this.audioInputDeviceLabel,
      audioOutputDeviceId: audioOutputDeviceId ?? this.audioOutputDeviceId,
      audioOutputDeviceLabel:
          audioOutputDeviceLabel ?? this.audioOutputDeviceLabel,
      enableSpeakerVerification:
          enableSpeakerVerification ?? this.enableSpeakerVerification,
      speakerSimilarityThreshold:
          speakerSimilarityThreshold ?? this.speakerSimilarityThreshold,
      speakerVerifyWakeOnly:
          speakerVerifyWakeOnly ?? this.speakerVerifyWakeOnly,
      speakerMinSpeechSeconds:
          speakerMinSpeechSeconds ?? this.speakerMinSpeechSeconds,
      speakerModelPath: speakerModelPath ?? this.speakerModelPath,
      ownerSpeakerEmbeddings:
          ownerSpeakerEmbeddings ?? this.ownerSpeakerEmbeddings,
      enableTargetSpeakerExtraction:
          enableTargetSpeakerExtraction ?? this.enableTargetSpeakerExtraction,
      tseSimilarityThreshold:
          tseSimilarityThreshold ?? this.tseSimilarityThreshold,
      tseAttenuationDb: tseAttenuationDb ?? this.tseAttenuationDb,
    );
  }

  factory AudioConfig.fromMap(Map<String, dynamic> map) {
    final rawEngine =
        map['asrEngine'] as String? ?? AppConstants.defaultAsrEngine;
    final asrEngine = const {
      AppConstants.asrEngineSenseVoice,
      AppConstants.asrEngineStreaming,
      AppConstants.asrEngineGeminiLive,
    }.contains(rawEngine)
        ? rawEngine
        : AppConstants.defaultAsrEngine;

    final rawMode = map['startWordMode'] as String?;
    final String resolvedMode;
    if (rawMode == AppConstants.startWordModeEnabled ||
        rawMode == AppConstants.startWordModeDisabled ||
        rawMode == AppConstants.startWordModeAuto) {
      resolvedMode = rawMode!;
    } else {
      resolvedMode = (map['enableStartWordDetection'] as bool?) == false
          ? AppConstants.startWordModeDisabled
          : AppConstants.defaultStartWordMode;
    }

    final continuousModeTimeoutMinutes =
        ((map['continuousModeTimeoutMinutes'] as num?)?.toInt() ??
                AppConstants.defaultContinuousModeTimeoutMinutes)
            .clamp(1, 60);

    return AudioConfig(
      startWord: map['startWord'] as String? ?? AppConstants.defaultStartWord,
      endWord: map['endWord'] as String? ?? AppConstants.defaultEndWord,
      resetWord: map['resetWord'] as String? ?? AppConstants.defaultResetWord,
      exitContinuousWord: map['exitContinuousWord'] as String? ??
          AppConstants.defaultExitContinuousWord,
      startWordMode: resolvedMode,
      continuousModeTimeoutMinutes: continuousModeTimeoutMinutes,
      similarityThreshold: (map['similarityThreshold'] as num?)?.toDouble() ??
          AppConstants.defaultSimilarityThreshold,
      silenceTimeoutSeconds: ((map['silenceTimeoutSeconds'] as num?)?.toInt() ??
              AppConstants.defaultSilenceTimeoutSeconds)
          .clamp(1, 30),
      asrEngine: asrEngine,
      vadThreshold: (map['vadThreshold'] as num?)?.toDouble() ??
          AppConstants.defaultVadThreshold,
      vadMinSilenceSeconds: (map['vadMinSilenceSeconds'] as num?)?.toDouble() ??
          AppConstants.defaultVadMinSilenceSeconds,
      vadMinSpeechSeconds: (map['vadMinSpeechSeconds'] as num?)?.toDouble() ??
          AppConstants.defaultVadMinSpeechSeconds,
      vadMaxSpeechSeconds: (map['vadMaxSpeechSeconds'] as num?)?.toDouble() ??
          AppConstants.defaultVadMaxSpeechSeconds,
      preRollMs:
          (map['preRollMs'] as num?)?.toInt() ?? AppConstants.defaultPreRollMs,
      postRollMs: (map['postRollMs'] as num?)?.toInt() ??
          AppConstants.defaultPostRollMs,
      enableTwoPass:
          map['enableTwoPass'] as bool? ?? AppConstants.defaultEnableTwoPass,
      autoSubmitOnTimeout: map['autoSubmitOnTimeout'] as bool? ??
          AppConstants.defaultAutoSubmitOnTimeout,
      geminiApiKey:
          map['geminiApiKey'] as String? ?? AppConstants.defaultGeminiApiKey,
      geminiAsrModel: map['geminiAsrModel'] as String? ??
          AppConstants.defaultGeminiAsrModel,
      audioInputDeviceId: map['audioInputDeviceId'] as String? ?? '',
      audioInputDeviceLabel: map['audioInputDeviceLabel'] as String? ?? '',
      audioOutputDeviceId: map['audioOutputDeviceId'] as String? ?? '',
      audioOutputDeviceLabel: map['audioOutputDeviceLabel'] as String? ?? '',
      enableSpeakerVerification:
          map['enableSpeakerVerification'] as bool? ??
              AppConstants.defaultEnableSpeakerVerification,
      speakerSimilarityThreshold:
          (map['speakerSimilarityThreshold'] as num?)?.toDouble() ??
              AppConstants.defaultSpeakerSimilarityThreshold,
      speakerVerifyWakeOnly: map['speakerVerifyWakeOnly'] as bool? ??
          AppConstants.defaultSpeakerVerifyWakeOnly,
      speakerMinSpeechSeconds:
          (map['speakerMinSpeechSeconds'] as num?)?.toDouble() ??
              AppConstants.defaultSpeakerMinSpeechSeconds,
      speakerModelPath: map['speakerModelPath'] as String? ?? '',
      ownerSpeakerEmbeddings: (map['ownerSpeakerEmbeddings'] as List?)
              ?.map((item) => (item as List)
                  .map((e) => (e as num).toDouble())
                  .toList())
              .toList() ??
          const [],
      enableTargetSpeakerExtraction:
          map['enableTargetSpeakerExtraction'] as bool? ??
              AppConstants.defaultEnableTargetSpeakerExtraction,
      tseSimilarityThreshold:
          (map['tseSimilarityThreshold'] as num?)?.toDouble() ??
              AppConstants.defaultTseSimilarityThreshold,
      tseAttenuationDb: (map['tseAttenuationDb'] as num?)?.toDouble() ??
          AppConstants.defaultTseAttenuationDb,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'startWord': startWord,
      'endWord': endWord,
      'resetWord': resetWord,
      'exitContinuousWord': exitContinuousWord,
      'startWordMode': startWordMode,
      'enableStartWordDetection': enableStartWordDetection,
      'continuousModeTimeoutMinutes': continuousModeTimeoutMinutes,
      'similarityThreshold': similarityThreshold,
      'silenceTimeoutSeconds': silenceTimeoutSeconds,
      'asrEngine': asrEngine,
      'vadThreshold': vadThreshold,
      'vadMinSilenceSeconds': vadMinSilenceSeconds,
      'vadMinSpeechSeconds': vadMinSpeechSeconds,
      'vadMaxSpeechSeconds': vadMaxSpeechSeconds,
      'preRollMs': preRollMs,
      'postRollMs': postRollMs,
      'enableTwoPass': enableTwoPass,
      'autoSubmitOnTimeout': autoSubmitOnTimeout,
      'geminiApiKey': geminiApiKey,
      'geminiAsrModel': geminiAsrModel,
      'audioInputDeviceId': audioInputDeviceId,
      'audioInputDeviceLabel': audioInputDeviceLabel,
      'audioOutputDeviceId': audioOutputDeviceId,
      'audioOutputDeviceLabel': audioOutputDeviceLabel,
      'enableSpeakerVerification': enableSpeakerVerification,
      'speakerSimilarityThreshold': speakerSimilarityThreshold,
      'speakerVerifyWakeOnly': speakerVerifyWakeOnly,
      'speakerMinSpeechSeconds': speakerMinSpeechSeconds,
      'speakerModelPath': speakerModelPath,
      'ownerSpeakerEmbeddings': ownerSpeakerEmbeddings,
      'enableTargetSpeakerExtraction': enableTargetSpeakerExtraction,
      'tseSimilarityThreshold': tseSimilarityThreshold,
      'tseAttenuationDb': tseAttenuationDb,
    };
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AudioConfig &&
          runtimeType == other.runtimeType &&
          startWord == other.startWord &&
          endWord == other.endWord &&
          resetWord == other.resetWord &&
          exitContinuousWord == other.exitContinuousWord &&
          startWordMode == other.startWordMode &&
          continuousModeTimeoutMinutes == other.continuousModeTimeoutMinutes &&
          similarityThreshold == other.similarityThreshold &&
          silenceTimeoutSeconds == other.silenceTimeoutSeconds &&
          asrEngine == other.asrEngine &&
          vadThreshold == other.vadThreshold &&
          vadMinSilenceSeconds == other.vadMinSilenceSeconds &&
          vadMinSpeechSeconds == other.vadMinSpeechSeconds &&
          vadMaxSpeechSeconds == other.vadMaxSpeechSeconds &&
          preRollMs == other.preRollMs &&
          postRollMs == other.postRollMs &&
          enableTwoPass == other.enableTwoPass &&
          autoSubmitOnTimeout == other.autoSubmitOnTimeout &&
          geminiApiKey == other.geminiApiKey &&
          geminiAsrModel == other.geminiAsrModel &&
          audioInputDeviceId == other.audioInputDeviceId &&
          audioInputDeviceLabel == other.audioInputDeviceLabel &&
          audioOutputDeviceId == other.audioOutputDeviceId &&
          audioOutputDeviceLabel == other.audioOutputDeviceLabel &&
          enableSpeakerVerification == other.enableSpeakerVerification &&
          speakerSimilarityThreshold == other.speakerSimilarityThreshold &&
          speakerVerifyWakeOnly == other.speakerVerifyWakeOnly &&
          speakerMinSpeechSeconds == other.speakerMinSpeechSeconds &&
          speakerModelPath == other.speakerModelPath &&
          _listListEquals(
              ownerSpeakerEmbeddings, other.ownerSpeakerEmbeddings) &&
          enableTargetSpeakerExtraction ==
              other.enableTargetSpeakerExtraction &&
          tseSimilarityThreshold == other.tseSimilarityThreshold &&
          tseAttenuationDb == other.tseAttenuationDb;

  @override
  int get hashCode => Object.hashAll([
        startWord,
        endWord,
        resetWord,
        exitContinuousWord,
        startWordMode,
        continuousModeTimeoutMinutes,
        similarityThreshold,
        silenceTimeoutSeconds,
        asrEngine,
        vadThreshold,
        vadMinSilenceSeconds,
        vadMinSpeechSeconds,
        vadMaxSpeechSeconds,
        preRollMs,
        postRollMs,
        enableTwoPass,
        autoSubmitOnTimeout,
        geminiApiKey,
        geminiAsrModel,
        audioInputDeviceId,
        audioInputDeviceLabel,
        audioOutputDeviceId,
        audioOutputDeviceLabel,
        enableSpeakerVerification,
        speakerSimilarityThreshold,
        speakerVerifyWakeOnly,
        speakerMinSpeechSeconds,
        speakerModelPath,
        enableTargetSpeakerExtraction,
        tseSimilarityThreshold,
        tseAttenuationDb,
      ]);
}

/// 大语言模型与知识库（LightRAG/WebSearch）领域配置
class LlmConfig {
  final String openAiBaseUrl;
  final String openAiApiKey;
  final String openAiModel;
  final bool disableThinking;
  final bool enableWebSearch;
  final bool enableLightRag;
  final String lightRagBaseUrl;
  final String systemPrompt;
  final String locationAddress;
  final List<String> cachedAvailableModels;

  LlmConfig({
    String? openAiBaseUrl,
    String? openAiApiKey,
    this.openAiModel = AppConstants.defaultOpenAiModel,
    this.disableThinking = AppConstants.defaultDisableThinking,
    this.enableWebSearch = AppConstants.defaultEnableWebSearch,
    this.enableLightRag = AppConstants.defaultEnableLightRag,
    this.lightRagBaseUrl = AppConstants.defaultLightRagBaseUrl,
    this.systemPrompt = AppConstants.defaultSystemPrompt,
    this.locationAddress = AppConstants.defaultLocationAddress,
    this.cachedAvailableModels = const [],
  })  : openAiBaseUrl = openAiBaseUrl ?? AppConstants.defaultOpenAiBaseUrl,
        openAiApiKey = openAiApiKey ?? AppConstants.defaultOpenAiApiKey;

  LlmConfig copyWith({
    String? openAiBaseUrl,
    String? openAiApiKey,
    String? openAiModel,
    bool? disableThinking,
    bool? enableWebSearch,
    bool? enableLightRag,
    String? lightRagBaseUrl,
    String? systemPrompt,
    String? locationAddress,
    List<String>? cachedAvailableModels,
  }) {
    return LlmConfig(
      openAiBaseUrl: openAiBaseUrl ?? this.openAiBaseUrl,
      openAiApiKey: openAiApiKey ?? this.openAiApiKey,
      openAiModel: openAiModel ?? this.openAiModel,
      disableThinking: disableThinking ?? this.disableThinking,
      enableWebSearch: enableWebSearch ?? this.enableWebSearch,
      enableLightRag: enableLightRag ?? this.enableLightRag,
      lightRagBaseUrl: lightRagBaseUrl ?? this.lightRagBaseUrl,
      systemPrompt: systemPrompt ?? this.systemPrompt,
      locationAddress: locationAddress ?? this.locationAddress,
      cachedAvailableModels:
          cachedAvailableModels ?? this.cachedAvailableModels,
    );
  }

  factory LlmConfig.fromMap(Map<String, dynamic> map) {
    return LlmConfig(
      openAiBaseUrl:
          map['openAiBaseUrl'] as String? ?? AppConstants.defaultOpenAiBaseUrl,
      openAiApiKey:
          map['openAiApiKey'] as String? ?? AppConstants.defaultOpenAiApiKey,
      openAiModel:
          map['openAiModel'] as String? ?? AppConstants.defaultOpenAiModel,
      disableThinking: map['disableThinking'] as bool? ??
          AppConstants.defaultDisableThinking,
      enableWebSearch: map['enableWebSearch'] as bool? ??
          AppConstants.defaultEnableWebSearch,
      enableLightRag: map['enableLightRag'] as bool? ??
          AppConstants.defaultEnableLightRag,
      lightRagBaseUrl: map['lightRagBaseUrl'] as String? ??
          AppConstants.defaultLightRagBaseUrl,
      systemPrompt:
          map['systemPrompt'] as String? ?? AppConstants.defaultSystemPrompt,
      locationAddress: map['locationAddress'] as String? ??
          AppConstants.defaultLocationAddress,
      cachedAvailableModels: (map['cachedAvailableModels'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'openAiBaseUrl': openAiBaseUrl,
      'openAiApiKey': openAiApiKey,
      'openAiModel': openAiModel,
      'disableThinking': disableThinking,
      'enableWebSearch': enableWebSearch,
      'enableLightRag': enableLightRag,
      'lightRagBaseUrl': lightRagBaseUrl,
      'systemPrompt': systemPrompt,
      'locationAddress': locationAddress,
      'cachedAvailableModels': cachedAvailableModels,
    };
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LlmConfig &&
          runtimeType == other.runtimeType &&
          openAiBaseUrl == other.openAiBaseUrl &&
          openAiApiKey == other.openAiApiKey &&
          openAiModel == other.openAiModel &&
          disableThinking == other.disableThinking &&
          enableWebSearch == other.enableWebSearch &&
          enableLightRag == other.enableLightRag &&
          lightRagBaseUrl == other.lightRagBaseUrl &&
          systemPrompt == other.systemPrompt &&
          locationAddress == other.locationAddress &&
          _listEquals(cachedAvailableModels, other.cachedAvailableModels);

  @override
  int get hashCode => Object.hash(
        openAiBaseUrl,
        openAiApiKey,
        openAiModel,
        disableThinking,
        enableWebSearch,
        enableLightRag,
        lightRagBaseUrl,
        systemPrompt,
        locationAddress,
        Object.hashAll(cachedAvailableModels),
      );
}

/// 语音合成（TTS）与播报领域配置
class TtsConfig {
  final bool enableBargeIn;
  final bool enableTtsPlayback;
  final double ttsSpeed;
  final int playbackVolume;
  final bool enablePromptTone;
  final String ttsEngine;
  final String edgeVoice;

  const TtsConfig({
    this.enableBargeIn = true,
    this.enableTtsPlayback = true,
    this.ttsSpeed = 1.0,
    this.playbackVolume = 80,
    this.enablePromptTone = true,
    this.ttsEngine = AppConstants.defaultTtsEngine,
    this.edgeVoice = AppConstants.defaultEdgeVoice,
  });

  TtsConfig copyWith({
    bool? enableBargeIn,
    bool? enableTtsPlayback,
    double? ttsSpeed,
    int? playbackVolume,
    bool? enablePromptTone,
    String? ttsEngine,
    String? edgeVoice,
  }) {
    return TtsConfig(
      enableBargeIn: enableBargeIn ?? this.enableBargeIn,
      enableTtsPlayback: enableTtsPlayback ?? this.enableTtsPlayback,
      ttsSpeed: ttsSpeed ?? this.ttsSpeed,
      playbackVolume: playbackVolume ?? this.playbackVolume,
      enablePromptTone: enablePromptTone ?? this.enablePromptTone,
      ttsEngine: ttsEngine ?? this.ttsEngine,
      edgeVoice: edgeVoice ?? this.edgeVoice,
    );
  }

  factory TtsConfig.fromMap(Map<String, dynamic> map) {
    return TtsConfig(
      enableBargeIn: map['enableBargeIn'] as bool? ?? true,
      enableTtsPlayback: map['enableTtsPlayback'] as bool? ?? true,
      ttsSpeed: (map['ttsSpeed'] as num?)?.toDouble() ?? 1.0,
      playbackVolume:
          ((map['playbackVolume'] as num?)?.toInt() ?? 80).clamp(0, 150),
      enablePromptTone: map['enablePromptTone'] as bool? ?? true,
      ttsEngine: map['ttsEngine'] as String? ?? AppConstants.defaultTtsEngine,
      edgeVoice: map['edgeVoice'] as String? ?? AppConstants.defaultEdgeVoice,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'enableBargeIn': enableBargeIn,
      'enableTtsPlayback': enableTtsPlayback,
      'ttsSpeed': ttsSpeed,
      'playbackVolume': playbackVolume,
      'enablePromptTone': enablePromptTone,
      'ttsEngine': ttsEngine,
      'edgeVoice': edgeVoice,
    };
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TtsConfig &&
          runtimeType == other.runtimeType &&
          enableBargeIn == other.enableBargeIn &&
          enableTtsPlayback == other.enableTtsPlayback &&
          ttsSpeed == other.ttsSpeed &&
          playbackVolume == other.playbackVolume &&
          enablePromptTone == other.enablePromptTone &&
          ttsEngine == other.ttsEngine &&
          edgeVoice == other.edgeVoice;

  @override
  int get hashCode => Object.hash(
        enableBargeIn,
        enableTtsPlayback,
        ttsSpeed,
        playbackVolume,
        enablePromptTone,
        ttsEngine,
        edgeVoice,
      );
}

/// 视觉与摄像头（Android CameraX / DJI Nano / Linux V4L2）领域配置
class VisionConfig {
  final String captureSource;
  final String nanoWlanInterface;
  final String nanoSsid;
  final String nanoPassword;
  final String nanoBleAddress;
  final bool enableVisionIntent;
  final double visionSimilarityThreshold;
  final int cameraKeepAliveMinutes;
  final String cameraLensDirection;
  final int cameraResolutionWidth;
  final int cameraResolutionHeight;
  final int cameraSendShortEdge;
  final List<String> customVisionPrototypes;
  final String linuxCameraDevice;

  const VisionConfig({
    this.captureSource = AppConstants.defaultCaptureSource,
    this.nanoWlanInterface = AppConstants.defaultNanoWlanInterface,
    this.nanoSsid = AppConstants.defaultNanoSsid,
    this.nanoPassword = AppConstants.defaultNanoPassword,
    this.nanoBleAddress = AppConstants.defaultNanoBleAddress,
    this.enableVisionIntent = AppConstants.defaultEnableVisionIntent,
    this.visionSimilarityThreshold =
        AppConstants.defaultVisionSimilarityThreshold,
    this.cameraKeepAliveMinutes = AppConstants.defaultCameraKeepAliveMinutes,
    this.cameraLensDirection = AppConstants.defaultCameraLensDirection,
    this.cameraResolutionWidth = 0,
    this.cameraResolutionHeight = 0,
    this.cameraSendShortEdge = 720,
    this.customVisionPrototypes = const [],
    this.linuxCameraDevice = '',
  });

  VisionConfig copyWith({
    String? captureSource,
    String? nanoWlanInterface,
    String? nanoSsid,
    String? nanoPassword,
    String? nanoBleAddress,
    bool? enableVisionIntent,
    double? visionSimilarityThreshold,
    int? cameraKeepAliveMinutes,
    String? cameraLensDirection,
    int? cameraResolutionWidth,
    int? cameraResolutionHeight,
    int? cameraSendShortEdge,
    List<String>? customVisionPrototypes,
    String? linuxCameraDevice,
  }) {
    return VisionConfig(
      captureSource: captureSource ?? this.captureSource,
      nanoWlanInterface: nanoWlanInterface ?? this.nanoWlanInterface,
      nanoSsid: nanoSsid ?? this.nanoSsid,
      nanoPassword: nanoPassword ?? this.nanoPassword,
      nanoBleAddress: nanoBleAddress ?? this.nanoBleAddress,
      enableVisionIntent: enableVisionIntent ?? this.enableVisionIntent,
      visionSimilarityThreshold:
          visionSimilarityThreshold ?? this.visionSimilarityThreshold,
      cameraKeepAliveMinutes:
          cameraKeepAliveMinutes ?? this.cameraKeepAliveMinutes,
      cameraLensDirection: cameraLensDirection ?? this.cameraLensDirection,
      cameraResolutionWidth:
          cameraResolutionWidth ?? this.cameraResolutionWidth,
      cameraResolutionHeight:
          cameraResolutionHeight ?? this.cameraResolutionHeight,
      cameraSendShortEdge: cameraSendShortEdge ?? this.cameraSendShortEdge,
      customVisionPrototypes:
          customVisionPrototypes ?? this.customVisionPrototypes,
      linuxCameraDevice: linuxCameraDevice ?? this.linuxCameraDevice,
    );
  }

  factory VisionConfig.fromMap(Map<String, dynamic> map) {
    final rawCameraResWidth =
        (map['cameraResolutionWidth'] as num?)?.toInt() ?? 0;
    final rawCameraResHeight =
        (map['cameraResolutionHeight'] as num?)?.toInt() ?? 0;
    final hasCameraResolution = rawCameraResWidth > 0 && rawCameraResHeight > 0;
    final rawSendShortEdge =
        (map['cameraSendShortEdge'] as num?)?.toInt() ?? 720;
    final sendShortEdge = const {480, 720, 1080}.contains(rawSendShortEdge)
        ? rawSendShortEdge
        : 720;

    return VisionConfig(
      captureSource:
          map['captureSource'] as String? ?? AppConstants.defaultCaptureSource,
      nanoWlanInterface: map['nanoWlanInterface'] as String? ??
          AppConstants.defaultNanoWlanInterface,
      nanoSsid: map['nanoSsid'] as String? ?? AppConstants.defaultNanoSsid,
      nanoPassword:
          map['nanoPassword'] as String? ?? AppConstants.defaultNanoPassword,
      nanoBleAddress: map['nanoBleAddress'] as String? ??
          AppConstants.defaultNanoBleAddress,
      enableVisionIntent: map['enableVisionIntent'] as bool? ??
          AppConstants.defaultEnableVisionIntent,
      visionSimilarityThreshold:
          (map['visionSimilarityThreshold'] as num?)?.toDouble() ??
              AppConstants.defaultVisionSimilarityThreshold,
      cameraKeepAliveMinutes: (map['cameraKeepAliveMinutes'] as int? ??
              AppConstants.defaultCameraKeepAliveMinutes)
          .clamp(0, 10),
      cameraLensDirection: map['cameraLensDirection'] as String? ??
          AppConstants.defaultCameraLensDirection,
      cameraResolutionWidth: hasCameraResolution ? rawCameraResWidth : 0,
      cameraResolutionHeight: hasCameraResolution ? rawCameraResHeight : 0,
      cameraSendShortEdge: sendShortEdge,
      customVisionPrototypes: (map['customVisionPrototypes'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
      linuxCameraDevice: map['linuxCameraDevice'] as String? ?? '',
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'captureSource': captureSource,
      'nanoWlanInterface': nanoWlanInterface,
      'nanoSsid': nanoSsid,
      'nanoPassword': nanoPassword,
      'nanoBleAddress': nanoBleAddress,
      'enableVisionIntent': enableVisionIntent,
      'visionSimilarityThreshold': visionSimilarityThreshold,
      'cameraKeepAliveMinutes': cameraKeepAliveMinutes,
      'cameraLensDirection': cameraLensDirection,
      'cameraResolutionWidth': cameraResolutionWidth,
      'cameraResolutionHeight': cameraResolutionHeight,
      'cameraSendShortEdge': cameraSendShortEdge,
      'customVisionPrototypes': customVisionPrototypes,
      'linuxCameraDevice': linuxCameraDevice,
    };
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VisionConfig &&
          runtimeType == other.runtimeType &&
          captureSource == other.captureSource &&
          nanoWlanInterface == other.nanoWlanInterface &&
          nanoSsid == other.nanoSsid &&
          nanoPassword == other.nanoPassword &&
          nanoBleAddress == other.nanoBleAddress &&
          enableVisionIntent == other.enableVisionIntent &&
          visionSimilarityThreshold == other.visionSimilarityThreshold &&
          cameraKeepAliveMinutes == other.cameraKeepAliveMinutes &&
          cameraLensDirection == other.cameraLensDirection &&
          cameraResolutionWidth == other.cameraResolutionWidth &&
          cameraResolutionHeight == other.cameraResolutionHeight &&
          cameraSendShortEdge == other.cameraSendShortEdge &&
          linuxCameraDevice == other.linuxCameraDevice &&
          _listEquals(customVisionPrototypes, other.customVisionPrototypes);

  @override
  int get hashCode => Object.hash(
        captureSource,
        nanoWlanInterface,
        nanoSsid,
        nanoPassword,
        nanoBleAddress,
        enableVisionIntent,
        visionSimilarityThreshold,
        cameraKeepAliveMinutes,
        cameraLensDirection,
        cameraResolutionWidth,
        cameraResolutionHeight,
        cameraSendShortEdge,
        linuxCameraDevice,
        Object.hashAll(customVisionPrototypes),
      );
}

/// 服务端与运行环境配置
class ServerConfig {
  final bool autoStartMicOnLaunch;
  final String webAccessPassword;
  final bool enableFloatingCapsule;

  const ServerConfig({
    bool? autoStartMicOnLaunch,
    this.webAccessPassword = '',
    this.enableFloatingCapsule = false,
  }) : autoStartMicOnLaunch = autoStartMicOnLaunch ?? false;

  ServerConfig copyWith({
    bool? autoStartMicOnLaunch,
    String? webAccessPassword,
    bool? enableFloatingCapsule,
  }) {
    return ServerConfig(
      autoStartMicOnLaunch: autoStartMicOnLaunch ?? this.autoStartMicOnLaunch,
      webAccessPassword: webAccessPassword ?? this.webAccessPassword,
      enableFloatingCapsule:
          enableFloatingCapsule ?? this.enableFloatingCapsule,
    );
  }

  factory ServerConfig.fromMap(Map<String, dynamic> map) {
    return ServerConfig(
      autoStartMicOnLaunch:
          map['autoStartMicOnLaunch'] as bool? ?? Platform.isLinux,
      webAccessPassword: map['webAccessPassword'] as String? ?? '',
      enableFloatingCapsule: map['enableFloatingCapsule'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'autoStartMicOnLaunch': autoStartMicOnLaunch,
      'webAccessPassword': webAccessPassword,
      'enableFloatingCapsule': enableFloatingCapsule,
    };
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ServerConfig &&
          runtimeType == other.runtimeType &&
          autoStartMicOnLaunch == other.autoStartMicOnLaunch &&
          webAccessPassword == other.webAccessPassword &&
          enableFloatingCapsule == other.enableFloatingCapsule;

  @override
  int get hashCode => Object.hash(
        autoStartMicOnLaunch,
        webAccessPassword,
        enableFloatingCapsule,
      );
}

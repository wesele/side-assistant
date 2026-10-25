import 'dart:convert';
import 'dart:io';
import '../constants/app_constants.dart';
import '../platform/storage_bridge.dart';

class AppSettings {
  String startWord;
  String endWord;
  String resetWord;
  double similarityThreshold;
  int silenceTimeoutSeconds;
  String asrEngine;

  // 高级 VAD / 两遍解码
  double vadThreshold;
  double vadMinSilenceSeconds;
  double vadMinSpeechSeconds;
  double vadMaxSpeechSeconds;
  int preRollMs;
  int postRollMs;
  bool enableTwoPass;
  bool autoSubmitOnTimeout;

  String openAiBaseUrl;
  String openAiApiKey;
  String openAiModel;
  bool disableThinking;
  bool enableWebSearch;
  bool enableLightRag;
  String lightRagBaseUrl;
  String systemPrompt;

  // Gemini 云端语音识别（仅在选择 gemini_live 引擎时使用）
  String geminiApiKey;
  String geminiAsrModel;

  bool useRemoteEmbedding;
  String embeddingBaseUrl;
  String embeddingApiKey;
  String embeddingModel;
  String localEmbeddingModelPath;

  /// 录音输入设备（Android / Linux）：'' 表示自动（交给系统选择），
  /// 否则是原生 `AudioDeviceInfo.id` 或 Linux 设备标识（见 AudioInputDeviceService）。
  String audioInputDeviceId;

  /// 录音设备显示名，仅用于设置界面回显（设备断开后仍能显示用户选的是什么）。
  String audioInputDeviceLabel;

  /// 扬声器输出设备（Linux 服务端）：'' 表示自动（系统默认）。
  String audioOutputDeviceId;
  String audioOutputDeviceLabel;

  /// Linux 本地摄像头设备节点（如 '/dev/video0'，'' 表示自动检测）。
  String linuxCameraDevice;

  /// 服务启动后是否自动开启麦克风监听（Linux 服务端默认开启）。
  bool autoStartMicOnLaunch;

  /// Web 控制台可选访问密码（'' 表示局域网免密访问）。
  String webAccessPassword;

  bool enableBargeIn;
  bool enableTtsPlayback;
  double ttsSpeed;
  int playbackVolume;
  bool enablePromptTone;
  String ttsEngine;
  String edgeVoice;

  /// 当前地理位置（地址文本）。Linux/Windows 使用该配置；Android 优先自动定位，失败时回退到该值。
  String locationAddress;

  /// 开始词列表：支持在设置里用分号/逗号配置多个（如“晓漫；小助手”）。
  List<String> get startWords => splitTriggerWords(startWord);

  /// 结束词列表：支持配置多个（如“回答；完毕”）。
  List<String> get endWords => splitTriggerWords(endWord);

  /// 新起会话词列表：支持配置多个（如“新起一个；重新开始”）。
  List<String> get resetWords => splitTriggerWords(resetWord);

  /// 把“A；B;C，D”这类配置拆成去重后的词列表。
  ///
  /// 中英文分号与逗号都当分隔符；空项忽略；保持用户书写顺序（决定匹配优先级）。
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

  // 视觉与摄像头配置
  String captureSource;
  String nanoWlanInterface;
  String nanoSsid;
  String nanoPassword;
  String nanoBleAddress;
  bool enableVisionIntent;
  double visionSimilarityThreshold;
  int cameraKeepAliveMinutes;
  String cameraLensDirection;

  /// 拍照分辨率（仅 Android 原生 CameraX 生效）。
  /// 0×0 表示自动：按 1600×1200 目标就近选择设备支持档位。
  int cameraResolutionWidth;
  int cameraResolutionHeight;

  /// 发送给大模型前的压缩档位：按图片短边缩放到 480 / 720 / 1080。
  /// 只影响上传的图片字节，本地保存的原图不受影响。
  int cameraSendShortEdge;
  List<String> customVisionPrototypes;
  List<String> cachedAvailableModels;

  /// Android 顶部悬浮胶囊：最小化 App 后在摄像头周围显示状态并支持展开操作。
  bool enableFloatingCapsule;

  AppSettings({
    this.startWord = AppConstants.defaultStartWord,
    this.endWord = AppConstants.defaultEndWord,
    this.resetWord = AppConstants.defaultResetWord,
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
    String? openAiBaseUrl,
    String? openAiApiKey,
    this.openAiModel = AppConstants.defaultOpenAiModel,
    this.disableThinking = AppConstants.defaultDisableThinking,
    this.enableWebSearch = AppConstants.defaultEnableWebSearch,
    this.enableLightRag = AppConstants.defaultEnableLightRag,
    this.lightRagBaseUrl = AppConstants.defaultLightRagBaseUrl,
    this.systemPrompt = AppConstants.defaultSystemPrompt,
    this.geminiApiKey = AppConstants.defaultGeminiApiKey,
    this.geminiAsrModel = AppConstants.defaultGeminiAsrModel,
    this.useRemoteEmbedding = true,
    this.embeddingBaseUrl = AppConstants.defaultEmbeddingBaseUrl,
    this.embeddingApiKey = AppConstants.defaultEmbeddingApiKey,
    this.embeddingModel = AppConstants.defaultEmbeddingModel,
    this.localEmbeddingModelPath = '',
    this.audioInputDeviceId = '',
    this.audioInputDeviceLabel = '',
    this.audioOutputDeviceId = '',
    this.audioOutputDeviceLabel = '',
    this.linuxCameraDevice = '',
    bool? autoStartMicOnLaunch,
    this.webAccessPassword = '',
    this.enableBargeIn = true,
    this.enableTtsPlayback = true,
    this.ttsSpeed = 1.0,
    this.playbackVolume = 80,
    this.enablePromptTone = true,
    this.ttsEngine = AppConstants.defaultTtsEngine,
    this.edgeVoice = AppConstants.defaultEdgeVoice,
    this.locationAddress = AppConstants.defaultLocationAddress,
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
    List<String>? customVisionPrototypes,
    List<String>? cachedAvailableModels,
    this.enableFloatingCapsule = false,
  })  : openAiBaseUrl = openAiBaseUrl ?? AppConstants.defaultOpenAiBaseUrl,
        openAiApiKey = openAiApiKey ?? AppConstants.defaultOpenAiApiKey,
        autoStartMicOnLaunch = autoStartMicOnLaunch ?? Platform.isLinux,
        customVisionPrototypes = customVisionPrototypes ?? [],
        cachedAvailableModels = cachedAvailableModels ?? [];

  Map<String, dynamic> toMap() {
    return {
      'startWord': startWord,
      'endWord': endWord,
      'resetWord': resetWord,
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
      'openAiBaseUrl': openAiBaseUrl,
      'openAiApiKey': openAiApiKey,
      'openAiModel': openAiModel,
      'disableThinking': disableThinking,
      'enableWebSearch': enableWebSearch,
      'enableLightRag': enableLightRag,
      'lightRagBaseUrl': lightRagBaseUrl,
      'systemPrompt': systemPrompt,
      'geminiApiKey': geminiApiKey,
      'geminiAsrModel': geminiAsrModel,
      'useRemoteEmbedding': useRemoteEmbedding,
      'embeddingBaseUrl': embeddingBaseUrl,
      'embeddingApiKey': embeddingApiKey,
      'embeddingModel': embeddingModel,
      'localEmbeddingModelPath': localEmbeddingModelPath,
      'audioInputDeviceId': audioInputDeviceId,
      'audioInputDeviceLabel': audioInputDeviceLabel,
      'audioOutputDeviceId': audioOutputDeviceId,
      'audioOutputDeviceLabel': audioOutputDeviceLabel,
      'linuxCameraDevice': linuxCameraDevice,
      'autoStartMicOnLaunch': autoStartMicOnLaunch,
      'webAccessPassword': webAccessPassword,
      'enableBargeIn': enableBargeIn,
      'enableTtsPlayback': enableTtsPlayback,
      'ttsSpeed': ttsSpeed,
      'playbackVolume': playbackVolume,
      'enablePromptTone': enablePromptTone,
      'ttsEngine': ttsEngine,
      'edgeVoice': edgeVoice,
      'locationAddress': locationAddress,
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
      'cachedAvailableModels': cachedAvailableModels,
      'enableFloatingCapsule': enableFloatingCapsule,
    };
  }

  factory AppSettings.fromMap(Map<String, dynamic> map) {
    final rawEngine =
        map['asrEngine'] as String? ?? AppConstants.defaultAsrEngine;
    // 旧版本可能保存了已移除的引擎（firered / streaming_zh / lan），统一回退默认引擎。
    final asrEngine = const {
      AppConstants.asrEngineSenseVoice,
      AppConstants.asrEngineStreaming,
      AppConstants.asrEngineGeminiLive,
    }.contains(rawEngine)
        ? rawEngine
        : AppConstants.defaultAsrEngine;

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

    return AppSettings(
      startWord: map['startWord'] as String? ?? AppConstants.defaultStartWord,
      endWord: map['endWord'] as String? ?? AppConstants.defaultEndWord,
      resetWord: map['resetWord'] as String? ?? AppConstants.defaultResetWord,
      similarityThreshold: (map['similarityThreshold'] as num?)?.toDouble() ??
          AppConstants.defaultSimilarityThreshold,
      silenceTimeoutSeconds: map['silenceTimeoutSeconds'] as int? ??
          AppConstants.defaultSilenceTimeoutSeconds,
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
      geminiApiKey:
          map['geminiApiKey'] as String? ?? AppConstants.defaultGeminiApiKey,
      geminiAsrModel: map['geminiAsrModel'] as String? ??
          AppConstants.defaultGeminiAsrModel,
      useRemoteEmbedding: map['useRemoteEmbedding'] as bool? ?? true,
      embeddingBaseUrl: map['embeddingBaseUrl'] as String? ??
          AppConstants.defaultEmbeddingBaseUrl,
      embeddingApiKey: map['embeddingApiKey'] as String? ??
          AppConstants.defaultEmbeddingApiKey,
      embeddingModel: map['embeddingModel'] as String? ??
          AppConstants.defaultEmbeddingModel,
      localEmbeddingModelPath: map['localEmbeddingModelPath'] as String? ?? '',
      audioInputDeviceId: map['audioInputDeviceId'] as String? ?? '',
      audioInputDeviceLabel: map['audioInputDeviceLabel'] as String? ?? '',
      audioOutputDeviceId: map['audioOutputDeviceId'] as String? ?? '',
      audioOutputDeviceLabel: map['audioOutputDeviceLabel'] as String? ?? '',
      linuxCameraDevice: map['linuxCameraDevice'] as String? ?? '',
      autoStartMicOnLaunch:
          map['autoStartMicOnLaunch'] as bool? ?? Platform.isLinux,
      webAccessPassword: map['webAccessPassword'] as String? ?? '',
      enableBargeIn: map['enableBargeIn'] as bool? ?? true,
      enableTtsPlayback: map['enableTtsPlayback'] as bool? ?? true,
      ttsSpeed: (map['ttsSpeed'] as num?)?.toDouble() ?? 1.0,
      playbackVolume: ((map['playbackVolume'] as num?)?.toInt() ?? 80).clamp(0, 150),
      enablePromptTone: map['enablePromptTone'] as bool? ?? true,
      ttsEngine: map['ttsEngine'] as String? ?? AppConstants.defaultTtsEngine,
      edgeVoice: map['edgeVoice'] as String? ?? AppConstants.defaultEdgeVoice,
      locationAddress: map['locationAddress'] as String? ??
          AppConstants.defaultLocationAddress,
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
          [],
      cachedAvailableModels: (map['cachedAvailableModels'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
      enableFloatingCapsule: map['enableFloatingCapsule'] as bool? ?? false,
    );
  }

  static const String _prefsKey = 'app_settings_data_v1';

  Future<void> save() async {
    await StorageBridge.writePreferenceString(_prefsKey, jsonEncode(toMap()));
  }

  static Future<AppSettings> load() async {
    final jsonStr = await StorageBridge.readPreferenceString(_prefsKey);
    if (jsonStr == null || jsonStr.isEmpty) {
      return AppSettings();
    }
    try {
      final map = jsonDecode(jsonStr) as Map<String, dynamic>;
      return AppSettings.fromMap(map);
    } catch (_) {
      return AppSettings();
    }
  }
}

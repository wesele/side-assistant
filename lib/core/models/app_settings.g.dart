// GENERATED CODE - DO NOT MODIFY BY HAND
// Generator: tool/build_settings.dart

part of 'app_settings.dart';

/// 统一配置对象（领域化拆分 + 平坦持久化兼容）
///
/// 遵循六边形架构与 AGENTS.md 规范：
/// 1. 内存中领域化隔离：拆分为 [audio]、[llm]、[tts]、[vision]、[server] 五大领域子配置；
/// 2. 外部持久化 100% 平坦兼容：[toMap] 与 [fromMap] 完全兼容既有 flat JSON 格式；
/// 3. 全局平滑向后兼容：保留全部扁平字段的 getter/setter，已有调用代码零改动。
class AppSettings {
  AudioConfig audio;
  LlmConfig llm;
  TtsConfig tts;
  VisionConfig vision;
  ServerConfig server;

  AppSettings({
    AudioConfig? audio,
    LlmConfig? llm,
    TtsConfig? tts,
    VisionConfig? vision,
    ServerConfig? server,
    // 兼容既有扁平参数初始化
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
    double? speakerEnergyThreshold,
    String? speakerModelPath,
    List<List<double>>? ownerSpeakerEmbeddings,
    bool? enableTargetSpeakerExtraction,
    double? tseSimilarityThreshold,
    double? tseAttenuationDb,
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
    bool? enableBargeIn,
    bool? enableTtsPlayback,
    double? ttsSpeed,
    int? playbackVolume,
    bool? enablePromptTone,
    String? ttsEngine,
    String? edgeVoice,
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
    bool? autoStartMicOnLaunch,
    String? webAccessPassword,
    bool? enableFloatingCapsule,
  })  : audio = (audio ?? const AudioConfig()).copyWith(
          startWord: startWord,
          endWord: endWord,
          resetWord: resetWord,
          exitContinuousWord: exitContinuousWord,
          startWordMode: startWordMode,
          enableStartWordDetection: enableStartWordDetection,
          continuousModeTimeoutMinutes: continuousModeTimeoutMinutes,
          similarityThreshold: similarityThreshold,
          silenceTimeoutSeconds: silenceTimeoutSeconds,
          asrEngine: asrEngine,
          vadThreshold: vadThreshold,
          vadMinSilenceSeconds: vadMinSilenceSeconds,
          vadMinSpeechSeconds: vadMinSpeechSeconds,
          vadMaxSpeechSeconds: vadMaxSpeechSeconds,
          preRollMs: preRollMs,
          postRollMs: postRollMs,
          enableTwoPass: enableTwoPass,
          autoSubmitOnTimeout: autoSubmitOnTimeout,
          geminiApiKey: geminiApiKey,
          geminiAsrModel: geminiAsrModel,
          audioInputDeviceId: audioInputDeviceId,
          audioInputDeviceLabel: audioInputDeviceLabel,
          audioOutputDeviceId: audioOutputDeviceId,
          audioOutputDeviceLabel: audioOutputDeviceLabel,
          enableSpeakerVerification: enableSpeakerVerification,
          speakerSimilarityThreshold: speakerSimilarityThreshold,
          speakerVerifyWakeOnly: speakerVerifyWakeOnly,
          speakerMinSpeechSeconds: speakerMinSpeechSeconds,
          speakerEnergyThreshold: speakerEnergyThreshold,
          speakerModelPath: speakerModelPath,
          ownerSpeakerEmbeddings: ownerSpeakerEmbeddings,
          enableTargetSpeakerExtraction: enableTargetSpeakerExtraction,
          tseSimilarityThreshold: tseSimilarityThreshold,
          tseAttenuationDb: tseAttenuationDb,
        ),
        llm = (llm ?? LlmConfig()).copyWith(
          openAiBaseUrl: openAiBaseUrl,
          openAiApiKey: openAiApiKey,
          openAiModel: openAiModel,
          disableThinking: disableThinking,
          enableWebSearch: enableWebSearch,
          enableLightRag: enableLightRag,
          lightRagBaseUrl: lightRagBaseUrl,
          systemPrompt: systemPrompt,
          locationAddress: locationAddress,
          cachedAvailableModels: cachedAvailableModels,
        ),
        tts = (tts ?? const TtsConfig()).copyWith(
          enableBargeIn: enableBargeIn,
          enableTtsPlayback: enableTtsPlayback,
          ttsSpeed: ttsSpeed,
          playbackVolume: playbackVolume,
          enablePromptTone: enablePromptTone,
          ttsEngine: ttsEngine,
          edgeVoice: edgeVoice,
        ),
        vision = (vision ?? const VisionConfig()).copyWith(
          captureSource: captureSource,
          nanoWlanInterface: nanoWlanInterface,
          nanoSsid: nanoSsid,
          nanoPassword: nanoPassword,
          nanoBleAddress: nanoBleAddress,
          enableVisionIntent: enableVisionIntent,
          visionSimilarityThreshold: visionSimilarityThreshold,
          cameraKeepAliveMinutes: cameraKeepAliveMinutes,
          cameraLensDirection: cameraLensDirection,
          cameraResolutionWidth: cameraResolutionWidth,
          cameraResolutionHeight: cameraResolutionHeight,
          cameraSendShortEdge: cameraSendShortEdge,
          customVisionPrototypes: customVisionPrototypes,
          linuxCameraDevice: linuxCameraDevice,
        ),
        server = (server ?? ServerConfig(autoStartMicOnLaunch: Platform.isLinux)).copyWith(
          autoStartMicOnLaunch: autoStartMicOnLaunch,
          webAccessPassword: webAccessPassword,
          enableFloatingCapsule: enableFloatingCapsule,
        );

  // --- AudioConfig 属性代理 ---
  String get startWord => audio.startWord;
  set startWord(String v) => audio = audio.copyWith(startWord: v);

  String get endWord => audio.endWord;
  set endWord(String v) => audio = audio.copyWith(endWord: v);

  String get resetWord => audio.resetWord;
  set resetWord(String v) => audio = audio.copyWith(resetWord: v);

  String get exitContinuousWord => audio.exitContinuousWord;
  set exitContinuousWord(String v) => audio = audio.copyWith(exitContinuousWord: v);

  String get startWordMode => audio.startWordMode;
  set startWordMode(String v) => audio = audio.copyWith(startWordMode: v);

  bool get enableStartWordDetection => audio.enableStartWordDetection;
  set enableStartWordDetection(bool v) =>
      audio = audio.copyWith(enableStartWordDetection: v);

  int get continuousModeTimeoutMinutes => audio.continuousModeTimeoutMinutes;
  set continuousModeTimeoutMinutes(int v) => audio = audio.copyWith(continuousModeTimeoutMinutes: v);

  double get similarityThreshold => audio.similarityThreshold;
  set similarityThreshold(double v) => audio = audio.copyWith(similarityThreshold: v);

  int get silenceTimeoutSeconds => audio.silenceTimeoutSeconds;
  set silenceTimeoutSeconds(int v) => audio = audio.copyWith(silenceTimeoutSeconds: v);

  String get asrEngine => audio.asrEngine;
  set asrEngine(String v) => audio = audio.copyWith(asrEngine: v);

  double get vadThreshold => audio.vadThreshold;
  set vadThreshold(double v) => audio = audio.copyWith(vadThreshold: v);

  double get vadMinSilenceSeconds => audio.vadMinSilenceSeconds;
  set vadMinSilenceSeconds(double v) => audio = audio.copyWith(vadMinSilenceSeconds: v);

  double get vadMinSpeechSeconds => audio.vadMinSpeechSeconds;
  set vadMinSpeechSeconds(double v) => audio = audio.copyWith(vadMinSpeechSeconds: v);

  double get vadMaxSpeechSeconds => audio.vadMaxSpeechSeconds;
  set vadMaxSpeechSeconds(double v) => audio = audio.copyWith(vadMaxSpeechSeconds: v);

  int get preRollMs => audio.preRollMs;
  set preRollMs(int v) => audio = audio.copyWith(preRollMs: v);

  int get postRollMs => audio.postRollMs;
  set postRollMs(int v) => audio = audio.copyWith(postRollMs: v);

  bool get enableTwoPass => audio.enableTwoPass;
  set enableTwoPass(bool v) => audio = audio.copyWith(enableTwoPass: v);

  bool get autoSubmitOnTimeout => audio.autoSubmitOnTimeout;
  set autoSubmitOnTimeout(bool v) => audio = audio.copyWith(autoSubmitOnTimeout: v);

  String get geminiApiKey => audio.geminiApiKey;
  set geminiApiKey(String v) => audio = audio.copyWith(geminiApiKey: v);

  String get geminiAsrModel => audio.geminiAsrModel;
  set geminiAsrModel(String v) => audio = audio.copyWith(geminiAsrModel: v);

  String get audioInputDeviceId => audio.audioInputDeviceId;
  set audioInputDeviceId(String v) => audio = audio.copyWith(audioInputDeviceId: v);

  String get audioInputDeviceLabel => audio.audioInputDeviceLabel;
  set audioInputDeviceLabel(String v) => audio = audio.copyWith(audioInputDeviceLabel: v);

  String get audioOutputDeviceId => audio.audioOutputDeviceId;
  set audioOutputDeviceId(String v) => audio = audio.copyWith(audioOutputDeviceId: v);

  String get audioOutputDeviceLabel => audio.audioOutputDeviceLabel;
  set audioOutputDeviceLabel(String v) => audio = audio.copyWith(audioOutputDeviceLabel: v);

  bool get enableSpeakerVerification => audio.enableSpeakerVerification;
  set enableSpeakerVerification(bool v) => audio = audio.copyWith(enableSpeakerVerification: v);

  double get speakerSimilarityThreshold => audio.speakerSimilarityThreshold;
  set speakerSimilarityThreshold(double v) => audio = audio.copyWith(speakerSimilarityThreshold: v);

  bool get speakerVerifyWakeOnly => audio.speakerVerifyWakeOnly;
  set speakerVerifyWakeOnly(bool v) => audio = audio.copyWith(speakerVerifyWakeOnly: v);

  double get speakerMinSpeechSeconds => audio.speakerMinSpeechSeconds;
  set speakerMinSpeechSeconds(double v) => audio = audio.copyWith(speakerMinSpeechSeconds: v);

  double get speakerEnergyThreshold => audio.speakerEnergyThreshold;
  set speakerEnergyThreshold(double v) => audio = audio.copyWith(speakerEnergyThreshold: v);

  String get speakerModelPath => audio.speakerModelPath;
  set speakerModelPath(String v) => audio = audio.copyWith(speakerModelPath: v);

  List<List<double>> get ownerSpeakerEmbeddings => audio.ownerSpeakerEmbeddings;
  set ownerSpeakerEmbeddings(List<List<double>> v) => audio = audio.copyWith(ownerSpeakerEmbeddings: v);

  bool get enableTargetSpeakerExtraction => audio.enableTargetSpeakerExtraction;
  set enableTargetSpeakerExtraction(bool v) => audio = audio.copyWith(enableTargetSpeakerExtraction: v);

  double get tseSimilarityThreshold => audio.tseSimilarityThreshold;
  set tseSimilarityThreshold(double v) => audio = audio.copyWith(tseSimilarityThreshold: v);

  double get tseAttenuationDb => audio.tseAttenuationDb;
  set tseAttenuationDb(double v) => audio = audio.copyWith(tseAttenuationDb: v);

  // --- LlmConfig 属性代理 ---
  String get openAiBaseUrl => llm.openAiBaseUrl;
  set openAiBaseUrl(String v) => llm = llm.copyWith(openAiBaseUrl: v);

  String get openAiApiKey => llm.openAiApiKey;
  set openAiApiKey(String v) => llm = llm.copyWith(openAiApiKey: v);

  String get openAiModel => llm.openAiModel;
  set openAiModel(String v) => llm = llm.copyWith(openAiModel: v);

  bool get disableThinking => llm.disableThinking;
  set disableThinking(bool v) => llm = llm.copyWith(disableThinking: v);

  bool get enableWebSearch => llm.enableWebSearch;
  set enableWebSearch(bool v) => llm = llm.copyWith(enableWebSearch: v);

  bool get enableLightRag => llm.enableLightRag;
  set enableLightRag(bool v) => llm = llm.copyWith(enableLightRag: v);

  String get lightRagBaseUrl => llm.lightRagBaseUrl;
  set lightRagBaseUrl(String v) => llm = llm.copyWith(lightRagBaseUrl: v);

  String get systemPrompt => llm.systemPrompt;
  set systemPrompt(String v) => llm = llm.copyWith(systemPrompt: v);

  String get locationAddress => llm.locationAddress;
  set locationAddress(String v) => llm = llm.copyWith(locationAddress: v);

  List<String> get cachedAvailableModels => llm.cachedAvailableModels;
  set cachedAvailableModels(List<String> v) => llm = llm.copyWith(cachedAvailableModels: v);

  // --- TtsConfig 属性代理 ---
  bool get enableBargeIn => tts.enableBargeIn;
  set enableBargeIn(bool v) => tts = tts.copyWith(enableBargeIn: v);

  bool get enableTtsPlayback => tts.enableTtsPlayback;
  set enableTtsPlayback(bool v) => tts = tts.copyWith(enableTtsPlayback: v);

  double get ttsSpeed => tts.ttsSpeed;
  set ttsSpeed(double v) => tts = tts.copyWith(ttsSpeed: v);

  int get playbackVolume => tts.playbackVolume;
  set playbackVolume(int v) => tts = tts.copyWith(playbackVolume: v);

  bool get enablePromptTone => tts.enablePromptTone;
  set enablePromptTone(bool v) => tts = tts.copyWith(enablePromptTone: v);

  String get ttsEngine => tts.ttsEngine;
  set ttsEngine(String v) => tts = tts.copyWith(ttsEngine: v);

  String get edgeVoice => tts.edgeVoice;
  set edgeVoice(String v) => tts = tts.copyWith(edgeVoice: v);

  // --- VisionConfig 属性代理 ---
  String get captureSource => vision.captureSource;
  set captureSource(String v) => vision = vision.copyWith(captureSource: v);

  String get nanoWlanInterface => vision.nanoWlanInterface;
  set nanoWlanInterface(String v) => vision = vision.copyWith(nanoWlanInterface: v);

  String get nanoSsid => vision.nanoSsid;
  set nanoSsid(String v) => vision = vision.copyWith(nanoSsid: v);

  String get nanoPassword => vision.nanoPassword;
  set nanoPassword(String v) => vision = vision.copyWith(nanoPassword: v);

  String get nanoBleAddress => vision.nanoBleAddress;
  set nanoBleAddress(String v) => vision = vision.copyWith(nanoBleAddress: v);

  bool get enableVisionIntent => vision.enableVisionIntent;
  set enableVisionIntent(bool v) => vision = vision.copyWith(enableVisionIntent: v);

  double get visionSimilarityThreshold => vision.visionSimilarityThreshold;
  set visionSimilarityThreshold(double v) => vision = vision.copyWith(visionSimilarityThreshold: v);

  int get cameraKeepAliveMinutes => vision.cameraKeepAliveMinutes;
  set cameraKeepAliveMinutes(int v) => vision = vision.copyWith(cameraKeepAliveMinutes: v);

  String get cameraLensDirection => vision.cameraLensDirection;
  set cameraLensDirection(String v) => vision = vision.copyWith(cameraLensDirection: v);

  int get cameraResolutionWidth => vision.cameraResolutionWidth;
  set cameraResolutionWidth(int v) => vision = vision.copyWith(cameraResolutionWidth: v);

  int get cameraResolutionHeight => vision.cameraResolutionHeight;
  set cameraResolutionHeight(int v) => vision = vision.copyWith(cameraResolutionHeight: v);

  int get cameraSendShortEdge => vision.cameraSendShortEdge;
  set cameraSendShortEdge(int v) => vision = vision.copyWith(cameraSendShortEdge: v);

  List<String> get customVisionPrototypes => vision.customVisionPrototypes;
  set customVisionPrototypes(List<String> v) => vision = vision.copyWith(customVisionPrototypes: v);

  String get linuxCameraDevice => vision.linuxCameraDevice;
  set linuxCameraDevice(String v) => vision = vision.copyWith(linuxCameraDevice: v);

  // --- ServerConfig 属性代理 ---
  bool get autoStartMicOnLaunch => server.autoStartMicOnLaunch;
  set autoStartMicOnLaunch(bool v) => server = server.copyWith(autoStartMicOnLaunch: v);

  String get webAccessPassword => server.webAccessPassword;
  set webAccessPassword(String v) => server = server.copyWith(webAccessPassword: v);

  bool get enableFloatingCapsule => server.enableFloatingCapsule;
  set enableFloatingCapsule(bool v) => server = server.copyWith(enableFloatingCapsule: v);

  List<String> get startWords => audio.startWords;
  List<String> get endWords => audio.endWords;
  List<String> get resetWords => audio.resetWords;
  List<String> get exitContinuousWords => audio.exitContinuousWords;

  static List<String> splitTriggerWords(String raw) =>
      AudioConfig.splitTriggerWords(raw);

  /// 序列化为平坦 JSON Map（完全匹配 233 服务器 preferences.json）
  Map<String, dynamic> toMap() {
    return {
      ...audio.toMap(),
      ...llm.toMap(),
      ...tts.toMap(),
      ...vision.toMap(),
      ...server.toMap(),
    };
  }

  /// 从平坦 JSON Map 解析构建领域化对象
  factory AppSettings.fromMap(Map<String, dynamic> map) {
    return AppSettings(
      audio: AudioConfig.fromMap(map),
      llm: LlmConfig.fromMap(map),
      tts: TtsConfig.fromMap(map),
      vision: VisionConfig.fromMap(map),
      server: ServerConfig.fromMap(map),
    );
  }

  /// 增量合并平坦配置字典，返回全新的不可变 AppSettings
  AppSettings copyWithMap(Map<String, dynamic> delta) {
    return AppSettings(
      audio: audio.copyWithMap(delta),
      llm: llm.copyWithMap(delta),
      tts: tts.copyWithMap(delta),
      vision: vision.copyWithMap(delta),
      server: server.copyWithMap(delta),
    );
  }

  /// 局部增量就地更新配置
  void applyMap(Map<String, dynamic> delta) {
    audio = audio.copyWithMap(delta);
    llm = llm.copyWithMap(delta);
    tts = tts.copyWithMap(delta);
    vision = vision.copyWithMap(delta);
    server = server.copyWithMap(delta);
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

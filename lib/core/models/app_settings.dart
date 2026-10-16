import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../constants/app_constants.dart';

class AppSettings {
  String startWord;
  String endWord;
  String resetWord;
  double similarityThreshold;
  int silenceTimeoutSeconds;

  String openAiBaseUrl;
  String openAiApiKey;
  String openAiModel;
  String systemPrompt;

  bool useRemoteEmbedding;
  String embeddingBaseUrl;
  String embeddingApiKey;
  String embeddingModel;
  String localEmbeddingModelPath;

  bool enableBargeIn;
  bool enableTtsPlayback;
  double ttsSpeed;
  bool enableAcousticWakeFilter;
  bool enablePromptTone;
  String ttsEngine;
  String edgeVoice;

  AppSettings({
    this.startWord = AppConstants.defaultStartWord,
    this.endWord = AppConstants.defaultEndWord,
    this.resetWord = AppConstants.defaultResetWord,
    this.similarityThreshold = AppConstants.defaultSimilarityThreshold,
    this.silenceTimeoutSeconds = AppConstants.defaultSilenceTimeoutSeconds,
    this.openAiBaseUrl = AppConstants.defaultOpenAiBaseUrl,
    this.openAiApiKey = AppConstants.defaultOpenAiApiKey,
    this.openAiModel = AppConstants.defaultOpenAiModel,
    this.systemPrompt = AppConstants.defaultSystemPrompt,
    this.useRemoteEmbedding = true,
    this.embeddingBaseUrl = AppConstants.defaultEmbeddingBaseUrl,
    this.embeddingApiKey = AppConstants.defaultEmbeddingApiKey,
    this.embeddingModel = AppConstants.defaultEmbeddingModel,
    this.localEmbeddingModelPath = '',
    this.enableBargeIn = true,
    this.enableTtsPlayback = true,
    this.ttsSpeed = 1.0,
    this.enableAcousticWakeFilter = false,
    this.enablePromptTone = true,
    this.ttsEngine = AppConstants.defaultTtsEngine,
    this.edgeVoice = AppConstants.defaultEdgeVoice,
  });

  Map<String, dynamic> toMap() {
    return {
      'startWord': startWord,
      'endWord': endWord,
      'resetWord': resetWord,
      'similarityThreshold': similarityThreshold,
      'silenceTimeoutSeconds': silenceTimeoutSeconds,
      'openAiBaseUrl': openAiBaseUrl,
      'openAiApiKey': openAiApiKey,
      'openAiModel': openAiModel,
      'systemPrompt': systemPrompt,
      'useRemoteEmbedding': useRemoteEmbedding,
      'embeddingBaseUrl': embeddingBaseUrl,
      'embeddingApiKey': embeddingApiKey,
      'embeddingModel': embeddingModel,
      'localEmbeddingModelPath': localEmbeddingModelPath,
      'enableBargeIn': enableBargeIn,
      'enableTtsPlayback': enableTtsPlayback,
      'ttsSpeed': ttsSpeed,
      'enableAcousticWakeFilter': enableAcousticWakeFilter,
      'enablePromptTone': enablePromptTone,
      'ttsEngine': ttsEngine,
      'edgeVoice': edgeVoice,
    };
  }

  factory AppSettings.fromMap(Map<String, dynamic> map) {
    return AppSettings(
      startWord: map['startWord'] as String? ?? AppConstants.defaultStartWord,
      endWord: map['endWord'] as String? ?? AppConstants.defaultEndWord,
      resetWord: map['resetWord'] as String? ?? AppConstants.defaultResetWord,
      similarityThreshold: (map['similarityThreshold'] as num?)?.toDouble() ??
          AppConstants.defaultSimilarityThreshold,
      silenceTimeoutSeconds: map['silenceTimeoutSeconds'] as int? ??
          AppConstants.defaultSilenceTimeoutSeconds,
      openAiBaseUrl: map['openAiBaseUrl'] as String? ?? AppConstants.defaultOpenAiBaseUrl,
      openAiApiKey: map['openAiApiKey'] as String? ?? AppConstants.defaultOpenAiApiKey,
      openAiModel: map['openAiModel'] as String? ?? AppConstants.defaultOpenAiModel,
      systemPrompt: map['systemPrompt'] as String? ?? AppConstants.defaultSystemPrompt,
      useRemoteEmbedding: map['useRemoteEmbedding'] as bool? ?? true,
      embeddingBaseUrl: map['embeddingBaseUrl'] as String? ?? AppConstants.defaultEmbeddingBaseUrl,
      embeddingApiKey: map['embeddingApiKey'] as String? ?? AppConstants.defaultEmbeddingApiKey,
      embeddingModel: map['embeddingModel'] as String? ?? AppConstants.defaultEmbeddingModel,
      localEmbeddingModelPath: map['localEmbeddingModelPath'] as String? ?? '',
      enableBargeIn: map['enableBargeIn'] as bool? ?? true,
      enableTtsPlayback: map['enableTtsPlayback'] as bool? ?? true,
      ttsSpeed: (map['ttsSpeed'] as num?)?.toDouble() ?? 1.0,
      enableAcousticWakeFilter: map['enableAcousticWakeFilter'] as bool? ?? true,
      enablePromptTone: map['enablePromptTone'] as bool? ?? true,
      ttsEngine: map['ttsEngine'] as String? ?? AppConstants.defaultTtsEngine,
      edgeVoice: map['edgeVoice'] as String? ?? AppConstants.defaultEdgeVoice,
    );
  }

  static const String _prefsKey = 'app_settings_data_v1';

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(toMap()));
  }

  static Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_prefsKey);
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

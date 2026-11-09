import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../controllers/assistant_controller.dart';
import '../../core/constants/app_constants.dart';
import '../../core/models/app_settings.dart';
import '../../core/models/device_options.dart';
import 'settings/widgets/asr_settings_section.dart';
import 'settings/widgets/camera_vision_section.dart';
import 'settings/widgets/llm_settings_section.dart';
import 'settings/widgets/open_code_settings_card.dart';
import 'settings/widgets/pipeline_mode_section.dart';
import 'settings/widgets/speaker_verification_section.dart';
import 'settings/widgets/tts_settings_section.dart';
import 'settings/widgets/wake_dialogue_section.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  late final AssistantController _controller;
  late final TextEditingController _startWordCtrl;
  late final TextEditingController _openAiBaseUrlCtrl;
  late final TextEditingController _openAiApiKeyCtrl;
  late final TextEditingController _openAiModelCtrl;
  late final TextEditingController _systemPromptCtrl;
  late final TextEditingController _locationCtrl;
  late final TextEditingController _geminiApiKeyCtrl;
  late final TextEditingController _geminiAsrModelCtrl;
  late final TextEditingController _geminiLiveModelCtrl;
  late String _pipelineMode;
  late String _geminiLiveVoice;
  late String _geminiLiveAdvancedMode;
  late String _geminiLiveThinkingLevel;
  late bool _geminiLiveIncludeThoughts;

  late double _silenceTimeoutSeconds;
  late String _startWordMode;
  late int _continuousModeTimeoutMinutes;
  late bool _disableThinking;
  late bool _enableWebSearch;
  late bool _enableOpenCode;
  late String _codeAgentProvider;
  late final TextEditingController _openCodeCommandCtrl;
  late final TextEditingController _hermesCommandCtrl;
  late int _openCodeTimeoutSeconds;
  late int _openCodeProgressIntervalSeconds;

  // 主人声纹识别
  late bool _enableSpeakerVerification;
  late double _speakerSimilarityThreshold;
  late bool _speakerVerifyWakeOnly;
  late double _speakerMinSpeechSeconds;
  late double _speakerEnergyThreshold;
  late bool _enableTargetSpeakerExtraction;
  late double _tseAttenuationDb;

  late bool _enableLightRag;
  late final TextEditingController _lightRagUrlCtrl;
  late bool _enableBargeIn;
  late bool _enableTtsPlayback;
  late double _ttsSpeed;
  late String _asrEngine;
  late bool _enablePromptTone;
  late String _ttsEngine;
  late String _edgeVoice;

  // 高级 ASR / VAD 配置
  late double _vadThreshold;
  late double _vadMinSilenceSeconds;
  late double _vadMinSpeechSeconds;
  late double _vadMaxSpeechSeconds;
  late int _preRollMs;
  late int _postRollMs;
  late bool _enableTwoPass;
  late bool _autoSubmitOnTimeout;

  // 大模型下拉选择与拉取状态
  late List<String> _availableModels;

  // 视觉意图与摄像头配置状态
  late String _captureSource;
  late bool _enableFloatingCapsule;
  late String _nanoWlanInterface;
  late String _nanoSsid;
  late String _nanoPassword;
  late final TextEditingController _nanoBleAddressCtrl;
  List<String> _availableWlanInterfaces = [];

  late bool _enableVisionIntent;
  late int _cameraKeepAliveMinutes;
  late String _cameraLensDirection;
  late int _cameraResolutionWidth;
  late int _cameraResolutionHeight;
  late int _cameraSendShortEdge;

  bool _isAndroid = false;
  bool? _cameraPermissionGranted;

  // 录音输入设备（仅 Android）
  List<AudioInputDeviceOption> _audioInputDevices = const [];
  String _audioInputDeviceId = '';
  String _audioInputDeviceLabel = '';
  bool _isLoadingAudioDevices = false;

  Timer? _autoSaveTimer;
  bool _hasPendingSave = false;

  late final List<TextEditingController> _autoSaveTextControllers;
  late List<String> _lastAutoSavedTexts;

  @override
  void initState() {
    super.initState();
    _controller = context.read<AssistantController>();
    final settings = _controller.settings;

    _startWordCtrl = TextEditingController(text: settings.startWord);
    _openAiBaseUrlCtrl = TextEditingController(text: settings.openAiBaseUrl);
    _openAiApiKeyCtrl = TextEditingController(text: settings.openAiApiKey);
    _openAiModelCtrl = TextEditingController(text: settings.openAiModel);
    _systemPromptCtrl = TextEditingController(text: settings.systemPrompt);
    _locationCtrl = TextEditingController(text: settings.locationAddress);
    _geminiApiKeyCtrl = TextEditingController(text: settings.geminiApiKey);
    _geminiAsrModelCtrl = TextEditingController(text: settings.geminiAsrModel);
    _geminiLiveModelCtrl =
        TextEditingController(text: settings.geminiLiveModel);
    _pipelineMode = settings.pipelineMode;
    _geminiLiveVoice = settings.geminiLiveVoice;
    _geminiLiveAdvancedMode = settings.geminiLiveAdvancedMode;
    _geminiLiveThinkingLevel = settings.geminiLiveThinkingLevel;
    _geminiLiveIncludeThoughts = settings.geminiLiveIncludeThoughts;

    _availableModels = List.from(settings.cachedAvailableModels);
    final currentModel = settings.openAiModel.trim();
    if (currentModel.isNotEmpty && !_availableModels.contains(currentModel)) {
      _availableModels.insert(0, currentModel);
    }
    if (_availableModels.isEmpty) {
      _availableModels = [
        'WB.deepseek-v4.1-flash',
        'gpt-4o-mini',
        'gpt-4o',
        'deepseek-chat',
        'qwen-turbo',
      ];
    }
    if (_openAiModelCtrl.text.trim().isEmpty) {
      _openAiModelCtrl.text = _availableModels.first;
    }

    _silenceTimeoutSeconds = settings.silenceTimeoutSeconds;
    _startWordMode = settings.startWordMode;
    _continuousModeTimeoutMinutes = settings.continuousModeTimeoutMinutes;
    _disableThinking = settings.disableThinking;
    _enableWebSearch = settings.enableWebSearch;
    _enableOpenCode = settings.enableOpenCode;
    _codeAgentProvider = settings.codeAgentProvider;
    _openCodeCommandCtrl =
        TextEditingController(text: settings.openCodeCommand);
    _hermesCommandCtrl = TextEditingController(text: settings.hermesCommand);
    _openCodeTimeoutSeconds = settings.openCodeTimeoutSeconds;
    _openCodeProgressIntervalSeconds = settings.openCodeProgressIntervalSeconds;

    _enableSpeakerVerification = settings.enableSpeakerVerification;
    _speakerSimilarityThreshold = settings.speakerSimilarityThreshold;
    _speakerVerifyWakeOnly = settings.speakerVerifyWakeOnly;
    _speakerMinSpeechSeconds = settings.speakerMinSpeechSeconds;
    _speakerEnergyThreshold = settings.speakerEnergyThreshold;
    _enableTargetSpeakerExtraction = settings.enableTargetSpeakerExtraction;
    _tseAttenuationDb = settings.tseAttenuationDb;

    _enableLightRag = settings.enableLightRag;

    _lightRagUrlCtrl = TextEditingController(text: settings.lightRagBaseUrl);
    _enableBargeIn = settings.enableBargeIn;
    _enableTtsPlayback = settings.enableTtsPlayback;
    _ttsSpeed = settings.ttsSpeed;
    _asrEngine = const {
      AppConstants.asrEngineSenseVoice,
      AppConstants.asrEngineStreaming,
      AppConstants.asrEngineGeminiLive,
    }.contains(settings.asrEngine)
        ? settings.asrEngine
        : AppConstants.defaultAsrEngine;
    _enablePromptTone = settings.enablePromptTone;
    _ttsEngine = settings.ttsEngine;
    _edgeVoice = settings.edgeVoice;

    _vadThreshold = settings.vadThreshold;
    _vadMinSilenceSeconds = settings.vadMinSilenceSeconds;
    _vadMinSpeechSeconds = settings.vadMinSpeechSeconds;
    _vadMaxSpeechSeconds = settings.vadMaxSpeechSeconds;
    _preRollMs = settings.preRollMs;
    _postRollMs = settings.postRollMs;
    _enableTwoPass = settings.enableTwoPass;
    _autoSubmitOnTimeout = settings.autoSubmitOnTimeout;

    _audioInputDeviceId = settings.audioInputDeviceId;
    _audioInputDeviceLabel = settings.audioInputDeviceLabel;

    _enableVisionIntent = settings.enableVisionIntent;
    _cameraKeepAliveMinutes = settings.cameraKeepAliveMinutes;
    _cameraLensDirection = settings.cameraLensDirection;
    _cameraResolutionWidth = settings.cameraResolutionWidth;
    _cameraResolutionHeight = settings.cameraResolutionHeight;
    _cameraSendShortEdge = settings.cameraSendShortEdge;

    _captureSource = settings.captureSource;
    _enableFloatingCapsule = settings.enableFloatingCapsule;
    _isAndroid = Platform.isAndroid;
    _nanoWlanInterface = settings.nanoWlanInterface;
    _nanoSsid = settings.nanoSsid;
    _nanoPassword = settings.nanoPassword;
    _nanoBleAddressCtrl = TextEditingController(text: settings.nanoBleAddress);

    _autoSaveTextControllers = [
      _startWordCtrl,
      _openAiBaseUrlCtrl,
      _openAiApiKeyCtrl,
      _openAiModelCtrl,
      _systemPromptCtrl,
      _locationCtrl,
      _openCodeCommandCtrl,
      _hermesCommandCtrl,
      _lightRagUrlCtrl,
      _geminiApiKeyCtrl,
      _geminiAsrModelCtrl,
      _geminiLiveModelCtrl,
      _nanoBleAddressCtrl,
    ];
    for (final ctrl in _autoSaveTextControllers) {
      ctrl.addListener(_onTextControllerChanged);
    }
    _lastAutoSavedTexts = _autoSaveTextControllers.map((c) => c.text).toList();

    FocusManager.instance.addListener(_onFocusChanged);

    if (_isAndroid) {
      WidgetsBinding.instance.addObserver(this);
      _refreshCameraPermission();
      _loadAudioInputDevices();
    }

    _controller.getWlanInterfaces().then((list) {
      if (mounted) {
        setState(() => _availableWlanInterfaces = list);
      }
    });
  }

  void _onFocusChanged() {
    if (_hasPendingSave) {
      _scheduleAutoSave(immediate: true);
    }
  }

  void _onTextControllerChanged() {
    var changed = false;
    for (var i = 0; i < _autoSaveTextControllers.length; i++) {
      if (_autoSaveTextControllers[i].text != _lastAutoSavedTexts[i]) {
        _lastAutoSavedTexts[i] = _autoSaveTextControllers[i].text;
        changed = true;
      }
    }
    if (!changed) return;
    _scheduleAutoSave();
  }

  void _scheduleAutoSave({bool immediate = false}) {
    _hasPendingSave = true;
    _autoSaveTimer?.cancel();
    if (immediate) {
      unawaited(_saveSettings());
    } else {
      _autoSaveTimer = Timer(const Duration(milliseconds: 1500), () {
        unawaited(_saveSettings());
      });
    }
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_onFocusChanged);
    _autoSaveTimer?.cancel();
    for (final ctrl in _autoSaveTextControllers) {
      ctrl.removeListener(_onTextControllerChanged);
    }
    if (_hasPendingSave) {
      unawaited(_saveSettings());
    }
    if (_isAndroid) {
      WidgetsBinding.instance.removeObserver(this);
    }
    _startWordCtrl.dispose();
    _openAiBaseUrlCtrl.dispose();
    _openAiApiKeyCtrl.dispose();
    _openAiModelCtrl.dispose();
    _systemPromptCtrl.dispose();
    _locationCtrl.dispose();
    _openCodeCommandCtrl.dispose();
    _hermesCommandCtrl.dispose();
    _lightRagUrlCtrl.dispose();
    _geminiApiKeyCtrl.dispose();
    _geminiAsrModelCtrl.dispose();
    _geminiLiveModelCtrl.dispose();
    _nanoBleAddressCtrl.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _isAndroid) {
      _refreshCameraPermission();
    }
  }

  Future<void> _refreshCameraPermission() async {
    if (!_isAndroid) return;
    final granted = await _controller.hasCameraPermission();
    if (mounted) {
      setState(() => _cameraPermissionGranted = granted);
    }
  }

  Future<void> _handleGrantCameraPermission() async {
    final granted = await _controller.requestCameraPermission();
    if (!mounted) return;
    setState(() => _cameraPermissionGranted = granted);
    if (!granted) {
      await _controller.openCameraAppSettings();
    }
  }

  Future<void> _loadAudioInputDevices() async {
    setState(() => _isLoadingAudioDevices = true);
    final devices = await _controller.listAudioInputDevices();
    if (!mounted) return;
    setState(() {
      _audioInputDevices = devices;
      _isLoadingAudioDevices = false;
    });
  }

  AppSettings _buildCurrentSettings() {
    return AppSettings(
      startWord: _startWordCtrl.text.trim(),
      startWordMode: _startWordMode,
      continuousModeTimeoutMinutes: _continuousModeTimeoutMinutes,
      enableStartWordDetection:
          _startWordMode != AppConstants.startWordModeDisabled,
      silenceTimeoutSeconds: _silenceTimeoutSeconds,
      asrEngine: _asrEngine,
      vadThreshold: _vadThreshold,
      vadMinSilenceSeconds: _vadMinSilenceSeconds,
      vadMinSpeechSeconds: _vadMinSpeechSeconds,
      vadMaxSpeechSeconds: _vadMaxSpeechSeconds,
      preRollMs: _preRollMs,
      postRollMs: _postRollMs,
      enableTwoPass: _enableTwoPass,
      autoSubmitOnTimeout: _autoSubmitOnTimeout,
      openAiBaseUrl: _openAiBaseUrlCtrl.text.trim(),
      openAiApiKey: _openAiApiKeyCtrl.text.trim(),
      openAiModel: _openAiModelCtrl.text.trim(),
      cachedAvailableModels: _availableModels,
      disableThinking: _disableThinking,
      enableWebSearch: _enableWebSearch,
      enableOpenCode: _enableOpenCode,
      codeAgentProvider: _codeAgentProvider,
      openCodeCommand: _openCodeCommandCtrl.text.trim().isEmpty
          ? AppConstants.defaultOpenCodeCommand
          : _openCodeCommandCtrl.text.trim(),
      hermesCommand: _hermesCommandCtrl.text.trim().isEmpty
          ? AppConstants.defaultHermesCommand
          : _hermesCommandCtrl.text.trim(),
      openCodeTimeoutSeconds: _openCodeTimeoutSeconds,
      openCodeProgressIntervalSeconds: _openCodeProgressIntervalSeconds,
      enableLightRag: _enableLightRag,
      lightRagBaseUrl: _lightRagUrlCtrl.text.trim(),
      systemPrompt: _systemPromptCtrl.text.trim(),
      locationAddress: _locationCtrl.text.trim(),
      pipelineMode: _pipelineMode,
      geminiApiKey: _geminiApiKeyCtrl.text.trim(),
      geminiAsrModel: _geminiAsrModelCtrl.text.trim(),
      geminiLiveModel: _geminiLiveModelCtrl.text.trim().isEmpty
          ? AppConstants.defaultGeminiLiveModel
          : _geminiLiveModelCtrl.text.trim(),
      geminiLiveVoice: _geminiLiveVoice,
      geminiLiveAdvancedMode: _geminiLiveAdvancedMode,
      geminiLiveThinkingLevel: _geminiLiveThinkingLevel,
      geminiLiveIncludeThoughts: _geminiLiveIncludeThoughts,
      enableBargeIn: _enableBargeIn,
      enableTtsPlayback: _enableTtsPlayback,
      ttsSpeed: _ttsSpeed,
      enablePromptTone: _enablePromptTone,
      audioInputDeviceId: _audioInputDeviceId,
      audioInputDeviceLabel: _audioInputDeviceLabel,
      ttsEngine: _ttsEngine,
      edgeVoice: _edgeVoice,
      captureSource: _captureSource,
      nanoWlanInterface: _nanoWlanInterface,
      nanoSsid: _nanoSsid,
      nanoPassword: _nanoPassword,
      nanoBleAddress: _nanoBleAddressCtrl.text.trim(),
      enableVisionIntent: _enableVisionIntent,
      cameraKeepAliveMinutes: _cameraKeepAliveMinutes,
      cameraLensDirection: _cameraLensDirection,
      cameraResolutionWidth: _cameraResolutionWidth,
      cameraResolutionHeight: _cameraResolutionHeight,
      cameraSendShortEdge: _cameraSendShortEdge,
      enableFloatingCapsule: _enableFloatingCapsule,
      enableSpeakerVerification: _enableSpeakerVerification,
      speakerSimilarityThreshold: _speakerSimilarityThreshold,
      speakerVerifyWakeOnly: _speakerVerifyWakeOnly,
      speakerMinSpeechSeconds: _speakerMinSpeechSeconds,
      speakerEnergyThreshold: _speakerEnergyThreshold,
      enableTargetSpeakerExtraction: _enableTargetSpeakerExtraction,
      tseAttenuationDb: _tseAttenuationDb,
      ownerSpeakerEmbeddings: _controller.settings.ownerSpeakerEmbeddings,
      speakerModelPath: _controller.settings.speakerModelPath,
    );
  }

  Future<void> _saveSettings() async {
    _hasPendingSave = false;
    final newSettings = _buildCurrentSettings();
    try {
      await _controller.updateSettings(newSettings);
    } catch (_) {
      _hasPendingSave = true;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('设置未保存：无法写入配置文件，请检查目录权限后重试。'),
        action: SnackBarAction(label: '重试', onPressed: _saveSettings),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final isGeminiLive = _pipelineMode == AppConstants.pipelineModeGeminiLive;
    return Scaffold(
      appBar: AppBar(
        title: const Text('助手设置'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          PipelineModeSection(
            controller: _controller,
            pipelineMode: _pipelineMode,
            onPipelineModeChanged: (v) => setState(() => _pipelineMode = v),
            geminiApiKeyCtrl: _geminiApiKeyCtrl,
            geminiLiveModelCtrl: _geminiLiveModelCtrl,
            geminiLiveVoice: _geminiLiveVoice,
            onGeminiLiveVoiceChanged: (v) =>
                setState(() => _geminiLiveVoice = v),
            geminiLiveAdvancedMode: _geminiLiveAdvancedMode,
            onGeminiLiveAdvancedModeChanged: (v) =>
                setState(() => _geminiLiveAdvancedMode = v),
            geminiLiveThinkingLevel: _geminiLiveThinkingLevel,
            onGeminiLiveThinkingLevelChanged: (v) =>
                setState(() => _geminiLiveThinkingLevel = v),
            geminiLiveIncludeThoughts: _geminiLiveIncludeThoughts,
            onGeminiLiveIncludeThoughtsChanged: (v) =>
                setState(() => _geminiLiveIncludeThoughts = v),
            isAndroid: _isAndroid,
            audioInputDevices: _audioInputDevices,
            audioInputDeviceId: _audioInputDeviceId,
            audioInputDeviceLabel: _audioInputDeviceLabel,
            isLoadingAudioDevices: _isLoadingAudioDevices,
            onRefreshAudioDevices: _loadAudioInputDevices,
            onAudioInputDeviceChanged: (id, label) {
              setState(() {
                _audioInputDeviceId = id;
                _audioInputDeviceLabel = label;
              });
            },
            onAutoSave: _scheduleAutoSave,
          ),
          const SizedBox(height: 16),
          if (!isGeminiLive) ...[
            AsrSettingsSection(
              controller: _controller,
              asrEngine: _asrEngine,
              onAsrEngineChanged: (v) => setState(() => _asrEngine = v),
              geminiApiKeyCtrl: _geminiApiKeyCtrl,
              geminiAsrModelCtrl: _geminiAsrModelCtrl,
              isAndroid: _isAndroid,
              audioInputDevices: _audioInputDevices,
              audioInputDeviceId: _audioInputDeviceId,
              audioInputDeviceLabel: _audioInputDeviceLabel,
              isLoadingAudioDevices: _isLoadingAudioDevices,
              onRefreshAudioDevices: _loadAudioInputDevices,
              onAudioInputDeviceChanged: (id, label) {
                setState(() {
                  _audioInputDeviceId = id;
                  _audioInputDeviceLabel = label;
                });
              },
              autoSubmitOnTimeout: _autoSubmitOnTimeout,
              onAutoSubmitOnTimeoutChanged: (v) =>
                  setState(() => _autoSubmitOnTimeout = v),
              vadThreshold: _vadThreshold,
              onVadThresholdChanged: (v) => setState(() => _vadThreshold = v),
              vadMinSilenceSeconds: _vadMinSilenceSeconds,
              onVadMinSilenceChanged: (v) =>
                  setState(() => _vadMinSilenceSeconds = v),
              vadMinSpeechSeconds: _vadMinSpeechSeconds,
              onVadMinSpeechChanged: (v) =>
                  setState(() => _vadMinSpeechSeconds = v),
              vadMaxSpeechSeconds: _vadMaxSpeechSeconds,
              onVadMaxSpeechChanged: (v) =>
                  setState(() => _vadMaxSpeechSeconds = v),
              preRollMs: _preRollMs,
              onPreRollMsChanged: (v) => setState(() => _preRollMs = v),
              postRollMs: _postRollMs,
              onPostRollMsChanged: (v) => setState(() => _postRollMs = v),
              onAutoSave: _scheduleAutoSave,
            ),
            const SizedBox(height: 24),
            WakeDialogueSection(
              startWordMode: _startWordMode,
              onStartWordModeChanged: (v) => setState(() => _startWordMode = v),
              continuousModeTimeoutMinutes: _continuousModeTimeoutMinutes,
              onContinuousModeTimeoutMinutesChanged: (v) =>
                  setState(() => _continuousModeTimeoutMinutes = v),
              startWordCtrl: _startWordCtrl,
              silenceTimeoutSeconds: _silenceTimeoutSeconds,
              onSilenceTimeoutSecondsChanged: (v) =>
                  setState(() => _silenceTimeoutSeconds = v),
              onAutoSave: _scheduleAutoSave,
            ),
            const SizedBox(height: 16),
          ],
          SpeakerVerificationSection(
            controller: _controller,
            enableSpeakerVerification: _enableSpeakerVerification,
            speakerSimilarityThreshold: _speakerSimilarityThreshold,
            speakerVerifyWakeOnly: _speakerVerifyWakeOnly,
            speakerMinSpeechSeconds: _speakerMinSpeechSeconds,
            speakerEnergyThreshold: _speakerEnergyThreshold,
            enableTargetSpeakerExtraction: _enableTargetSpeakerExtraction,
            tseAttenuationDb: _tseAttenuationDb,
            onEnableChanged: (v) =>
                setState(() => _enableSpeakerVerification = v),
            onSimilarityThresholdChanged: (v) =>
                setState(() => _speakerSimilarityThreshold = v),
            onWakeOnlyChanged: (v) =>
                setState(() => _speakerVerifyWakeOnly = v),
            onMinSpeechSecondsChanged: (v) =>
                setState(() => _speakerMinSpeechSeconds = v),
            onEnergyThresholdChanged: (v) =>
                setState(() => _speakerEnergyThreshold = v),
            onTargetSpeakerExtractionChanged: (v) =>
                setState(() => _enableTargetSpeakerExtraction = v),
            onTseAttenuationDbChanged: (v) =>
                setState(() => _tseAttenuationDb = v),
            onAutoSave: _scheduleAutoSave,
          ),
          const SizedBox(height: 16),
          LlmSettingsSection(
            controller: _controller,
            openAiBaseUrlCtrl: _openAiBaseUrlCtrl,
            openAiApiKeyCtrl: _openAiApiKeyCtrl,
            openAiModelCtrl: _openAiModelCtrl,
            availableModels: _availableModels,
            onAvailableModelsChanged: (models) =>
                setState(() => _availableModels = models),
            disableThinking: _disableThinking,
            onDisableThinkingChanged: (v) =>
                setState(() => _disableThinking = v),
            enableWebSearch: _enableWebSearch,
            onEnableWebSearchChanged: (v) =>
                setState(() => _enableWebSearch = v),
            enableLightRag: _enableLightRag,
            onEnableLightRagChanged: (v) => setState(() => _enableLightRag = v),
            lightRagUrlCtrl: _lightRagUrlCtrl,
            systemPromptCtrl: _systemPromptCtrl,
            locationCtrl: _locationCtrl,
            isGeminiLiveMode: isGeminiLive,
            onAutoSave: _scheduleAutoSave,
          ),
          const SizedBox(height: 16),
          OpenCodeSettingsCard(
            controller: _controller,
            enableOpenCode: _enableOpenCode,
            onEnableOpenCodeChanged: (v) => setState(() => _enableOpenCode = v),
            codeAgentProvider: _codeAgentProvider,
            onCodeAgentProviderChanged: (v) =>
                setState(() => _codeAgentProvider = v),
            openCodeCommandCtrl: _openCodeCommandCtrl,
            hermesCommandCtrl: _hermesCommandCtrl,
            openCodeTimeoutSeconds: _openCodeTimeoutSeconds,
            openCodeProgressIntervalSeconds: _openCodeProgressIntervalSeconds,
            onOpenCodeProgressIntervalSecondsChanged: (v) =>
                setState(() => _openCodeProgressIntervalSeconds = v),
            onOpenCodeTimeoutSecondsChanged: (v) =>
                setState(() => _openCodeTimeoutSeconds = v),
            onAutoSave: _scheduleAutoSave,
          ),
          if (!isGeminiLive) ...[
            const SizedBox(height: 16),
            TtsSettingsSection(
              controller: _controller,
              enableTtsPlayback: _enableTtsPlayback,
              onEnableTtsPlaybackChanged: (v) =>
                  setState(() => _enableTtsPlayback = v),
              enableBargeIn: _enableBargeIn,
              onEnableBargeInChanged: (v) => setState(() => _enableBargeIn = v),
              enablePromptTone: _enablePromptTone,
              onEnablePromptToneChanged: (v) =>
                  setState(() => _enablePromptTone = v),
              ttsSpeed: _ttsSpeed,
              onTtsSpeedChanged: (v) => setState(() => _ttsSpeed = v),
              ttsEngine: _ttsEngine,
              onTtsEngineChanged: (v) => setState(() => _ttsEngine = v),
              edgeVoice: _edgeVoice,
              onEdgeVoiceChanged: (v) => setState(() => _edgeVoice = v),
              isAndroid: _isAndroid,
              enableFloatingCapsule: _enableFloatingCapsule,
              onEnableFloatingCapsuleChanged: (v) =>
                  setState(() => _enableFloatingCapsule = v),
              onAutoSave: _scheduleAutoSave,
            ),
          ],
          const SizedBox(height: 24),
          CameraVisionSection(
            controller: _controller,
            enableVisionIntent: _enableVisionIntent,
            onEnableVisionIntentChanged: (v) =>
                setState(() => _enableVisionIntent = v),
            captureSource: _captureSource,
            onCaptureSourceChanged: (v) => setState(() => _captureSource = v),
            cameraLensDirection: _cameraLensDirection,
            onCameraLensDirectionChanged: (v) =>
                setState(() => _cameraLensDirection = v),
            cameraResolutionWidth: _cameraResolutionWidth,
            cameraResolutionHeight: _cameraResolutionHeight,
            onCameraResolutionChanged: (w, h) {
              setState(() {
                _cameraResolutionWidth = w;
                _cameraResolutionHeight = h;
              });
            },
            cameraSendShortEdge: _cameraSendShortEdge,
            onCameraSendShortEdgeChanged: (v) =>
                setState(() => _cameraSendShortEdge = v),
            nanoWlanInterface: _nanoWlanInterface,
            onNanoWlanInterfaceChanged: (v) =>
                setState(() => _nanoWlanInterface = v),
            nanoBleAddressCtrl: _nanoBleAddressCtrl,
            availableWlanInterfaces: _availableWlanInterfaces,
            cameraKeepAliveMinutes: _cameraKeepAliveMinutes,
            onCameraKeepAliveMinutesChanged: (v) =>
                setState(() => _cameraKeepAliveMinutes = v),
            isAndroid: _isAndroid,
            cameraPermissionGranted: _cameraPermissionGranted,
            onGrantCameraPermission: _handleGrantCameraPermission,
            onAutoSave: _scheduleAutoSave,
          ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }
}

import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../controllers/assistant_controller.dart';
import '../../core/constants/app_constants.dart';
import '../../core/models/app_settings.dart';
import '../../services/llm/llm_service.dart';
import '../../services/nlp/embedding_service.dart';
import '../../services/nlp/vector_math.dart';
import '../../services/speech/audio_input_device_service.dart';
import '../../services/vision/nano/nano_wifi_driver.dart';
import '../../services/vision/nano/nano_ble_driver.dart';
import '../../services/vision/android_camera_bridge.dart';
import '../../services/system/floating_capsule_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  late final AssistantController _controller;
  late final TextEditingController _startWordCtrl;
  late final TextEditingController _endWordCtrl;
  late final TextEditingController _resetWordCtrl;
  late final TextEditingController _openAiBaseUrlCtrl;
  late final TextEditingController _openAiApiKeyCtrl;
  late final TextEditingController _openAiModelCtrl;
  late final TextEditingController _systemPromptCtrl;
  late final TextEditingController _locationCtrl;
  late final TextEditingController _embeddingBaseUrlCtrl;
  late final TextEditingController _embeddingApiKeyCtrl;
  late final TextEditingController _embeddingModelCtrl;
  late final TextEditingController _geminiApiKeyCtrl;
  late final TextEditingController _geminiAsrModelCtrl;

  late double _similarityThreshold;
  late int _silenceTimeoutSeconds;
  late bool _useRemoteEmbedding;
  late bool _disableThinking;
  late bool _enableWebSearch;

  late bool _enableLightRag;

  late final TextEditingController _lightRagUrlCtrl;
  late bool _enableBargeIn;
  late bool _enableTtsPlayback;
  late double _ttsSpeed;
  late String _asrEngine;
  late bool _enablePromptTone;
  late String _ttsEngine;
  late String _edgeVoice;
  bool _isPreviewingVoice = false;
  bool _isTestingGemini = false;
  String? _geminiTestResult;

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
  bool _isLoadingModels = false;
  bool _isManualModelInput = false;

  // 视觉意图与摄像头配置状态
  late String _captureSource;
  late bool _enableFloatingCapsule;
  bool? _promotionAllowed;
  late String _nanoWlanInterface;
  late String _nanoSsid;
  late String _nanoPassword;
  late final TextEditingController _nanoBleAddressCtrl;
  List<String> _availableWlanInterfaces = [];
  bool _isTestingNano = false;
  String _nanoTestResult = '';

  late bool _enableVisionIntent;
  late double _visionSimilarityThreshold;
  late int _cameraKeepAliveMinutes;
  late String _cameraLensDirection;
  late int _cameraResolutionWidth;
  late int _cameraResolutionHeight;
  late int _cameraSendShortEdge;
  List<CameraResolution> _supportedCameraResolutions = [];
  bool _isLoadingCameraResolutions = false;
  late final TextEditingController _customVisionPrototypesCtrl;

  bool _isAndroid = false;
  bool? _cameraPermissionGranted;

  // 录音输入设备（仅 Android）
  List<AudioInputDeviceOption> _audioInputDevices = const [];
  String _audioInputDeviceId = '';
  String _audioInputDeviceLabel = '';
  bool _isLoadingAudioDevices = false;

  // 语义测试工具状态
  final TextEditingController _testPhraseCtrl = TextEditingController();
  String _testResultText = '';
  bool _isTestingEmbedding = false;

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
    _endWordCtrl = TextEditingController(text: settings.endWord);
    _resetWordCtrl = TextEditingController(text: settings.resetWord);
    _openAiBaseUrlCtrl = TextEditingController(text: settings.openAiBaseUrl);
    _openAiApiKeyCtrl = TextEditingController(text: settings.openAiApiKey);
    _openAiModelCtrl = TextEditingController(text: settings.openAiModel);
    _systemPromptCtrl = TextEditingController(text: settings.systemPrompt);
    _locationCtrl = TextEditingController(text: settings.locationAddress);
    _embeddingBaseUrlCtrl =
        TextEditingController(text: settings.embeddingBaseUrl);
    _embeddingApiKeyCtrl =
        TextEditingController(text: settings.embeddingApiKey);
    _embeddingModelCtrl = TextEditingController(text: settings.embeddingModel);
    _geminiApiKeyCtrl = TextEditingController(text: settings.geminiApiKey);
    _geminiAsrModelCtrl = TextEditingController(text: settings.geminiAsrModel);

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

    _similarityThreshold = settings.similarityThreshold;
    _silenceTimeoutSeconds = settings.silenceTimeoutSeconds;
    _useRemoteEmbedding = settings.useRemoteEmbedding;
    _disableThinking = settings.disableThinking;
    _enableWebSearch = settings.enableWebSearch;

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
    _visionSimilarityThreshold = settings.visionSimilarityThreshold;
    _cameraKeepAliveMinutes = settings.cameraKeepAliveMinutes;
    _cameraLensDirection = settings.cameraLensDirection;
    _cameraResolutionWidth = settings.cameraResolutionWidth;
    _cameraResolutionHeight = settings.cameraResolutionHeight;
    _cameraSendShortEdge = settings.cameraSendShortEdge;
    _customVisionPrototypesCtrl = TextEditingController(
      text: settings.customVisionPrototypes.join('\n'),
    );

    _captureSource = settings.captureSource;
    _enableFloatingCapsule = settings.enableFloatingCapsule;
    _isAndroid = Platform.isAndroid;
    _nanoWlanInterface = settings.nanoWlanInterface;
    _nanoSsid = settings.nanoSsid;
    _nanoPassword = settings.nanoPassword;
    _nanoBleAddressCtrl = TextEditingController(text: settings.nanoBleAddress);

    _autoSaveTextControllers = [
      _startWordCtrl,
      _endWordCtrl,
      _resetWordCtrl,
      _openAiBaseUrlCtrl,
      _openAiApiKeyCtrl,
      _openAiModelCtrl,
      _systemPromptCtrl,
      _locationCtrl,
      _lightRagUrlCtrl,
      _embeddingBaseUrlCtrl,
      _embeddingApiKeyCtrl,
      _embeddingModelCtrl,
      _geminiApiKeyCtrl,
      _geminiAsrModelCtrl,
      _customVisionPrototypesCtrl,
      _nanoBleAddressCtrl,
    ];
    for (final ctrl in _autoSaveTextControllers) {
      ctrl.addListener(_onTextControllerChanged);
    }
    _lastAutoSavedTexts =
        _autoSaveTextControllers.map((c) => c.text).toList();

    if (_isAndroid) {
      WidgetsBinding.instance.addObserver(this);
      _refreshCameraPermission();
      _refreshPromotionAllowed();
      _loadSupportedCameraResolutions();
      _loadAudioInputDevices();
    }

    NanoWifiDriver.getWlanInterfaces().then((list) {
      if (mounted) {
        setState(() => _availableWlanInterfaces = list);
      }
    });

    if (_openAiBaseUrlCtrl.text.trim().isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _fetchAvailableModels(silent: true);
        }
      });
    }
  }

  void _onTextControllerChanged() {
    // 软键盘弹出或输入框仅获得焦点/移动光标时，TextEditingController 也可能触发监听；
    // 只有文本内容实际发生变化时才触发自动保存与服务重建。
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
      _autoSaveTimer = Timer(const Duration(milliseconds: 400), () {
        unawaited(_saveSettings());
      });
    }
  }

  @override
  void dispose() {
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
    _endWordCtrl.dispose();
    _resetWordCtrl.dispose();
    _openAiBaseUrlCtrl.dispose();
    _openAiApiKeyCtrl.dispose();
    _openAiModelCtrl.dispose();
    _systemPromptCtrl.dispose();
    _locationCtrl.dispose();
    _lightRagUrlCtrl.dispose();
    _embeddingBaseUrlCtrl.dispose();
    _embeddingApiKeyCtrl.dispose();
    _embeddingModelCtrl.dispose();
    _geminiApiKeyCtrl.dispose();
    _geminiAsrModelCtrl.dispose();
    _testPhraseCtrl.dispose();
    _customVisionPrototypesCtrl.dispose();
    _nanoBleAddressCtrl.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _isAndroid) {
      _refreshCameraPermission();
      _refreshPromotionAllowed();
    }
  }

  Future<void> _refreshCameraPermission() async {
    if (!_isAndroid) return;
    final granted = await AndroidCameraBridge.hasPermission();
    if (mounted) {
      setState(() => _cameraPermissionGranted = granted);
    }
  }

  Future<void> _refreshPromotionAllowed() async {
    if (!_isAndroid) return;
    final allowed = await FloatingCapsuleService.canPostPromoted();
    if (mounted) {
      setState(() => _promotionAllowed = allowed);
    }
  }

  Future<void> _handleFloatingCapsuleToggle(bool value) async {
    setState(() => _enableFloatingCapsule = value);
    _scheduleAutoSave(immediate: true);
    if (value && _isAndroid) {
      await _refreshPromotionAllowed();
    }
  }

  Future<void> _loadSupportedCameraResolutions() async {
    if (!_isAndroid) return;
    if (mounted) {
      setState(() => _isLoadingCameraResolutions = true);
    }
    final list = await AndroidCameraBridge.getSupportedResolutions(
      lensDirection: _cameraLensDirection,
    );
    if (!mounted) return;
    setState(() {
      _supportedCameraResolutions = list;
      _isLoadingCameraResolutions = false;
      if (list.isNotEmpty &&
          _cameraResolutionWidth > 0 &&
          !list.any((r) =>
              r.width == _cameraResolutionWidth &&
              r.height == _cameraResolutionHeight)) {
        _cameraResolutionWidth = 0;
        _cameraResolutionHeight = 0;
      }
    });
  }

  Future<void> _handleGrantCameraPermission() async {
    final granted = await AndroidCameraBridge.requestPermission();
    if (!mounted) return;
    setState(() => _cameraPermissionGranted = granted);
    if (!granted) {
      await AndroidCameraBridge.openAppSettings();
    }
  }

  Future<void> _loadAudioInputDevices() async {
    setState(() => _isLoadingAudioDevices = true);
    final devices = await AudioInputDeviceService.listInputDevices();
    if (!mounted) return;
    setState(() {
      _audioInputDevices = devices;
      _isLoadingAudioDevices = false;
    });
  }

  Widget _buildAudioInputDeviceSection(ThemeData theme) {
    if (!_isAndroid) return const SizedBox.shrink();

    final savedId = _audioInputDeviceId.trim();
    final savedLabel = _audioInputDeviceLabel.trim();
    final savedMissing =
        savedId.isNotEmpty && !_audioInputDevices.any((d) => d.id == savedId);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 28),
        Row(
          children: [
            Icon(Icons.settings_voice,
                size: 18, color: theme.colorScheme.primary),
            const SizedBox(width: 6),
            Expanded(child: Text('录音设备', style: theme.textTheme.titleSmall)),
            if (_isLoadingAudioDevices)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              TextButton.icon(
                onPressed: _loadAudioInputDevices,
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('重新扫描'),
              ),
          ],
        ),
        const SizedBox(height: 4),
        _buildLabeledField(
          '录音输入源',
          DropdownButtonFormField<String>(
            value: _audioInputDeviceId,
            isExpanded: true,
            decoration: const InputDecoration(),
            items: [
              const DropdownMenuItem(
                value: AudioInputDeviceService.autoId,
                child: Text('自动（系统默认，推荐）'),
              ),
              ..._audioInputDevices.map(
                (d) => DropdownMenuItem(
                  value: d.id,
                  child: Text(
                    d.label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: d.isBluetooth ? theme.colorScheme.primary : null,
                    ),
                  ),
                ),
              ),
              if (savedMissing)
                DropdownMenuItem(
                  value: savedId,
                  child: Text(
                    savedLabel.isEmpty ? savedId : savedLabel,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (v) {
              if (v == null) return;
              setState(() {
                _audioInputDeviceId = v;
                if (v == AudioInputDeviceService.autoId) {
                  _audioInputDeviceLabel = '';
                } else {
                  final matches = _audioInputDevices.where((d) => d.id == v);
                  _audioInputDeviceLabel =
                      matches.isEmpty ? savedLabel : matches.first.label;
                }
              });
              _scheduleAutoSave(immediate: true);
            },
          ),
        ),
      ],
    );
  }

  AppSettings _buildCurrentSettings() {
    return AppSettings(
      startWord: _startWordCtrl.text.trim(),
      endWord: _endWordCtrl.text.trim(),
      resetWord: _resetWordCtrl.text.trim(),
      similarityThreshold: _similarityThreshold,
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
      enableLightRag: _enableLightRag,
      lightRagBaseUrl: _lightRagUrlCtrl.text.trim(),
      systemPrompt: _systemPromptCtrl.text.trim(),
      locationAddress: _locationCtrl.text.trim(),
      geminiApiKey: _geminiApiKeyCtrl.text.trim(),
      geminiAsrModel: _geminiAsrModelCtrl.text.trim(),
      useRemoteEmbedding: _useRemoteEmbedding,
      embeddingBaseUrl: _embeddingBaseUrlCtrl.text.trim(),
      embeddingApiKey: _embeddingApiKeyCtrl.text.trim(),
      embeddingModel: _embeddingModelCtrl.text.trim(),
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
      visionSimilarityThreshold: _visionSimilarityThreshold,
      cameraKeepAliveMinutes: _cameraKeepAliveMinutes,
      cameraLensDirection: _cameraLensDirection,
      cameraResolutionWidth: _cameraResolutionWidth,
      cameraResolutionHeight: _cameraResolutionHeight,
      cameraSendShortEdge: _cameraSendShortEdge,
      customVisionPrototypes: _customVisionPrototypesCtrl.text
          .split('\n')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList(),
      enableFloatingCapsule: _enableFloatingCapsule,
    );
  }

  Future<void> _saveSettings() async {
    _hasPendingSave = false;
    final newSettings = _buildCurrentSettings();
    await _controller.updateSettings(newSettings);
  }

  Future<void> _fetchAvailableModels({bool silent = false}) async {
    final baseUrl = _openAiBaseUrlCtrl.text.trim();
    final apiKey = _openAiApiKeyCtrl.text.trim();
    if (baseUrl.isEmpty) {
      if (!silent && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请先填写 API Base URL')),
        );
      }
      return;
    }

    setState(() {
      _isLoadingModels = true;
    });

    try {
      final models = await LlmService.fetchAvailableModels(
        baseUrl: baseUrl,
        apiKey: apiKey,
      );

      if (mounted) {
        setState(() {
          final current = _openAiModelCtrl.text.trim();
          final set = <String>{...models};
          if (current.isNotEmpty) {
            set.add(current);
          }
          _availableModels = set.toList()..sort();
          _isLoadingModels = false;
        });
        _scheduleAutoSave(immediate: true);

        if (!silent) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('成功获取到 ${models.length} 个可用模型')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingModels = false;
        });
        if (!silent) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('获取模型列表失败: $e')),
          );
        }
      }
    }
  }

  Future<void> _previewCurrentVoice() async {
    if (_isPreviewingVoice) return;
    setState(() => _isPreviewingVoice = true);
    try {
      final tts = _controller.ttsService;
      await tts.previewVoice(
        voice: _edgeVoice,
        text: '你好，我是晓漫，这是我的全新神经网络发音效果。',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('音色试听失败: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isPreviewingVoice = false);
      }
    }
  }

  Future<void> _runEmbeddingTest() async {
    final candidate = _testPhraseCtrl.text.trim();
    if (candidate.isEmpty) return;

    setState(() {
      _isTestingEmbedding = true;
      _testResultText = '正在计算相似度...';
    });

    try {
      final probeSettings = AppSettings(
        useRemoteEmbedding: _useRemoteEmbedding,
        embeddingBaseUrl: _embeddingBaseUrlCtrl.text.trim(),
        embeddingApiKey: _embeddingApiKeyCtrl.text.trim(),
        embeddingModel: _embeddingModelCtrl.text.trim(),
        openAiApiKey: _openAiApiKeyCtrl.text.trim(),
      );
      EmbeddingService service;
      if (_useRemoteEmbedding) {
        service = RemoteOpenAiEmbeddingService(settings: probeSettings);
      } else {
        service = LocalQwenEmbeddingService(settings: probeSettings);
      }

      final words = AppSettings.splitTriggerWords(_startWordCtrl.text);
      final startWord =
          words.isEmpty ? _startWordCtrl.text.trim() : words.first;
      final vecB = await service.getEmbedding(candidate);
      var bestWord = startWord;
      var bestSim = -1.0;
      for (final word in (words.isEmpty ? [startWord] : words)) {
        final vecA = await service.getEmbedding(word);
        final sim = VectorMath.cosineSimilarity(vecA, vecB);
        if (sim > bestSim) {
          bestSim = sim;
          bestWord = word;
        }
      }
      final sim = bestSim;

      final isPass = sim >= _similarityThreshold;
      setState(() {
        _testResultText =
            '与开始词「$bestWord」余弦相似度: ${(sim * 100).toStringAsFixed(2)}% '
            '(${isPass ? "✅ 判定命中唤醒" : "❌ 未达到阈值 ${(_similarityThreshold * 100).toInt()}%"})';
      });
    } catch (e) {
      setState(() {
        _testResultText = '计算失败: $e';
      });
    } finally {
      setState(() {
        _isTestingEmbedding = false;
      });
    }
  }

  Future<void> _testGeminiConnection() async {
    setState(() {
      _isTestingGemini = true;
      _geminiTestResult = '正在连接 Gemini...';
    });

    final result = await _controller.testGeminiAsrConnection(
      apiKey: _geminiApiKeyCtrl.text.trim(),
      model: _geminiAsrModelCtrl.text.trim(),
    );

    if (!mounted) return;
    setState(() {
      _isTestingGemini = false;
      _geminiTestResult = result;
    });
  }

  Widget _buildGeminiConfigSection(ThemeData theme) {
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: EdgeInsets.zero,
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      title: const Text('Gemini 3.5 Transcribe Live 配置（云端）'),
      children: [
        _buildLabeledField(
          'Gemini API Key',
          TextField(
            controller: _geminiApiKeyCtrl,
            obscureText: true,
            decoration: const InputDecoration(),
          ),
        ),
        const SizedBox(height: 12),
        _buildLabeledField(
          'Gemini 模型',
          TextField(
            controller: _geminiAsrModelCtrl,
            decoration: const InputDecoration(),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: _isTestingGemini ? null : _testGeminiConnection,
              icon: _isTestingGemini
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.wifi_tethering),
              label: Text(_isTestingGemini ? '测试中...' : '测试连接'),
            ),
          ],
        ),
        if (_geminiTestResult != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _geminiTestResult!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: _geminiTestResult!.startsWith('连接成功')
                    ? Colors.green
                    : theme.colorScheme.error,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildAsrAdvancedSection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('静音超时自动提交'),
          value: _autoSubmitOnTimeout,
          onChanged: (v) {
            setState(() => _autoSubmitOnTimeout = v);
            _scheduleAutoSave(immediate: true);
          },
        ),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('高级 VAD / 分段参数'),
          children: [
            _buildDoubleSlider(
              label: 'VAD 语音阈值',
              value: _vadThreshold,
              min: 0.20,
              max: 0.80,
              divisions: 12,
              format: (v) => v.toStringAsFixed(2),
              onChanged: (v) {
                setState(() => _vadThreshold = v);
                _scheduleAutoSave();
              },
            ),
            _buildDoubleSlider(
              label: '尾静音判定',
              value: _vadMinSilenceSeconds,
              min: 0.20,
              max: 1.20,
              divisions: 20,
              format: (v) => '${v.toStringAsFixed(2)} 秒',
              onChanged: (v) {
                setState(() => _vadMinSilenceSeconds = v);
                _scheduleAutoSave();
              },
            ),
            _buildDoubleSlider(
              label: '最短语音',
              value: _vadMinSpeechSeconds,
              min: 0.10,
              max: 0.60,
              divisions: 10,
              format: (v) => '${v.toStringAsFixed(2)} 秒',
              onChanged: (v) {
                setState(() => _vadMinSpeechSeconds = v);
                _scheduleAutoSave();
              },
            ),
            _buildDoubleSlider(
              label: '最长语音',
              value: _vadMaxSpeechSeconds,
              min: 10,
              max: 60,
              divisions: 10,
              format: (v) => '${v.toStringAsFixed(0)} 秒',
              onChanged: (v) {
                setState(() => _vadMaxSpeechSeconds = v);
                _scheduleAutoSave();
              },
            ),
            _buildDoubleSlider(
              label: '段前预卷',
              value: _preRollMs.toDouble(),
              min: 0,
              max: 500,
              divisions: 10,
              format: (v) => '${v.toStringAsFixed(0)} 毫秒',
              onChanged: (v) {
                setState(() => _preRollMs = v.round());
                _scheduleAutoSave();
              },
            ),
            _buildDoubleSlider(
              label: '段尾补静音',
              value: _postRollMs.toDouble(),
              min: 0,
              max: 500,
              divisions: 10,
              format: (v) => '${v.toStringAsFixed(0)} 毫秒',
              onChanged: (v) {
                setState(() => _postRollMs = v.round());
                _scheduleAutoSave();
              },
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildDoubleSlider({
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String Function(double) format,
    required ValueChanged<double> onChanged,
  }) {
    final safeValue = value.clamp(min, max).toDouble();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$label: ${format(safeValue)}'),
        Slider(
          value: safeValue,
          min: min,
          max: max,
          divisions: divisions,
          label: format(safeValue),
          onChanged: onChanged,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('助手设置'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildSectionHeader('语音识别引擎', Icons.graphic_eq),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildLabeledField(
                    '识别模型',
                    DropdownButtonFormField<String>(
                      value: _asrEngine,
                      isExpanded: true,
                      decoration: const InputDecoration(),
                      items: const [
                        DropdownMenuItem(
                          value: AppConstants.asrEngineSenseVoice,
                          child: Text('高精度离线 SenseVoice（内置，推荐）'),
                        ),
                        DropdownMenuItem(
                          value: AppConstants.asrEngineStreaming,
                          child: Text('低延迟流式 Zipformer（内置小模型）'),
                        ),
                        DropdownMenuItem(
                          value: AppConstants.asrEngineGeminiLive,
                          child: Text('Gemini 3.5 Transcribe Live（云端，需联网）'),
                        ),
                      ],
                      onChanged: (v) {
                        if (v != null) {
                          setState(() => _asrEngine = v);
                          _scheduleAutoSave(immediate: true);
                        }
                      },
                    ),
                  ),
                  _buildGeminiConfigSection(theme),
                  _buildAudioInputDeviceSection(theme),
                  _buildAsrAdvancedSection(theme),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          _buildSectionHeader('语音触发词与语义匹配', Icons.record_voice_over),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildLabeledField(
                    '开始词',
                    TextField(
                      controller: _startWordCtrl,
                      decoration: const InputDecoration(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _buildLabeledField(
                    '结束词',
                    TextField(
                      controller: _endWordCtrl,
                      decoration: const InputDecoration(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _buildLabeledField(
                    '新起会话词',
                    TextField(
                      controller: _resetWordCtrl,
                      decoration: const InputDecoration(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Text('语义匹配阈值: ${(_similarityThreshold * 100).toInt()}%'),
                      Expanded(
                        child: Slider(
                          value: _similarityThreshold,
                          min: 0.50,
                          max: 0.95,
                          divisions: 45,
                          label: '${(_similarityThreshold * 100).toInt()}%',
                          onChanged: (v) {
                            setState(() => _similarityThreshold = v);
                            _scheduleAutoSave();
                          },
                        ),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      Text('静音超时保护: $_silenceTimeoutSeconds 秒'),
                      Expanded(
                        child: Slider(
                          value: _silenceTimeoutSeconds.toDouble(),
                          min: 5,
                          max: 30,
                          divisions: 25,
                          label: '$_silenceTimeoutSeconds 秒',
                          onChanged: (v) {
                            setState(() => _silenceTimeoutSeconds = v.toInt());
                            _scheduleAutoSave();
                          },
                        ),
                      ),
                    ],
                  ),
                  const Divider(height: 24),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('触发词向量匹配实时测试', style: theme.textTheme.titleSmall),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _testPhraseCtrl,
                              decoration: const InputDecoration(
                                hintText: '输入测试词',
                                isDense: true,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton(
                            onPressed:
                                _isTestingEmbedding ? null : _runEmbeddingTest,
                            child: _isTestingEmbedding
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2))
                                : const Text('测试相似度'),
                          ),
                        ],
                      ),
                      if (_testResultText.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          _testResultText,
                          style: TextStyle(
                            fontSize: 13,
                            color: _testResultText.contains('✅')
                                ? Colors.green
                                : Colors.deepOrange,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          _buildSectionHeader('大语言模型（OpenAI 兼容）', Icons.psychology),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildLabeledField(
                    'API Base URL',
                    TextField(
                      controller: _openAiBaseUrlCtrl,
                      decoration: const InputDecoration(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _buildLabeledField(
                    'API Key',
                    TextField(
                      controller: _openAiApiKeyCtrl,
                      obscureText: true,
                      decoration: const InputDecoration(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (!_isManualModelInput) ...[
                    _buildLabeledField(
                      '模型名称（下拉选择）',
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            child: DropdownButtonFormField<String>(
                              value: _availableModels
                                      .contains(_openAiModelCtrl.text.trim())
                                  ? _openAiModelCtrl.text.trim()
                                  : (_availableModels.isNotEmpty
                                      ? _availableModels.first
                                      : null),
                              isExpanded: true,
                              decoration: const InputDecoration(),
                              items: [
                                ..._availableModels.map(
                                  (m) => DropdownMenuItem(
                                    value: m,
                                    child: Text(
                                      m,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                                const DropdownMenuItem(
                                  value: '__custom__',
                                  child: Row(
                                    children: [
                                      Icon(Icons.edit, size: 16),
                                      SizedBox(width: 8),
                                      Text('手动输入其它模型...'),
                                    ],
                                  ),
                                ),
                              ],
                              onChanged: (val) {
                                if (val == null) return;
                                if (val == '__custom__') {
                                  setState(() {
                                    _isManualModelInput = true;
                                  });
                                } else {
                                  setState(() {
                                    _openAiModelCtrl.text = val;
                                  });
                                  _scheduleAutoSave(immediate: true);
                                }
                              },
                            ),
                          ),
                          const SizedBox(width: 8),
                          IconButton.filledTonal(
                            icon: _isLoadingModels
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  )
                                : const Icon(Icons.refresh),
                            tooltip: '从 API 拉取/刷新可用模型列表',
                            onPressed: _isLoadingModels
                                ? null
                                : () => _fetchAvailableModels(silent: false),
                          ),
                          const SizedBox(width: 4),
                          IconButton.outlined(
                            icon: const Icon(Icons.edit_note),
                            tooltip: '切换为手动输入',
                            onPressed: () {
                              setState(() {
                                _isManualModelInput = true;
                              });
                            },
                          ),
                        ],
                      ),
                    ),
                  ] else ...[
                    _buildLabeledField(
                      '模型名称（手动输入）',
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _openAiModelCtrl,
                              decoration: InputDecoration(
                                suffixIcon: IconButton(
                                  icon: const Icon(
                                      Icons.arrow_drop_down_circle_outlined),
                                  tooltip: '切换回下拉选择',
                                  onPressed: () {
                                    final text = _openAiModelCtrl.text.trim();
                                    if (text.isNotEmpty &&
                                        !_availableModels.contains(text)) {
                                      _availableModels.insert(0, text);
                                    }
                                    setState(() {
                                      _isManualModelInput = false;
                                    });
                                  },
                                ),
                              ),
                              onChanged: (_) => setState(() {}),
                            ),
                          ),
                          const SizedBox(width: 8),
                          IconButton.filledTonal(
                            icon: _isLoadingModels
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  )
                                : const Icon(Icons.refresh),
                            tooltip: '从 API 拉取/刷新可用模型列表',
                            onPressed: _isLoadingModels
                                ? null
                                : () => _fetchAvailableModels(silent: false),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('关闭大模型深度思考'),
                    value: _disableThinking,
                    onChanged: (v) {
                      setState(() => _disableThinking = v);
                      _scheduleAutoSave(immediate: true);
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('启用联网搜索 (web_search)'),
                    value: _enableWebSearch,
                    onChanged: (v) {
                      setState(() => _enableWebSearch = v);
                      _scheduleAutoSave(immediate: true);
                    },
                  ),

                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('启用 LightRAG 个人知识库 (lightrag_query)'),
                    subtitle: const Text('向模型声明主人身份并开放查询工具；切换新会话时自动归档对话（含图片）'),
                    value: _enableLightRag,
                    onChanged: (v) {
                      setState(() => _enableLightRag = v);
                      _scheduleAutoSave(immediate: true);
                    },
                  ),

                  _buildLabeledField(
                    'LightRAG 服务地址',
                    TextField(
                      controller: _lightRagUrlCtrl,
                      decoration: const InputDecoration(
                        hintText: 'http://192.168.31.233:9621',
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _buildLabeledField(
                    '系统提示词',
                    TextField(
                      controller: _systemPromptCtrl,
                      maxLines: 4,
                      decoration: const InputDecoration(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _buildLabeledField(
                    '当前地理位置（Android 自动定位，失败时使用此地址）',
                    TextField(
                      controller: _locationCtrl,
                      decoration: const InputDecoration(),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          _buildSectionHeader('Embedding 语义向量服务', Icons.hub),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('使用远程 OpenAI 规范 Embedding API'),
                    value: _useRemoteEmbedding,
                    onChanged: (v) {
                      setState(() => _useRemoteEmbedding = v);
                      _scheduleAutoSave(immediate: true);
                    },
                  ),
                  if (_useRemoteEmbedding) ...[
                    const SizedBox(height: 12),
                    _buildLabeledField(
                      'Embedding Base URL',
                      TextField(
                        controller: _embeddingBaseUrlCtrl,
                        decoration: const InputDecoration(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    _buildLabeledField(
                      'Embedding API Key',
                      TextField(
                        controller: _embeddingApiKeyCtrl,
                        obscureText: true,
                        decoration: const InputDecoration(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    _buildLabeledField(
                      'Embedding 模型名',
                      TextField(
                        controller: _embeddingModelCtrl,
                        decoration: const InputDecoration(),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          _buildSectionHeader('语音合成与交互选项', Icons.volume_up),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('启用 TTS 自动播放'),
                    value: _enableTtsPlayback,
                    onChanged: (v) {
                      setState(() => _enableTtsPlayback = v);
                      _scheduleAutoSave(immediate: true);
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('支持语音打断（Barge-in）'),
                    value: _enableBargeIn,
                    onChanged: (v) {
                      setState(() => _enableBargeIn = v);
                      _scheduleAutoSave(immediate: true);
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('交互反馈提示音（轻滴声）'),
                    value: _enablePromptTone,
                    onChanged: (v) {
                      setState(() => _enablePromptTone = v);
                      _scheduleAutoSave(immediate: true);
                    },
                  ),
                  Row(
                    children: [
                      Text('朗读语速: ${_ttsSpeed.toStringAsFixed(1)}x'),
                      Expanded(
                        child: Slider(
                          value: _ttsSpeed,
                          min: 0.5,
                          max: 2.0,
                          divisions: 15,
                          label: '${_ttsSpeed.toStringAsFixed(1)}x',
                          onChanged: (v) {
                            setState(() => _ttsSpeed = v);
                            _scheduleAutoSave();
                          },
                        ),
                      ),
                    ],
                  ),
                  const Divider(height: 24),
                  _buildLabeledField(
                    'TTS 语音合成引擎',
                    DropdownButtonFormField<String>(
                      isExpanded: true,
                      value: _ttsEngine,
                      decoration: const InputDecoration(),
                      items: [
                        const DropdownMenuItem(
                          value: 'edge',
                          child: Text('微软 Edge Neural (超自然高品质 · 推荐)',
                              overflow: TextOverflow.ellipsis),
                        ),
                        DropdownMenuItem(
                          value: 'system',
                          child: Text(
                              Platform.isWindows
                                  ? 'Windows 系统原生 SAPI5 (离线发音)'
                                  : '系统原生 TTS 引擎 (Android TextToSpeech)',
                              overflow: TextOverflow.ellipsis),
                        ),
                      ],
                      onChanged: (v) {
                        if (v != null) {
                          setState(() => _ttsEngine = v);
                          _scheduleAutoSave(immediate: true);
                        }
                      },
                    ),
                  ),
                  if (_ttsEngine == 'edge') ...[
                    const SizedBox(height: 12),
                    _buildLabeledField(
                      '微软神经网络音色',
                      DropdownButtonFormField<String>(
                        isExpanded: true,
                        value: _edgeVoice,
                        decoration: const InputDecoration(),
                        items: const [
                          DropdownMenuItem(
                            value: 'zh-CN-XiaoxiaoNeural',
                            child: Text('晓晓 (温柔自然女声 · 推荐)',
                                overflow: TextOverflow.ellipsis),
                          ),
                          DropdownMenuItem(
                            value: 'zh-CN-YunxiNeural',
                            child: Text('云希 (阳光沉稳男声)',
                                overflow: TextOverflow.ellipsis),
                          ),
                          DropdownMenuItem(
                            value: 'zh-CN-XiaoyiNeural',
                            child: Text('小艺 (活泼亲切女声)',
                                overflow: TextOverflow.ellipsis),
                          ),
                          DropdownMenuItem(
                            value: 'zh-CN-YunjianNeural',
                            child: Text('云健 (影视解说/磁性男声)',
                                overflow: TextOverflow.ellipsis),
                          ),
                          DropdownMenuItem(
                            value: 'zh-CN-YunyangNeural',
                            child: Text('云扬 (专业新闻播音男声)',
                                overflow: TextOverflow.ellipsis),
                          ),
                        ],
                        onChanged: (v) {
                          if (v != null) {
                            setState(() => _edgeVoice = v);
                            _scheduleAutoSave(immediate: true);
                          }
                        },
                      ),
                    ),
                    const SizedBox(height: 10),
                    Align(
                      alignment: Alignment.centerRight,
                      child: OutlinedButton.icon(
                        icon: _isPreviewingVoice
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.play_circle_outline),
                        label: Text(_isPreviewingVoice ? '正在试听中...' : '试听当前音色'),
                        onPressed:
                            _isPreviewingVoice ? null : _previewCurrentVoice,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (_isAndroid) ...[
            const SizedBox(height: 24),
            _buildSectionHeader(
                '顶部悬浮胶囊（系统 Live Update）', Icons.bubble_chart_outlined),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('启用顶部悬浮胶囊'),
                      value: _enableFloatingCapsule,
                      onChanged: _handleFloatingCapsuleToggle,
                    ),
                    if (_enableFloatingCapsule &&
                        _promotionAllowed == false) ...[
                      const SizedBox(height: 4),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.open_in_new, size: 16),
                        label: const Text('去开启系统实时活动权限'),
                        onPressed: () async {
                          await FloatingCapsuleService.requestPromotion();
                          await _refreshPromotionAllowed();
                        },
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 24),
          _buildSectionHeader('视觉意图识别与摄像头', Icons.camera_alt_outlined),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('启用视觉意图自动识别'),
                    value: _enableVisionIntent,
                    onChanged: (v) {
                      setState(() => _enableVisionIntent = v);
                      _scheduleAutoSave(immediate: true);
                    },
                  ),
                  if (_enableVisionIntent) ...[
                    if (_isAndroid &&
                        _cameraPermissionGranted == false &&
                        _captureSource == AppConstants.captureSourceLocal) ...[
                      _buildCameraPermissionBanner(theme),
                    ],
                    const Divider(height: 24),
                    Row(
                      children: [
                        Text(
                            '视觉意图判定阈值: ${(_visionSimilarityThreshold * 100).toInt()}%'),
                        Expanded(
                          child: Slider(
                            value: _visionSimilarityThreshold,
                            min: 0.50,
                            max: 0.90,
                            divisions: 40,
                            label:
                                '${(_visionSimilarityThreshold * 100).toInt()}%',
                            onChanged: (v) {
                              setState(() => _visionSimilarityThreshold = v);
                              _scheduleAutoSave();
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _buildLabeledField(
                      '拍照源',
                      DropdownButtonFormField<String>(
                        isExpanded: true,
                        value: _captureSource,
                        decoration: const InputDecoration(),
                        items: const [
                          DropdownMenuItem(
                            value: AppConstants.captureSourceLocal,
                            child: Text('本地摄像头'),
                          ),
                          DropdownMenuItem(
                            value: AppConstants.captureSourceNano,
                            child: Text('DJI Osmo Nano'),
                          ),
                        ],
                        onChanged: (v) {
                          if (v != null) {
                            setState(() => _captureSource = v);
                            _scheduleAutoSave(immediate: true);
                          }
                        },
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (_captureSource == AppConstants.captureSourceLocal) ...[
                      _buildLabeledField(
                        '摄像头朝向',
                        DropdownButtonFormField<String>(
                          isExpanded: true,
                          value: _cameraLensDirection,
                          decoration: const InputDecoration(),
                          items: const [
                            DropdownMenuItem(
                              value: 'back',
                              child: Text('后置摄像头'),
                            ),
                            DropdownMenuItem(
                              value: 'front',
                              child: Text('前置摄像头'),
                            ),
                          ],
                          onChanged: (v) {
                            if (v == null || v == _cameraLensDirection) return;
                            setState(() {
                              _cameraLensDirection = v;
                              _cameraResolutionWidth = 0;
                              _cameraResolutionHeight = 0;
                              _supportedCameraResolutions = [];
                            });
                            _scheduleAutoSave(immediate: true);
                            _loadSupportedCameraResolutions();
                          },
                        ),
                      ),
                      if (_isAndroid) ...[
                        const SizedBox(height: 12),
                        _buildCameraResolutionSelector(),
                        const SizedBox(height: 12),
                        _buildSendCompressionSelector(),
                      ],
                    ] else ...[
                      _buildLabeledField(
                        'Nano 专用无线网卡',
                        DropdownButtonFormField<String>(
                          isExpanded: true,
                          value: _availableWlanInterfaces
                                      .contains(_nanoWlanInterface) ||
                                  _nanoWlanInterface == 'auto'
                              ? _nanoWlanInterface
                              : 'auto',
                          decoration: const InputDecoration(),
                          items: [
                            const DropdownMenuItem(
                              value: 'auto',
                              child: Text('自动选择'),
                            ),
                            ..._availableWlanInterfaces
                                .map((iface) => DropdownMenuItem(
                                      value: iface,
                                      child: Text(iface),
                                    )),
                          ],
                          onChanged: (v) {
                            if (v != null) {
                              setState(() => _nanoWlanInterface = v);
                              _scheduleAutoSave(immediate: true);
                            }
                          },
                        ),
                      ),
                      const SizedBox(height: 12),
                      _buildLabeledField(
                        'Nano 蓝牙 MAC 地址 (可选)',
                        TextField(
                          controller: _nanoBleAddressCtrl,
                          decoration: const InputDecoration(),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          OutlinedButton.icon(
                            icon: _isTestingNano
                                ? const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  )
                                : const Icon(Icons.wifi_tethering),
                            label:
                                Text(_isTestingNano ? '正在测试...' : '测试 Nano 连接'),
                            onPressed:
                                _isTestingNano ? null : _testNanoConnection,
                          ),
                          if (_nanoTestResult.isNotEmpty) ...[
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                _nanoTestResult,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: _nanoTestResult.startsWith('✅')
                                      ? Colors.green.shade800
                                      : (_nanoTestResult.startsWith('❌')
                                          ? Colors.red.shade800
                                          : Colors.blue.shade800),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Text(
                          _cameraKeepAliveMinutes == 0
                              ? '空闲关闭: 0 分钟'
                              : '空闲关闭: $_cameraKeepAliveMinutes 分钟',
                        ),
                        Expanded(
                          child: Slider(
                            value: _cameraKeepAliveMinutes
                                .toDouble()
                                .clamp(0.0, 10.0),
                            min: 0,
                            max: 10,
                            divisions: 10,
                            label: '$_cameraKeepAliveMinutes 分钟',
                            onChanged: (v) {
                              setState(() => _cameraKeepAliveMinutes = v.round());
                              _scheduleAutoSave();
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _buildLabeledField(
                      '自定义视觉意图触发短语 (每行一条)',
                      TextField(
                        controller: _customVisionPrototypesCtrl,
                        maxLines: 4,
                        decoration: const InputDecoration(),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  Future<void> _testNanoConnection() async {
    final settings = _controller.settings;
    setState(() {
      _isTestingNano = true;
      _nanoTestResult = '正在启动 Nano 链路检测...';
    });
    final bleDriver = NanoBleDriver();
    try {
      String addr = _nanoBleAddressCtrl.text.trim();
      if (addr.isEmpty) {
        setState(() => _nanoTestResult = '正在扫描附近的 DJI Osmo Nano...');
        final found =
            await bleDriver.scanForNano(timeout: const Duration(seconds: 6));
        if (found == null) {
          throw Exception('未扫描到目标 Nano 蓝牙设备，请确保相机已开机且在附近');
        }
        addr = found;
        _nanoBleAddressCtrl.text = addr;
      }

      setState(() => _nanoTestResult = '正在连接 Nano 蓝牙 ($addr)...');
      final connected = await bleDriver.connect(addr);
      if (!connected) {
        throw Exception('蓝牙 GATT 连接失败');
      }

      final battery = bleDriver.batteryPercent;
      setState(() => _nanoTestResult =
          '蓝牙连接成功 (电量: ${battery >= 0 ? '$battery%' : '就绪'})，正在尝试唤醒与协商凭据...');

      try {
        final (ssid, pwd) = await bleDriver.readWifiCredentials(
            timeout: const Duration(seconds: 8));
        if (ssid.isNotEmpty && pwd.isNotEmpty) {
          if (mounted) {
            setState(() {
              _nanoSsid = ssid;
              _nanoPassword = pwd;
            });
          }
          settings.nanoSsid = ssid;
          settings.nanoPassword = pwd;
          await settings.save();
        }
      } catch (e) {
        debugPrint('[SettingsScreen] 自动读取 Wi-Fi 凭证提示: $e');
      }

      if (_nanoSsid.isNotEmpty && _nanoPassword.isNotEmpty) {
        final targetIface =
            await NanoWifiDriver.resolveInterface(_nanoWlanInterface);
        setState(
            () => _nanoTestResult = '已自动获取 Wi-Fi 凭证 ($_nanoSsid)，正在测试连接与入网...');
        final ip = await NanoWifiDriver.connectSoftAp(
          iface: targetIface,
          ssid: _nanoSsid,
          password: _nanoPassword,
          timeout: const Duration(seconds: 15),
        );
        await NanoWifiDriver.disconnectSoftAp(targetIface);
        final currentBattery = bleDriver.batteryPercent;
        setState(() => _nanoTestResult =
            '✅ 测试通过！蓝牙与 Wi-Fi 链路畅通 (电量: ${currentBattery >= 0 ? '$currentBattery%' : '就绪'}, 自动获取热点: $_nanoSsid, 网卡: $targetIface, 分配 IP: $ip)');
      } else {
        setState(() => _nanoTestResult =
            '✅ 蓝牙测试通过 (电量: ${battery >= 0 ? '$battery%' : '就绪'})，未解锁 Wi-Fi 凭证，请确认相机亮屏并允许配对');
      }
    } catch (e) {
      setState(() => _nanoTestResult = '❌ 测试未通过: $e');
    } finally {
      await bleDriver.disconnect();
      if (mounted) {
        setState(() => _isTestingNano = false);
      }
    }
  }

  Widget _buildSectionHeader(String title, IconData icon) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Row(
        children: [
          Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          Text(title,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _buildCameraResolutionSelector() {
    final selectedKey = _cameraResolutionWidth > 0
        ? '${_cameraResolutionWidth}x$_cameraResolutionHeight'
        : 'auto';

    final items = <DropdownMenuItem<String>>[
      const DropdownMenuItem(
        value: 'auto',
        child: Text('自动（1600×1200 就近选档）'),
      ),
      ..._supportedCameraResolutions.map(
        (r) => DropdownMenuItem<String>(
          value: r.key,
          child: Text(r.label),
        ),
      ),
    ];

    if (!items.any((item) => item.value == selectedKey)) {
      items.add(
        DropdownMenuItem<String>(
          value: selectedKey,
          child:
              Text('$_cameraResolutionWidth × $_cameraResolutionHeight（当前配置）'),
        ),
      );
    }

    return _buildLabeledField(
      '拍照分辨率',
      DropdownButtonFormField<String>(
        value: selectedKey,
        isExpanded: true,
        decoration: InputDecoration(
          suffixIcon: _isLoadingCameraResolutions
              ? const Padding(
                  padding: EdgeInsets.all(14),
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : null,
        ),
        items: items,
        onChanged: _isLoadingCameraResolutions
            ? null
            : (v) {
                if (v == null) return;
                if (v == 'auto') {
                  setState(() {
                    _cameraResolutionWidth = 0;
                    _cameraResolutionHeight = 0;
                  });
                  _scheduleAutoSave(immediate: true);
                  return;
                }
                final res = CameraResolution.fromKey(v);
                if (res == null) return;
                setState(() {
                  _cameraResolutionWidth = res.width;
                  _cameraResolutionHeight = res.height;
                });
                _scheduleAutoSave(immediate: true);
              },
      ),
    );
  }

  Widget _buildSendCompressionSelector() {
    return _buildLabeledField(
      '发送前压缩',
      DropdownButtonFormField<int>(
        value: _cameraSendShortEdge,
        isExpanded: true,
        decoration: const InputDecoration(),
        items: const [
          DropdownMenuItem(
            value: 480,
            child: Text('480p'),
          ),
          DropdownMenuItem(
            value: 720,
            child: Text('720p'),
          ),
          DropdownMenuItem(
            value: 1080,
            child: Text('1080p'),
          ),
        ],
        onChanged: (v) {
          if (v != null) {
            setState(() => _cameraSendShortEdge = v);
            _scheduleAutoSave(immediate: true);
          }
        },
      ),
    );
  }

  /// 上方左对齐小字标题 + 下方输入框/选择框，保证与卡片内其它配置文字左边缘完全对齐。
  Widget _buildLabeledField(String label, Widget field) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 6),
        field,
      ],
    );
  }

  Widget _buildCameraPermissionBanner(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withOpacity(0.5),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.error.withOpacity(0.4)),
      ),
      child: Row(
        children: [
          Icon(Icons.no_photography_outlined,
              size: 20, color: theme.colorScheme.error),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '未授予相机权限',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 13,
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
          ),
          TextButton(
            onPressed: _handleGrantCameraPermission,
            child: const Text('开启权限'),
          ),
        ],
      ),
    );
  }
}

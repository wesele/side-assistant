import 'package:flutter/material.dart';
import '../../../../controllers/assistant_controller.dart';
import '../../../../core/constants/app_constants.dart';
import '../../../../core/models/device_options.dart';
import 'settings_shared.dart';

class PipelineModeSection extends StatefulWidget {
  final AssistantController controller;
  final String pipelineMode;
  final ValueChanged<String> onPipelineModeChanged;
  final TextEditingController geminiApiKeyCtrl;
  final TextEditingController geminiLiveModelCtrl;
  final String geminiLiveVoice;
  final ValueChanged<String> onGeminiLiveVoiceChanged;
  final bool isAndroid;
  final List<AudioInputDeviceOption> audioInputDevices;
  final String audioInputDeviceId;
  final String audioInputDeviceLabel;
  final bool isLoadingAudioDevices;
  final VoidCallback onRefreshAudioDevices;
  final void Function(String id, String label) onAudioInputDeviceChanged;
  final String geminiLiveAdvancedMode;
  final ValueChanged<String> onGeminiLiveAdvancedModeChanged;
  final String geminiLiveThinkingLevel;
  final ValueChanged<String> onGeminiLiveThinkingLevelChanged;
  final bool geminiLiveIncludeThoughts;
  final ValueChanged<bool> onGeminiLiveIncludeThoughtsChanged;
  final void Function({bool immediate}) onAutoSave;

  const PipelineModeSection({
    super.key,
    required this.controller,
    required this.pipelineMode,
    required this.onPipelineModeChanged,
    required this.geminiApiKeyCtrl,
    required this.geminiLiveModelCtrl,
    required this.geminiLiveVoice,
    required this.onGeminiLiveVoiceChanged,
    required this.geminiLiveAdvancedMode,
    required this.onGeminiLiveAdvancedModeChanged,
    required this.geminiLiveThinkingLevel,
    required this.onGeminiLiveThinkingLevelChanged,
    required this.geminiLiveIncludeThoughts,
    required this.onGeminiLiveIncludeThoughtsChanged,
    required this.isAndroid,
    required this.audioInputDevices,
    required this.audioInputDeviceId,
    required this.audioInputDeviceLabel,
    required this.isLoadingAudioDevices,
    required this.onRefreshAudioDevices,
    required this.onAudioInputDeviceChanged,
    required this.onAutoSave,
  });

  @override
  State<PipelineModeSection> createState() => _PipelineModeSectionState();
}

class _PipelineModeSectionState extends State<PipelineModeSection> {
  bool _isTestingLive = false;
  bool _isPreviewingLiveVoice = false;
  String? _liveTestResult;

  @override
  void initState() {
    super.initState();
    widget.geminiLiveModelCtrl.addListener(_onModelTextChanged);
  }

  @override
  void didUpdateWidget(PipelineModeSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.geminiLiveModelCtrl != widget.geminiLiveModelCtrl) {
      oldWidget.geminiLiveModelCtrl.removeListener(_onModelTextChanged);
      widget.geminiLiveModelCtrl.addListener(_onModelTextChanged);
    }
  }

  @override
  void dispose() {
    widget.geminiLiveModelCtrl.removeListener(_onModelTextChanged);
    super.dispose();
  }

  void _onModelTextChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  bool get _isGeminiLive =>
      widget.pipelineMode == AppConstants.pipelineModeGeminiLive;

  bool get _isEffectiveAdvanced {
    final mode = widget.geminiLiveAdvancedMode.trim().toLowerCase();
    if (mode == AppConstants.geminiLiveAdvancedModeAdvanced) return true;
    if (mode == AppConstants.geminiLiveAdvancedModeBasic) return false;
    return widget.geminiLiveModelCtrl.text
        .toLowerCase()
        .contains('extended-thinking');
  }

  Future<void> _previewGeminiLiveVoice(String activeVoice) async {
    widget.onAutoSave(immediate: true);
    setState(() {
      _isPreviewingLiveVoice = true;
    });

    try {
      await widget.controller.previewVoice(
        voice: activeVoice,
        text: '你好，我是晓漫，这是 Gemini Live $activeVoice 原生音色的试听效果。',
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('试听失败: $e'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
      setState(() {
        _liveTestResult = '试听失败: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isPreviewingLiveVoice = false;
        });
      }
    }
  }

  Future<void> _testGeminiLiveConnection() async {
    setState(() {
      _isTestingLive = true;
      _liveTestResult = '正在连接 Gemini 3.8 Live...';
    });

    final result = await widget.controller.testGeminiAsrConnection(
      apiKey: widget.geminiApiKeyCtrl.text.trim(),
      model: widget.geminiLiveModelCtrl.text.trim().isEmpty
          ? AppConstants.defaultGeminiLiveModel
          : widget.geminiLiveModelCtrl.text.trim(),
    );

    if (!mounted) return;
    setState(() {
      _isTestingLive = false;
      _liveTestResult = result;
    });
  }

  Widget _buildAndroidAudioDeviceSelector(ThemeData theme) {
    if (!widget.isAndroid) return const SizedBox.shrink();

    final savedId = widget.audioInputDeviceId.trim();
    final savedLabel = widget.audioInputDeviceLabel.trim();
    final savedMissing = savedId.isNotEmpty &&
        !widget.audioInputDevices.any((d) => d.id == savedId);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 24),
        Row(
          children: [
            Icon(Icons.settings_voice,
                size: 18, color: theme.colorScheme.primary),
            const SizedBox(width: 6),
            Expanded(child: Text('录音设备', style: theme.textTheme.titleSmall)),
            if (widget.isLoadingAudioDevices)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              TextButton.icon(
                onPressed: widget.onRefreshAudioDevices,
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('重新扫描'),
              ),
          ],
        ),
        const SizedBox(height: 4),
        buildLabeledField(
          '录音输入源',
          DropdownButtonFormField<String>(
            value: widget.audioInputDeviceId,
            isExpanded: true,
            decoration: const InputDecoration(),
            items: [
              const DropdownMenuItem(
                value: AudioInputDeviceOption.autoId,
                child: Text('自动（系统默认，推荐）'),
              ),
              ...widget.audioInputDevices.map(
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
              String newLabel = '';
              if (v != AudioInputDeviceOption.autoId) {
                final matches =
                    widget.audioInputDevices.where((d) => d.id == v);
                newLabel = matches.isEmpty ? savedLabel : matches.first.label;
              }
              widget.onAudioInputDeviceChanged(v, newLabel);
              widget.onAutoSave(immediate: true);
            },
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const voiceOptions = AppConstants.geminiLiveVoices;
    final activeVoice = voiceOptions.contains(widget.geminiLiveVoice)
        ? widget.geminiLiveVoice
        : AppConstants.defaultGeminiLiveVoice;

    const modeOptions = AppConstants.geminiLiveAdvancedModes;
    final activeMode = modeOptions.contains(widget.geminiLiveAdvancedMode)
        ? widget.geminiLiveAdvancedMode
        : AppConstants.defaultGeminiLiveAdvancedMode;

    const thinkingLevels = AppConstants.geminiLiveThinkingLevels;
    final activeThinkingLevel =
        thinkingLevels.contains(widget.geminiLiveThinkingLevel)
            ? widget.geminiLiveThinkingLevel
            : AppConstants.defaultGeminiLiveThinkingLevel;

    final isEffectiveAdvanced = _isEffectiveAdvanced;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        buildSectionHeader(context, '对话管线模式', Icons.auto_awesome),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                buildLabeledField(
                  '交互架构模式',
                  DropdownButtonFormField<String>(
                    value: _isGeminiLive
                        ? AppConstants.pipelineModeGeminiLive
                        : AppConstants.pipelineModeCascade,
                    isExpanded: true,
                    decoration: const InputDecoration(),
                    items: const [
                      DropdownMenuItem(
                        value: AppConstants.pipelineModeCascade,
                        child: Text('标准级联模式（独立 ASR + LLM + TTS）'),
                      ),
                      DropdownMenuItem(
                        value: AppConstants.pipelineModeGeminiLive,
                        child: Text('Gemini 3.8 Live 全双工模式（端到端语音大模型）'),
                      ),
                    ],
                    onChanged: (v) {
                      if (v != null) {
                        widget.onPipelineModeChanged(v);
                        widget.onAutoSave(immediate: true);
                      }
                    },
                  ),
                ),
                if (_isGeminiLive) ...[
                  const SizedBox(height: 12),
                  Text(
                    '开启麦克风后即建立原生 BidiGenerateContent 全双工会话：免唤醒词、随时自然打断、端到端 24kHz 超低延迟原生语音回复与实时双向字幕。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 12),
                  buildLabeledField(
                    'Gemini API Key',
                    TextField(
                      controller: widget.geminiApiKeyCtrl,
                      obscureText: true,
                      decoration: const InputDecoration(
                        hintText: 'AIza...',
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  buildLabeledField(
                    'Gemini Live 模型',
                    TextField(
                      controller: widget.geminiLiveModelCtrl,
                      decoration: InputDecoration(
                        hintText: AppConstants.defaultGeminiLiveModel,
                        suffixIcon: PopupMenuButton<String>(
                          icon: const Icon(Icons.arrow_drop_down),
                          tooltip: '选择预设模型',
                          onSelected: (model) {
                            widget.geminiLiveModelCtrl.text = model;
                            widget.onAutoSave(immediate: true);
                          },
                          itemBuilder: (context) =>
                              AppConstants.geminiLiveModels
                                  .map(
                                    (m) => PopupMenuItem<String>(
                                      value: m,
                                      child: Text(m),
                                    ),
                                  )
                                  .toList(),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  buildLabeledField(
                    'Gemini Live 原生音色 (Voice)',
                    DropdownButtonFormField<String>(
                      value: activeVoice,
                      isExpanded: true,
                      decoration: const InputDecoration(),
                      items: voiceOptions
                          .map(
                            (v) => DropdownMenuItem(
                              value: v,
                              child: Text(
                                AppConstants.geminiLiveVoiceLabels[v] ?? v,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (v) {
                        if (v != null) {
                          widget.onGeminiLiveVoiceChanged(v);
                          widget.onAutoSave(immediate: true);
                        }
                      },
                    ),
                  ),
                  const SizedBox(height: 12),
                  buildLabeledField(
                    'Gemini Live 模式',
                    DropdownButtonFormField<String>(
                      key: const Key('gemini_live_advanced_mode_dropdown'),
                      value: activeMode,
                      isExpanded: true,
                      decoration: const InputDecoration(),
                      items: const [
                        DropdownMenuItem(
                          value: AppConstants.geminiLiveAdvancedModeAuto,
                          child: Text('自动（按模型判断）'),
                        ),
                        DropdownMenuItem(
                          value: AppConstants.geminiLiveAdvancedModeAdvanced,
                          child: Text('高级（Extended Thinking）'),
                        ),
                        DropdownMenuItem(
                          value: AppConstants.geminiLiveAdvancedModeBasic,
                          child: Text('初级'),
                        ),
                      ],
                      onChanged: (v) {
                        if (v != null) {
                          widget.onGeminiLiveAdvancedModeChanged(v);
                          widget.onAutoSave(immediate: true);
                        }
                      },
                    ),
                  ),
                  const SizedBox(height: 12),
                  buildLabeledField(
                    '思考深度',
                    DropdownButtonFormField<String>(
                      key: const Key('gemini_live_thinking_level_dropdown'),
                      value: activeThinkingLevel,
                      isExpanded: true,
                      decoration: InputDecoration(
                        helperText: isEffectiveAdvanced ? null : '初级模式下不生效',
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: AppConstants.geminiLiveThinkingLevelLow,
                          child: Text('低'),
                        ),
                        DropdownMenuItem(
                          value: AppConstants.geminiLiveThinkingLevelMedium,
                          child: Text('中'),
                        ),
                        DropdownMenuItem(
                          value: AppConstants.geminiLiveThinkingLevelHigh,
                          child: Text('高'),
                        ),
                      ],
                      onChanged: isEffectiveAdvanced
                          ? (v) {
                              if (v != null) {
                                widget.onGeminiLiveThinkingLevelChanged(v);
                                widget.onAutoSave(immediate: true);
                              }
                            }
                          : null,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    key: const Key('gemini_live_include_thoughts_switch'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('显示思考摘要'),
                    subtitle:
                        isEffectiveAdvanced ? null : const Text('初级模式下不生效'),
                    value: widget.geminiLiveIncludeThoughts,
                    onChanged: isEffectiveAdvanced
                        ? (v) {
                            widget.onGeminiLiveIncludeThoughtsChanged(v);
                            widget.onAutoSave(immediate: true);
                          }
                        : null,
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed:
                            _isTestingLive ? null : _testGeminiLiveConnection,
                        icon: _isTestingLive
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.wifi_tethering),
                        label: Text(
                          _isTestingLive ? '测试中...' : '测试 Gemini 3.8 Live 连通性',
                        ),
                      ),
                      OutlinedButton.icon(
                        onPressed: _isPreviewingLiveVoice
                            ? null
                            : () => _previewGeminiLiveVoice(activeVoice),
                        icon: _isPreviewingLiveVoice
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.volume_up),
                        label: Text(
                          _isPreviewingLiveVoice ? '正在试听中...' : '试听当前音色',
                        ),
                      ),
                    ],
                  ),
                  if (_liveTestResult != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        _liveTestResult!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: _liveTestResult!.startsWith('连接成功')
                              ? Colors.green
                              : theme.colorScheme.error,
                        ),
                      ),
                    ),
                  _buildAndroidAudioDeviceSelector(theme),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

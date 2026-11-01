import 'package:flutter/material.dart';
import '../../../../controllers/assistant_controller.dart';
import '../../../../core/constants/app_constants.dart';
import '../../../../core/models/device_options.dart';
import 'settings_shared.dart';

class AsrSettingsSection extends StatefulWidget {
  final AssistantController controller;
  final String asrEngine;
  final ValueChanged<String> onAsrEngineChanged;

  final TextEditingController geminiApiKeyCtrl;
  final TextEditingController geminiAsrModelCtrl;

  final bool isAndroid;
  final List<AudioInputDeviceOption> audioInputDevices;
  final String audioInputDeviceId;
  final String audioInputDeviceLabel;
  final bool isLoadingAudioDevices;
  final VoidCallback onRefreshAudioDevices;
  final void Function(String id, String label) onAudioInputDeviceChanged;

  final bool autoSubmitOnTimeout;
  final ValueChanged<bool> onAutoSubmitOnTimeoutChanged;

  final double vadThreshold;
  final ValueChanged<double> onVadThresholdChanged;
  final double vadMinSilenceSeconds;
  final ValueChanged<double> onVadMinSilenceChanged;
  final double vadMinSpeechSeconds;
  final ValueChanged<double> onVadMinSpeechChanged;
  final double vadMaxSpeechSeconds;
  final ValueChanged<double> onVadMaxSpeechChanged;
  final int preRollMs;
  final ValueChanged<int> onPreRollMsChanged;
  final int postRollMs;
  final ValueChanged<int> onPostRollMsChanged;

  final void Function({bool immediate}) onAutoSave;

  const AsrSettingsSection({
    super.key,
    required this.controller,
    required this.asrEngine,
    required this.onAsrEngineChanged,
    required this.geminiApiKeyCtrl,
    required this.geminiAsrModelCtrl,
    required this.isAndroid,
    required this.audioInputDevices,
    required this.audioInputDeviceId,
    required this.audioInputDeviceLabel,
    required this.isLoadingAudioDevices,
    required this.onRefreshAudioDevices,
    required this.onAudioInputDeviceChanged,
    required this.autoSubmitOnTimeout,
    required this.onAutoSubmitOnTimeoutChanged,
    required this.vadThreshold,
    required this.onVadThresholdChanged,
    required this.vadMinSilenceSeconds,
    required this.onVadMinSilenceChanged,
    required this.vadMinSpeechSeconds,
    required this.onVadMinSpeechChanged,
    required this.vadMaxSpeechSeconds,
    required this.onVadMaxSpeechChanged,
    required this.preRollMs,
    required this.onPreRollMsChanged,
    required this.postRollMs,
    required this.onPostRollMsChanged,
    required this.onAutoSave,
  });

  @override
  State<AsrSettingsSection> createState() => _AsrSettingsSectionState();
}

class _AsrSettingsSectionState extends State<AsrSettingsSection> {
  bool _isTestingGemini = false;
  String? _geminiTestResult;

  Future<void> _testGeminiConnection() async {
    setState(() {
      _isTestingGemini = true;
      _geminiTestResult = '正在连接 Gemini...';
    });

    final result = await widget.controller.testGeminiAsrConnection(
      apiKey: widget.geminiApiKeyCtrl.text.trim(),
      model: widget.geminiAsrModelCtrl.text.trim(),
    );

    if (!mounted) return;
    setState(() {
      _isTestingGemini = false;
      _geminiTestResult = result;
    });
  }

  Widget _buildDoubleSliderItem({
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

  Widget _buildGeminiConfigSection(ThemeData theme) {
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: EdgeInsets.zero,
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      title: const Text('Gemini 3.5 Transcribe Live 配置（云端）'),
      children: [
        buildLabeledField(
          'Gemini API Key',
          TextField(
            controller: widget.geminiApiKeyCtrl,
            obscureText: true,
            decoration: const InputDecoration(),
          ),
        ),
        const SizedBox(height: 12),
        buildLabeledField(
          'Gemini 模型',
          TextField(
            controller: widget.geminiAsrModelCtrl,
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

  Widget _buildAudioInputDeviceSection(ThemeData theme) {
    if (!widget.isAndroid) return const SizedBox.shrink();

    final savedId = widget.audioInputDeviceId.trim();
    final savedLabel = widget.audioInputDeviceLabel.trim();
    final savedMissing = savedId.isNotEmpty &&
        !widget.audioInputDevices.any((d) => d.id == savedId);

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
                final matches = widget.audioInputDevices.where((d) => d.id == v);
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

  Widget _buildAsrAdvancedSection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('静音超时自动提交'),
          value: widget.autoSubmitOnTimeout,
          onChanged: (v) {
            widget.onAutoSubmitOnTimeoutChanged(v);
            widget.onAutoSave(immediate: true);
          },
        ),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('高级 VAD / 分段参数'),
          children: [
            _buildDoubleSliderItem(
              label: 'VAD 语音阈值',
              value: widget.vadThreshold,
              min: 0.20,
              max: 0.80,
              divisions: 12,
              format: (v) => v.toStringAsFixed(2),
              onChanged: (v) {
                widget.onVadThresholdChanged(v);
                widget.onAutoSave();
              },
            ),
            _buildDoubleSliderItem(
              label: '尾静音判定',
              value: widget.vadMinSilenceSeconds,
              min: 0.20,
              max: 1.20,
              divisions: 20,
              format: (v) => '${v.toStringAsFixed(2)} 秒',
              onChanged: (v) {
                widget.onVadMinSilenceChanged(v);
                widget.onAutoSave();
              },
            ),
            _buildDoubleSliderItem(
              label: '最短语音',
              value: widget.vadMinSpeechSeconds,
              min: 0.10,
              max: 0.60,
              divisions: 10,
              format: (v) => '${v.toStringAsFixed(2)} 秒',
              onChanged: (v) {
                widget.onVadMinSpeechChanged(v);
                widget.onAutoSave();
              },
            ),
            _buildDoubleSliderItem(
              label: '最长语音',
              value: widget.vadMaxSpeechSeconds,
              min: 10,
              max: 60,
              divisions: 10,
              format: (v) => '${v.toStringAsFixed(0)} 秒',
              onChanged: (v) {
                widget.onVadMaxSpeechChanged(v);
                widget.onAutoSave();
              },
            ),
            _buildDoubleSliderItem(
              label: '段前预卷',
              value: widget.preRollMs.toDouble(),
              min: 0,
              max: 500,
              divisions: 10,
              format: (v) => '${v.toStringAsFixed(0)} 毫秒',
              onChanged: (v) {
                widget.onPreRollMsChanged(v.round());
                widget.onAutoSave();
              },
            ),
            _buildDoubleSliderItem(
              label: '段尾补静音',
              value: widget.postRollMs.toDouble(),
              min: 0,
              max: 500,
              divisions: 10,
              format: (v) => '${v.toStringAsFixed(0)} 毫秒',
              onChanged: (v) {
                widget.onPostRollMsChanged(v.round());
                widget.onAutoSave();
              },
            ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        buildSectionHeader(context, '语音识别引擎', Icons.graphic_eq),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                buildLabeledField(
                  '识别模型',
                  DropdownButtonFormField<String>(
                    value: widget.asrEngine,
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
                        widget.onAsrEngineChanged(v);
                        widget.onAutoSave(immediate: true);
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
      ],
    );
  }
}

import 'dart:io';
import 'package:flutter/material.dart';
import '../../../../controllers/assistant_controller.dart';
import '../../../../core/platform/floating_capsule_bridge.dart';
import 'settings_shared.dart';

class TtsSettingsSection extends StatefulWidget {
  final AssistantController controller;
  final bool enableTtsPlayback;
  final ValueChanged<bool> onEnableTtsPlaybackChanged;
  final bool enableBargeIn;
  final ValueChanged<bool> onEnableBargeInChanged;
  final bool enablePromptTone;
  final ValueChanged<bool> onEnablePromptToneChanged;
  final double ttsSpeed;
  final ValueChanged<double> onTtsSpeedChanged;
  final String ttsEngine;
  final ValueChanged<String> onTtsEngineChanged;
  final String edgeVoice;
  final ValueChanged<String> onEdgeVoiceChanged;

  final bool isAndroid;
  final bool enableFloatingCapsule;
  final ValueChanged<bool> onEnableFloatingCapsuleChanged;

  final void Function({bool immediate}) onAutoSave;

  const TtsSettingsSection({
    super.key,
    required this.controller,
    required this.enableTtsPlayback,
    required this.onEnableTtsPlaybackChanged,
    required this.enableBargeIn,
    required this.onEnableBargeInChanged,
    required this.enablePromptTone,
    required this.onEnablePromptToneChanged,
    required this.ttsSpeed,
    required this.onTtsSpeedChanged,
    required this.ttsEngine,
    required this.onTtsEngineChanged,
    required this.edgeVoice,
    required this.onEdgeVoiceChanged,
    required this.isAndroid,
    required this.enableFloatingCapsule,
    required this.onEnableFloatingCapsuleChanged,
    required this.onAutoSave,
  });

  @override
  State<TtsSettingsSection> createState() => _TtsSettingsSectionState();
}

class _TtsSettingsSectionState extends State<TtsSettingsSection> {
  bool _isPreviewingVoice = false;
  bool? _promotionAllowed;

  @override
  void initState() {
    super.initState();
    if (widget.isAndroid && widget.enableFloatingCapsule) {
      _refreshPromotionAllowed();
    }
  }

  Future<void> _refreshPromotionAllowed() async {
    if (!widget.isAndroid) return;
    final allowed = await FloatingCapsuleService.canPostPromoted();
    if (mounted) {
      setState(() => _promotionAllowed = allowed);
    }
  }

  Future<void> _handleFloatingCapsuleToggle(bool value) async {
    widget.onEnableFloatingCapsuleChanged(value);
    widget.onAutoSave(immediate: true);
    if (value && widget.isAndroid) {
      await _refreshPromotionAllowed();
    }
  }

  Future<void> _previewCurrentVoice() async {
    if (_isPreviewingVoice) return;
    setState(() => _isPreviewingVoice = true);
    try {
      final tts = widget.controller.ttsService;
      await tts.previewVoice(
        voice: widget.edgeVoice,
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

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        buildSectionHeader(context, '语音合成与交互选项', Icons.volume_up),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('启用 TTS 自动播放'),
                  value: widget.enableTtsPlayback,
                  onChanged: (v) {
                    widget.onEnableTtsPlaybackChanged(v);
                    widget.onAutoSave(immediate: true);
                  },
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('支持语音打断（Barge-in）'),
                  value: widget.enableBargeIn,
                  onChanged: (v) {
                    widget.onEnableBargeInChanged(v);
                    widget.onAutoSave(immediate: true);
                  },
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('交互反馈提示音（轻滴声）'),
                  value: widget.enablePromptTone,
                  onChanged: (v) {
                    widget.onEnablePromptToneChanged(v);
                    widget.onAutoSave(immediate: true);
                  },
                ),
                Row(
                  children: [
                    Text('朗读语速: ${widget.ttsSpeed.toStringAsFixed(1)}x'),
                    Expanded(
                      child: Slider(
                        value: widget.ttsSpeed,
                        min: 0.5,
                        max: 2.0,
                        divisions: 15,
                        label: '${widget.ttsSpeed.toStringAsFixed(1)}x',
                        onChanged: (v) {
                          widget.onTtsSpeedChanged(v);
                          widget.onAutoSave();
                        },
                      ),
                    ),
                  ],
                ),
                const Divider(height: 24),
                buildLabeledField(
                  'TTS 语音合成引擎',
                  DropdownButtonFormField<String>(
                    isExpanded: true,
                    value: widget.ttsEngine,
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
                        widget.onTtsEngineChanged(v);
                        widget.onAutoSave(immediate: true);
                      }
                    },
                  ),
                ),
                if (widget.ttsEngine == 'edge') ...[
                  const SizedBox(height: 12),
                  buildLabeledField(
                    '微软神经网络音色',
                    DropdownButtonFormField<String>(
                      isExpanded: true,
                      value: widget.edgeVoice,
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
                          widget.onEdgeVoiceChanged(v);
                          widget.onAutoSave(immediate: true);
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
                              child: CircularProgressIndicator(strokeWidth: 2),
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
        if (widget.isAndroid) ...[
          const SizedBox(height: 24),
          buildSectionHeader(
              context, '顶部悬浮胶囊（系统 Live Update）', Icons.bubble_chart_outlined),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('启用顶部悬浮胶囊'),
                    value: widget.enableFloatingCapsule,
                    onChanged: _handleFloatingCapsuleToggle,
                  ),
                  if (widget.enableFloatingCapsule &&
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
      ],
    );
  }
}

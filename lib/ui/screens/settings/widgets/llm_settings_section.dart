import 'package:flutter/material.dart';
import '../../../../controllers/assistant_controller.dart';
import 'settings_shared.dart';

class LlmSettingsSection extends StatefulWidget {
  final AssistantController? controller;
  final TextEditingController openAiBaseUrlCtrl;
  final TextEditingController openAiApiKeyCtrl;
  final TextEditingController openAiModelCtrl;
  final List<String> availableModels;
  final ValueChanged<List<String>> onAvailableModelsChanged;

  final bool disableThinking;
  final ValueChanged<bool> onDisableThinkingChanged;
  final bool enableWebSearch;
  final ValueChanged<bool> onEnableWebSearchChanged;
  final bool enableLightRag;
  final ValueChanged<bool> onEnableLightRagChanged;

  final TextEditingController lightRagUrlCtrl;
  final TextEditingController systemPromptCtrl;
  final TextEditingController locationCtrl;
  final bool isGeminiLiveMode;

  final void Function({bool immediate}) onAutoSave;

  const LlmSettingsSection({
    super.key,
    this.controller,
    required this.openAiBaseUrlCtrl,
    required this.openAiApiKeyCtrl,
    required this.openAiModelCtrl,
    required this.availableModels,
    required this.onAvailableModelsChanged,
    required this.disableThinking,
    required this.onDisableThinkingChanged,
    required this.enableWebSearch,
    required this.onEnableWebSearchChanged,
    required this.enableLightRag,
    required this.onEnableLightRagChanged,
    required this.lightRagUrlCtrl,
    required this.systemPromptCtrl,
    required this.locationCtrl,
    this.isGeminiLiveMode = false,
    required this.onAutoSave,
  });

  @override
  State<LlmSettingsSection> createState() => _LlmSettingsSectionState();
}

class _LlmSettingsSectionState extends State<LlmSettingsSection> {
  bool _isLoadingModels = false;
  bool _isManualModelInput = false;

  Future<void> _fetchAvailableModels({bool silent = false}) async {
    final baseUrl = widget.openAiBaseUrlCtrl.text.trim();
    final apiKey = widget.openAiApiKeyCtrl.text.trim();
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
      final models = widget.controller != null
          ? await widget.controller!.fetchAvailableModels(
              baseUrl: baseUrl,
              apiKey: apiKey,
            )
          : <String>[];
      if (mounted) {
        if (models.isNotEmpty) {
          final updated = List<String>.from(models);
          widget.onAvailableModelsChanged(updated);
          final current = widget.openAiModelCtrl.text.trim();
          if (!updated.contains(current)) {
            widget.openAiModelCtrl.text = updated.first;
            widget.onAutoSave(immediate: true);
          }
          if (!silent) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('已获取 ${models.length} 个可用模型')),
            );
          }
        } else if (!silent) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('获取模型列表为空，请检查接口是否支持 /v1/models')),
          );
        }
      }
    } catch (e) {
      if (!silent && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('获取模型列表失败: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingModels = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final models = widget.availableModels;
    final currentModel = widget.openAiModelCtrl.text.trim();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        buildSectionHeader(
          context,
          widget.isGeminiLiveMode
              ? '对话工具与系统人设（Gemini Live 生效）'
              : '大语言模型（OpenAI 兼容）',
          Icons.psychology,
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!widget.isGeminiLiveMode) ...[
                  buildLabeledField(
                    'API Base URL',
                    TextField(
                      controller: widget.openAiBaseUrlCtrl,
                      decoration: const InputDecoration(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  buildLabeledField(
                    'API Key',
                    TextField(
                      controller: widget.openAiApiKeyCtrl,
                      obscureText: true,
                      decoration: const InputDecoration(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (!_isManualModelInput) ...[
                    buildLabeledField(
                      '模型名称（下拉选择）',
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            child: DropdownButtonFormField<String>(
                              value: models.contains(currentModel)
                                  ? currentModel
                                  : (models.isNotEmpty ? models.first : null),
                              isExpanded: true,
                              decoration: const InputDecoration(),
                              items: [
                                ...models.map(
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
                                    widget.openAiModelCtrl.text = val;
                                  });
                                  widget.onAutoSave(immediate: true);
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
                    buildLabeledField(
                      '模型名称（手动输入）',
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            child: TextField(
                              controller: widget.openAiModelCtrl,
                              decoration: InputDecoration(
                                suffixIcon: IconButton(
                                  icon: const Icon(
                                      Icons.arrow_drop_down_circle_outlined),
                                  tooltip: '切换回下拉选择',
                                  onPressed: () {
                                    final text =
                                        widget.openAiModelCtrl.text.trim();
                                    if (text.isNotEmpty &&
                                        !models.contains(text)) {
                                      final updated = List<String>.from(models)
                                        ..insert(0, text);
                                      widget.onAvailableModelsChanged(updated);
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
                    value: widget.disableThinking,
                    onChanged: (v) {
                      widget.onDisableThinkingChanged(v);
                      widget.onAutoSave(immediate: true);
                    },
                  ),
                ],
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('启用联网搜索 (web_search)'),
                  value: widget.enableWebSearch,
                  onChanged: (v) {
                    widget.onEnableWebSearchChanged(v);
                    widget.onAutoSave(immediate: true);
                  },
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('启用 LightRAG 个人知识库 (lightrag_query)'),
                  subtitle: const Text('向模型声明主人身份并开放查询工具；切换新会话时自动归档对话（含图片）'),
                  value: widget.enableLightRag,
                  onChanged: (v) {
                    widget.onEnableLightRagChanged(v);
                    widget.onAutoSave(immediate: true);
                  },
                ),
                buildLabeledField(
                  'LightRAG 服务地址',
                  TextField(
                    controller: widget.lightRagUrlCtrl,
                    decoration: const InputDecoration(
                      hintText: 'http://192.168.31.233:9621',
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                buildLabeledField(
                  '系统提示词',
                  TextField(
                    controller: widget.systemPromptCtrl,
                    maxLines: 4,
                    decoration: const InputDecoration(),
                  ),
                ),
                const SizedBox(height: 12),
                buildLabeledField(
                  '当前地理位置（Android 自动定位，失败时使用此地址）',
                  TextField(
                    controller: widget.locationCtrl,
                    decoration: const InputDecoration(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

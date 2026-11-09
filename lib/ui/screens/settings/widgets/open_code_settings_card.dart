import 'package:flutter/material.dart';

import '../../../../controllers/assistant_controller.dart';
import '../../../../core/constants/app_constants.dart';
import '../../../../core/models/custom_tool_manifest.dart';
import 'settings_shared.dart';

/// OpenCode / Hermes 与持久化工具配置卡片
class OpenCodeSettingsCard extends StatefulWidget {
  final AssistantController? controller;
  final bool enableOpenCode;
  final ValueChanged<bool> onEnableOpenCodeChanged;
  final String codeAgentProvider;
  final ValueChanged<String>? onCodeAgentProviderChanged;
  final TextEditingController openCodeCommandCtrl;
  final TextEditingController? hermesCommandCtrl;
  final int openCodeTimeoutSeconds;
  final int openCodeProgressIntervalSeconds;
  final ValueChanged<int> onOpenCodeProgressIntervalSecondsChanged;
  final ValueChanged<int> onOpenCodeTimeoutSecondsChanged;
  final void Function({bool immediate}) onAutoSave;
  final List<CustomToolManifest> Function()? onListTools;
  final bool Function(String name)? onDeleteTool;

  const OpenCodeSettingsCard({
    super.key,
    this.controller,
    required this.enableOpenCode,
    required this.onEnableOpenCodeChanged,
    this.codeAgentProvider = AppConstants.defaultCodeAgentProvider,
    this.onCodeAgentProviderChanged,
    required this.openCodeCommandCtrl,
    this.hermesCommandCtrl,
    required this.openCodeTimeoutSeconds,
    required this.openCodeProgressIntervalSeconds,
    required this.onOpenCodeProgressIntervalSecondsChanged,
    required this.onOpenCodeTimeoutSecondsChanged,
    required this.onAutoSave,
    this.onListTools,
    this.onDeleteTool,
  });

  @override
  State<OpenCodeSettingsCard> createState() => _OpenCodeSettingsCardState();
}

class _OpenCodeSettingsCardState extends State<OpenCodeSettingsCard> {
  late List<CustomToolManifest> _tools;

  @override
  void initState() {
    super.initState();
    _loadTools();
  }

  void _loadTools() {
    if (widget.onListTools != null) {
      _tools = widget.onListTools!();
    } else if (widget.controller != null) {
      _tools = widget.controller!.listCustomTools();
    } else {
      _tools = const [];
    }
  }

  Future<void> _confirmAndDeleteTool(CustomToolManifest tool) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除自定义工具'),
        content: Text('确定要删除持久化工具 "${tool.name}" 及其脚本文件吗？此操作无法撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      final bool deleted;
      if (widget.onDeleteTool != null) {
        deleted = widget.onDeleteTool!(tool.name);
      } else if (widget.controller != null) {
        deleted = widget.controller!.deleteCustomTool(tool.name);
      } else {
        deleted = false;
      }
      setState(() {
        _loadTools();
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              deleted ? '已成功删除工具 "${tool.name}"' : '删除工具 "${tool.name}" 失败',
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        buildSectionHeader(
          context,
          'OpenCode / Hermes 与持久化工具',
          Icons.terminal,
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                      '启用外部 Agent (OpenCode / Hermes) 代码生成与受限 CLI 工具'),
                  subtitle: const Text('允许大模型通过受限命令行生成、调试并安装可重用的持久化自定义工具'),
                  value: widget.enableOpenCode,
                  onChanged: (v) {
                    widget.onEnableOpenCodeChanged(v);
                    widget.onAutoSave(immediate: true);
                  },
                ),
                if (widget.enableOpenCode) ...[
                  const SizedBox(height: 12),
                  buildLabeledField(
                    '代码 Agent 提供方',
                    DropdownButtonFormField<String>(
                      value: widget.codeAgentProvider ==
                              AppConstants.codeAgentProviderHermes
                          ? AppConstants.codeAgentProviderHermes
                          : AppConstants.codeAgentProviderOpenCode,
                      isExpanded: true,
                      decoration: const InputDecoration(),
                      items: const [
                        DropdownMenuItem(
                          value: AppConstants.codeAgentProviderOpenCode,
                          child: Text('OpenCode'),
                        ),
                        DropdownMenuItem(
                          value: AppConstants.codeAgentProviderHermes,
                          child: Text('Hermes'),
                        ),
                      ],
                      onChanged: (newVal) {
                        if (newVal != null) {
                          widget.onCodeAgentProviderChanged?.call(newVal);
                          widget.onAutoSave(immediate: true);
                        }
                      },
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (widget.codeAgentProvider ==
                          AppConstants.codeAgentProviderHermes &&
                      widget.hermesCommandCtrl != null)
                    buildLabeledField(
                      'Hermes 命令或可执行文件路径',
                      TextField(
                        controller: widget.hermesCommandCtrl!,
                        decoration: const InputDecoration(
                          hintText:
                              'hermes (默认执行 hermes chat -Q --query-file -)',
                        ),
                        onChanged: (_) => widget.onAutoSave(),
                      ),
                    )
                  else
                    buildLabeledField(
                      'OpenCode 命令或可执行文件路径',
                      TextField(
                        controller: widget.openCodeCommandCtrl,
                        decoration: const InputDecoration(
                          hintText: 'opencode',
                        ),
                        onChanged: (_) => widget.onAutoSave(),
                      ),
                    ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      SizedBox(
                        width: 160,
                        child: Text(
                            '进度报告间隔: ${widget.openCodeProgressIntervalSeconds} 秒'),
                      ),
                      Expanded(
                        child: Slider(
                          value: widget.openCodeProgressIntervalSeconds
                              .toDouble()
                              .clamp(1, 600),
                          min: 1,
                          max: 600,
                          divisions: 599,
                          label: '${widget.openCodeProgressIntervalSeconds} 秒',
                          onChanged: (value) {
                            widget.onOpenCodeProgressIntervalSecondsChanged(
                                value.round());
                            widget.onAutoSave();
                          },
                        ),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      SizedBox(
                        width: 160,
                        child: Text(
                          widget.openCodeTimeoutSeconds == 0
                              ? '最大超时: 无限等待'
                              : '最大超时: ${widget.openCodeTimeoutSeconds} 秒',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Slider(
                          value: widget.openCodeTimeoutSeconds
                              .toDouble()
                              .clamp(0.0, 600.0),
                          min: 0,
                          max: 600,
                          divisions: 600,
                          label: widget.openCodeTimeoutSeconds == 0
                              ? '0 秒（无限等待）'
                              : '${widget.openCodeTimeoutSeconds} 秒',
                          onChanged: (val) {
                            widget.onOpenCodeTimeoutSecondsChanged(val.round());
                            widget.onAutoSave();
                          },
                        ),
                      ),
                    ],
                  ),
                  const Divider(height: 24),
                  Row(
                    children: [
                      Text(
                        '已安装自定义工具 (${_tools.length})',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.refresh, size: 20),
                        tooltip: '刷新工具列表',
                        onPressed: () => setState(_loadTools),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (_tools.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        '暂无已安装的持久化工具。\n在对话中指示助手“创建一个持久化工具”即可由 OpenCode 自动生成并注册于此。',
                        style: TextStyle(color: Colors.grey, fontSize: 13),
                      ),
                    )
                  else
                    ..._tools.map(
                      (tool) => Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest
                              .withOpacity(0.4),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: Theme.of(context)
                                .colorScheme
                                .outlineVariant
                                .withOpacity(0.5),
                          ),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Text(
                                        tool.name,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 14,
                                          fontFamily: 'monospace',
                                        ),
                                      ),
                                      if (tool.createdAt.isNotEmpty) ...[
                                        const SizedBox(width: 8),
                                        Text(
                                          tool.createdAt,
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: Theme.of(context)
                                                .colorScheme
                                                .outline,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    tool.summary,
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                  if (tool.parametersHint.isNotEmpty) ...[
                                    const SizedBox(height: 2),
                                    Text(
                                      '参数: ${tool.parametersHint}',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .secondary,
                                      ),
                                    ),
                                  ],
                                  if (tool.command.isNotEmpty) ...[
                                    const SizedBox(height: 2),
                                    Text(
                                      '命令: ${tool.command}',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .outline,
                                        fontFamily: 'monospace',
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            IconButton(
                              icon: const Icon(
                                Icons.delete_outline,
                                color: Colors.redAccent,
                              ),
                              tooltip: '删除工具',
                              onPressed: () => _confirmAndDeleteTool(tool),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

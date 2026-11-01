import 'package:flutter/material.dart';
import '../../../../core/constants/app_constants.dart';
import 'settings_shared.dart';

class WakeDialogueSection extends StatelessWidget {
  final String startWordMode;
  final ValueChanged<String> onStartWordModeChanged;
  final int continuousModeTimeoutMinutes;
  final ValueChanged<int> onContinuousModeTimeoutMinutesChanged;
  final TextEditingController startWordCtrl;
  final int silenceTimeoutSeconds;
  final ValueChanged<int> onSilenceTimeoutSecondsChanged;
  final void Function({bool immediate}) onAutoSave;

  const WakeDialogueSection({
    super.key,
    required this.startWordMode,
    required this.onStartWordModeChanged,
    required this.continuousModeTimeoutMinutes,
    required this.onContinuousModeTimeoutMinutesChanged,
    required this.startWordCtrl,
    required this.silenceTimeoutSeconds,
    required this.onSilenceTimeoutSecondsChanged,
    required this.onAutoSave,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        buildSectionHeader(context, '语音唤醒与连续对话', Icons.record_voice_over),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                buildLabeledField(
                  '唤醒交互模式',
                  DropdownButtonFormField<String>(
                    value: startWordMode,
                    isExpanded: true,
                    decoration: const InputDecoration(),
                    items: const [
                      DropdownMenuItem(
                        value: AppConstants.startWordModeEnabled,
                        child: Text('1. 启用（每次均需称呼名字唤醒）'),
                      ),
                      DropdownMenuItem(
                        value: AppConstants.startWordModeDisabled,
                        child: Text('2. 关闭（无需称呼名字，直接交互）'),
                      ),
                      DropdownMenuItem(
                        value: AppConstants.startWordModeAuto,
                        child: Text('3. 自动（唤醒后进入连续对话）'),
                      ),
                    ],
                    onChanged: (v) {
                      if (v != null) {
                        onStartWordModeChanged(v);
                        onAutoSave(immediate: true);
                      }
                    },
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  startWordMode == AppConstants.startWordModeAuto
                      ? '自动模式：唤醒后进入连续对话，由大模型智能理解对话意图；无对话超时或大模型识别到结束意图自动退出。'
                      : (startWordMode == AppConstants.startWordModeEnabled
                          ? '启用模式：每次发起提问或交互前，均需先呼唤名字唤醒。'
                          : '关闭模式：待机状态下无需呼唤名字，随时直接说话即可发起交互。'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (startWordMode == AppConstants.startWordModeAuto) ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Text('连续对话退出时间: $continuousModeTimeoutMinutes 分钟'),
                      Expanded(
                        child: Slider(
                          value: continuousModeTimeoutMinutes
                              .toDouble()
                              .clamp(1.0, 60.0),
                          min: 1,
                          max: 60,
                          divisions: 59,
                          label: '$continuousModeTimeoutMinutes 分钟',
                          onChanged: (v) {
                            onContinuousModeTimeoutMinutesChanged(v.round());
                            onAutoSave();
                          },
                        ),
                      ),
                    ],
                  ),
                ],
                const Divider(height: 20),
                buildLabeledField(
                  '唤醒名字',
                  TextField(
                    controller: startWordCtrl,
                    decoration: const InputDecoration(
                      hintText: '如：晓漫，支持分号分隔多个别名',
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Text('静音断句超时: $silenceTimeoutSeconds 秒'),
                    Expanded(
                      child: Slider(
                        value: silenceTimeoutSeconds.toDouble(),
                        min: 1,
                        max: 30,
                        divisions: 29,
                        label: '$silenceTimeoutSeconds 秒',
                        onChanged: (v) {
                          onSilenceTimeoutSecondsChanged(v.toInt());
                          onAutoSave();
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

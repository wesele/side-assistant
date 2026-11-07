import 'package:flutter/material.dart';
import '../../../../core/constants/app_constants.dart';
import 'settings_shared.dart';

class WakeDialogueSection extends StatelessWidget {
  final String startWordMode;
  final ValueChanged<String> onStartWordModeChanged;
  final int continuousModeTimeoutMinutes;
  final ValueChanged<int> onContinuousModeTimeoutMinutesChanged;
  final TextEditingController startWordCtrl;
  final double silenceTimeoutSeconds;
  final ValueChanged<double> onSilenceTimeoutSecondsChanged;
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
                    Text('静音断句超时: ${_formatSeconds(silenceTimeoutSeconds)}'),
                    Expanded(
                      child: Slider(
                        value: silenceTimeoutSeconds.clamp(
                          AppConstants.minSilenceTimeoutSeconds,
                          AppConstants.maxSilenceTimeoutSeconds,
                        ),
                        min: AppConstants.minSilenceTimeoutSeconds,
                        max: AppConstants.maxSilenceTimeoutSeconds,
                        // 0.1 秒步进：(10.0 - 0.1) / 0.1 = 99 段
                        divisions: ((AppConstants.maxSilenceTimeoutSeconds -
                                    AppConstants.minSilenceTimeoutSeconds) /
                                AppConstants.silenceTimeoutStepSeconds)
                            .round(),
                        label: _formatSeconds(silenceTimeoutSeconds),
                        onChanged: (v) {
                          onSilenceTimeoutSecondsChanged(
                            _roundToStep(v),
                          );
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

/// 把滑块浮点值吸附到 [AppConstants.silenceTimeoutStepSeconds] 的整数倍，
/// 避免出现 3.0999999999999996 这类浮点误差被写进配置。
double _roundToStep(double seconds) {
  final steps =
      (seconds / AppConstants.silenceTimeoutStepSeconds).roundToDouble();
  return (steps * AppConstants.silenceTimeoutStepSeconds * 10).round() / 10;
}

/// 展示用文案：整数秒显示「3 秒」，带小数显示「0.1 秒」。
String _formatSeconds(double seconds) {
  final rounded = (seconds * 10).round() / 10;
  final text = rounded == rounded.roundToDouble()
      ? rounded.toInt().toString()
      : rounded.toStringAsFixed(1);
  return '$text 秒';
}

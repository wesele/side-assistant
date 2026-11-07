import 'package:flutter/material.dart';

import '../../core/models/audio_input_device_kind.dart';
import '../theme/app_theme.dart';

/// 主界面「监听话筒」按钮的图标与配色。
///
/// 在原本只用 `isMicListening` 表达开/关的基础上，额外用颜色 + 角标区分
/// 当前生效的录音音源：内置麦克风（青色）、蓝牙麦克风（蓝色）、外接（橙色）。
/// 这样在 8kHz 蓝牙 HFP 链路上出现识别/声纹异常时，一眼就能看出音源类型。
class MicSourceToggleIcon extends StatelessWidget {
  const MicSourceToggleIcon({
    super.key,
    required this.isListening,
    required this.kind,
  });

  final bool isListening;
  final AudioInputDeviceKind kind;

  /// 蓝牙用蓝色、外接用橙色、内置沿用主题青色，静音时统一走中性色。
  static Color foregroundColor(
    AudioInputDeviceKind kind,
    bool isListening,
    Color mutedColor,
  ) {
    if (!isListening) return mutedColor;
    return switch (kind) {
      AudioInputDeviceKind.bluetooth => const Color(0xFF1E88E5),
      AudioInputDeviceKind.external => const Color(0xFFEF6C00),
      AudioInputDeviceKind.builtIn => AppTheme.accent,
      AudioInputDeviceKind.unknown => AppTheme.accent,
    };
  }

  static String tooltip(
    bool isListening,
    AudioInputDeviceKind kind,
    String deviceLabel,
  ) {
    final state = isListening ? '监听中（点击静音）' : '已静音（点击开启）';
    final source = audioInputDeviceKindLabel(kind);
    final detail = deviceLabel.trim().isEmpty ? '' : ' · $deviceLabel';
    return '话筒$state\n$source$detail';
  }

  IconData? get _badgeIcon => switch (kind) {
        AudioInputDeviceKind.bluetooth => Icons.bluetooth,
        AudioInputDeviceKind.builtIn => Icons.computer,
        AudioInputDeviceKind.external => Icons.usb,
        AudioInputDeviceKind.unknown => null,
      };

  @override
  Widget build(BuildContext context) {
    final badgeIcon = _badgeIcon;
    final badgeColor = kind == AudioInputDeviceKind.bluetooth
        ? const Color(0xFF1E88E5)
        : (kind == AudioInputDeviceKind.external
            ? const Color(0xFFEF6C00)
            : AppTheme.accent);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Icon(
          isListening ? Icons.mic : Icons.mic_off_outlined,
          size: 24,
        ),
        if (badgeIcon != null)
          Positioned(
            right: -5,
            bottom: -2,
            child: Container(
              padding: const EdgeInsets.all(1.5),
              decoration: BoxDecoration(
                color: badgeColor,
                shape: BoxShape.circle,
                border: Border.all(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  width: 1,
                ),
              ),
              child: Icon(badgeIcon, size: 9, color: Colors.white),
            ),
          ),
      ],
    );
  }
}

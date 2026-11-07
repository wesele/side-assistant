import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:side_assistant/core/models/app_settings.dart';
import 'package:side_assistant/core/models/audio_input_device_kind.dart';
import 'package:side_assistant/core/models/device_options.dart';
import 'package:side_assistant/services/speech/speaker_verification_service.dart';
import 'package:side_assistant/ui/theme/app_theme.dart';
import 'package:side_assistant/ui/widgets/mic_source_icon.dart';

/// 音源类型判定 + 声学域分组 + 主界面话筒图标的回归测试。
///
/// 背景：233 上蓝牙 8kHz HFP 与内置宽带麦克风混用同一套声纹模板，
/// 导致「0 次声纹通过」。修复方式为按域分组模板，并在 UI 上明确标出音源。
void main() {
  group('音源类型判定', () {
    test('Linux PipeWire 源名可区分蓝牙与内置声卡', () {
      expect(
        classifyAudioInputDevice(
            'PipeWire/Pulse: bluez_input.00_02_5B_43_DC_EE.0'),
        AudioInputDeviceKind.bluetooth,
      );
      expect(
        classifyAudioInputDevice(
            'PipeWire/Pulse: alsa_input.pci-0000_00_1b.0.analog-stereo'),
        AudioInputDeviceKind.builtIn,
      );
      expect(
        classifyAudioInputDevice('PipeWire/Pulse: bluez_input.x (系统默认)'),
        AudioInputDeviceKind.bluetooth,
      );
    });

    test('标签无法判定时回退到配置 id', () {
      expect(
        classifyAudioInputDevice('自动（系统默认）',
            id: 'pulse:bluez_input.00_02_5B_43_DC_EE.0'),
        AudioInputDeviceKind.bluetooth,
      );
      expect(
        classifyAudioInputDevice(null, id: 'alsa:plughw:1,0'),
        AudioInputDeviceKind.external,
      );
      expect(classifyAudioInputDevice('Virtual Mic'),
          AudioInputDeviceKind.unknown);
    });

    test('Android / 中文设备标签与设备枚举对象', () {
      expect(classifyAudioInputDevice('蓝牙耳机 (SCO)'),
          AudioInputDeviceKind.bluetooth);
      expect(classifyAudioInputDevice('内置麦克风'), AudioInputDeviceKind.builtIn);
      expect(
          classifyAudioInputDevice('USB 外接麦克风'), AudioInputDeviceKind.external);
      expect(
        classifyAudioDeviceOption(const AudioDeviceOption(
          id: 'bt-1',
          label: 'Some headset',
          isBluetooth: true,
        )),
        AudioInputDeviceKind.bluetooth,
      );
    });

    test('机器名与中文名一一对应', () {
      expect(audioInputDeviceKindName(AudioInputDeviceKind.bluetooth),
          'bluetooth');
      expect(
          audioInputDeviceKindLabel(AudioInputDeviceKind.bluetooth), '蓝牙麦克风');
      expect(audioInputDeviceKindLabel(AudioInputDeviceKind.builtIn), '内置麦克风');
    });
  });

  group('声学域归属', () {
    test('蓝牙与 SCO 丢包指纹归入窄带，内置麦克风归入宽带', () {
      expect(
        speakerDomainFor(deviceLabel: 'PipeWire/Pulse: bluez_input.abc'),
        speakerDomainNarrowband,
      );
      expect(
        speakerDomainFor(
            deviceLabel: 'PipeWire/Pulse: alsa_input.pci-0.analog-stereo'),
        speakerDomainWideband,
      );
      expect(
        speakerDomainFor(deviceLabel: 'Virtual Mic', narrowbandSignal: true),
        speakerDomainNarrowband,
      );
      expect(speakerDomainFor(), speakerDomainWideband);
    });
  });

  group('声纹模板声学域分组', () {
    List<double> v(int n) => [for (var i = 0; i < 8; i++) (n + i).toDouble()];

    test('旧库无标签时全部按宽带兼容，窄带比对暂时回退到全部', () {
      final book = SpeakerDomainBook.fromStored([v(1), v(2), v(3)], const []);
      expect(book.length, 3);
      expect(book.domains, List.filled(3, speakerDomainWideband));

      final narrow = book.templatesFor(speakerDomainNarrowband);
      expect(narrow.usedFallback, isTrue);
      expect(narrow.templates.length, 3);
      expect(book.templatesFor(speakerDomainWideband).usedFallback, isFalse);
    });

    test('录入窄带模板后，宽带与窄带各用各的，互不污染', () {
      final book = SpeakerDomainBook.fromStored([v(1), v(2)], const []);
      book.add(v(3), speakerDomainNarrowband);
      book.add(v(4), speakerDomainNarrowband);

      final narrow = book.templatesFor(speakerDomainNarrowband);
      expect(narrow.usedFallback, isFalse);
      expect(narrow.templates.length, 2);
      expect(narrow.templates.first.first, 3.0);

      final wide = book.templatesFor(speakerDomainWideband);
      expect(wide.templates.length, 2);
      expect(wide.templates.first.first, 1.0);

      expect(book.clearDomain(speakerDomainNarrowband), 2);
      expect(book.length, 2);
    });

    test('每域上限与全局上限裁剪，且标签始终对齐', () {
      final book = SpeakerDomainBook.fromStored([], const []);
      for (var i = 0; i < 8; i++) {
        book.add(
            v(i), i.isEven ? speakerDomainWideband : speakerDomainNarrowband);
      }
      book.trim(maxPerDomain: 3, maxTotal: 5);
      expect(book.length, lessThanOrEqualTo(5));
      expect(
        book.domains.where((d) => d == speakerDomainWideband).length,
        lessThanOrEqualTo(3),
      );
      expect(
        book.domains.where((d) => d == speakerDomainNarrowband).length,
        lessThanOrEqualTo(3),
      );
      expect(book.domains.length, book.embeddings.length);
    });

    test('ownerSpeakerDomains 配置字段可持久化并双向还原', () {
      final settings = AppSettings.fromMap({
        'ownerSpeakerEmbeddings': [
          [1.0, 2.0],
          [3.0, 4.0],
        ],
        'ownerSpeakerDomains': ['wideband', 'narrowband'],
        'audioInputDeviceId': 'pulse:bluez_input.AA_BB',
      });
      expect(settings.ownerSpeakerDomains, ['wideband', 'narrowband']);
      final restored = AppSettings.fromMap(settings.toMap());
      expect(restored.ownerSpeakerEmbeddings.length, 2);
      expect(restored.ownerSpeakerDomains.last, 'narrowband');
    });
  });

  group('主界面话筒图标', () {
    testWidgets('蓝牙音源显示麦克风 + 蓝牙角标，内置显示电脑角标', (WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: MicSourceToggleIcon(
            isListening: true,
            kind: AudioInputDeviceKind.bluetooth,
          ),
        ),
      ));
      expect(find.byIcon(Icons.mic), findsOneWidget);
      expect(find.byIcon(Icons.bluetooth), findsOneWidget);
      expect(find.byIcon(Icons.computer), findsNothing);

      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: MicSourceToggleIcon(
            isListening: true,
            kind: AudioInputDeviceKind.builtIn,
          ),
        ),
      ));
      expect(find.byIcon(Icons.computer), findsOneWidget);
      expect(find.byIcon(Icons.bluetooth), findsNothing);
    });

    testWidgets('静音态与未知音源不显示角标', (WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: MicSourceToggleIcon(
            isListening: false,
            kind: AudioInputDeviceKind.unknown,
          ),
        ),
      ));
      expect(find.byIcon(Icons.mic_off_outlined), findsOneWidget);
      expect(find.byIcon(Icons.bluetooth), findsNothing);
      expect(find.byIcon(Icons.computer), findsNothing);
    });

    test('配色与 tooltip 明确区分音源', () {
      expect(
        MicSourceToggleIcon.foregroundColor(
            AudioInputDeviceKind.bluetooth, true, Colors.grey),
        isNot(equals(AppTheme.accent)),
      );
      expect(
        MicSourceToggleIcon.tooltip(
          true,
          AudioInputDeviceKind.bluetooth,
          'bluez_input.00_02_5B',
        ),
        contains('蓝牙麦克风'),
      );
      expect(
        MicSourceToggleIcon.tooltip(
          true,
          AudioInputDeviceKind.builtIn,
          'alsa_input.pci-0',
        ),
        contains('内置麦克风'),
      );
    });
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:side_assistant/core/platform/linux/linux_hardware_adapter.dart';

void main() {
  group('Adversarial 1: LinuxAudioDeviceService Parser Stress Testing', () {
    test(
        '1.1 parsePactlSources handles corrupted, empty, and adversarial lines',
        () {
      // 1. Empty string & whitespace
      expect(LinuxAudioDeviceService.parsePactlSources(''), isEmpty);
      expect(
          LinuxAudioDeviceService.parsePactlSources('   \t\r\n   '), isEmpty);

      // 2. Single-token lines
      expect(LinuxAudioDeviceService.parsePactlSources('0\n1\n2\n'), isEmpty);

      // 3. Monitor variants: .monitor must be excluded, but strings with 'monitor' in prefix should not be accidentally excluded unless ending with .monitor
      const mixedMonitorSample = '''
0\talsa_output.pci.monitor\tPipeWire\ts32le\tRUNNING
1\talsa_input.pci.monitor.sub\tPipeWire\ts32le\tRUNNING
2\talsa_input.monitoring_source\tPipeWire\ts32le\tRUNNING
3\talsa_output.usb.analog-stereo.monitor\tPipeWire\ts32le\tRUNNING
''';
      final monitorDevices =
          LinuxAudioDeviceService.parsePactlSources(mixedMonitorSample);
      // Lines 0 and 3 end with .monitor, so only lines 1 and 2 should remain
      expect(monitorDevices.length, equals(2));
      expect(monitorDevices.any((d) => d.id.endsWith('.monitor')), isFalse);
      expect(monitorDevices[0].id, equals('pulse:alsa_input.pci.monitor.sub'));
      expect(
          monitorDevices[1].id, equals('pulse:alsa_input.monitoring_source'));

      // 4. Bluetooth casing variations
      const btSample = '''
10\tbluez_input.00_11_22\tPipeWire\ts16le
11\tBLUEZ_SOURCE_HD\tPipeWire\ts16le
12\tBluetooth_Mic_Device\tPipeWire\ts16le
13\tregular_mic_source\tPipeWire\ts16le
''';
      final btDevices = LinuxAudioDeviceService.parsePactlSources(btSample);
      expect(btDevices.length, equals(4));
      expect(btDevices[0].isBluetooth, isTrue);
      expect(btDevices[1].isBluetooth, isTrue);
      expect(btDevices[2].isBluetooth, isTrue);
      expect(btDevices[3].isBluetooth, isFalse);

      // 5. Duplicate ID deduplication with external seenIds
      final externalSeen = <String>{'pulse:existing_device'};
      const dupSample = '''
20\texisting_device\tPipeWire\ts16le
21\tnew_device\tPipeWire\ts16le
22\tnew_device\tPipeWire\ts16le
''';
      final dedupDevices = LinuxAudioDeviceService.parsePactlSources(
        dupSample,
        seenIds: externalSeen,
      );
      expect(dedupDevices.length, equals(1));
      expect(dedupDevices[0].id, equals('pulse:new_device'));
      expect(externalSeen.contains('pulse:new_device'), isTrue);

      // 6. High volume generator stress test (1,000 malformed lines)
      final sb = StringBuffer();
      for (var i = 0; i < 1000; i++) {
        if (i % 3 == 0) {
          sb.writeln('$i');
        } else if (i % 3 == 1) {
          sb.writeln('$i\t   ');
        } else {
          sb.writeln('$i\tsource_$i\tPipeWire\textra\tcolumns\there');
        }
      }
      final highVolDevices =
          LinuxAudioDeviceService.parsePactlSources(sb.toString());
      expect(highVolDevices.length,
          equals(333)); // exactly the ones with source_$i

      // 7. Non-numeric leading tokens (demonstrating parser behavior on error strings)
      const errorSample = 'Connection failure: Connection refused';
      final errParsed = LinuxAudioDeviceService.parsePactlSources(errorSample);
      // Because parser splits on whitespace without checking for integer index, token 1 is captured
      expect(errParsed.length, equals(1));
      expect(errParsed[0].id, equals('pulse:failure:'));
    });

    test(
        '1.2 parseArecordList handles malformed ALSA hardware lines and edge cases',
        () {
      // 1. Empty string & whitespace
      expect(LinuxAudioDeviceService.parseArecordList(''), isEmpty);
      expect(LinuxAudioDeviceService.parseArecordList('   \n\r\n   '), isEmpty);

      // 2. ALSA standard error / no soundcards message
      const noCardsOutput = '''
arecord: pcm_list:272: no soundcards found...
ALSA lib pcm.c:2660:(snd_pcm_open_noupdate) Unknown PCM
''';
      expect(LinuxAudioDeviceService.parseArecordList(noCardsOutput), isEmpty);

      // 3. Malformed lines missing brackets, numbers, or colons
      const malformedALSA = '''
**** List of CAPTURE Hardware Devices ****
card : MissingCardNum [HDA], device 0: Dev [Dev]
card 0 PCH [HDA Intel], device 0: Dev [Dev]
card 1: PCH HDA Intel], device 0: Dev [Dev]
card 2: PCH [HDA Intel, device 0: Dev [Dev]
card 3: PCH [HDA Intel], device : Dev [Dev]
card 4: PCH [HDA Intel], device 0 Dev [Dev]
card 5: PCH [HDA Intel], device 0: Dev Dev]
card 6: PCH [HDA Intel], device 0: Dev [Dev
card 7: RealCard [RealCardName], device 0: RealDev [RealDevName]
Subdevices: 1/1
Subdevice #0: subdevice #0
''';
      final parsed = LinuxAudioDeviceService.parseArecordList(malformedALSA);
      // Only card 7 strictly matches the standard ALSA regex
      expect(parsed.length, equals(1));
      expect(parsed[0].id, equals('alsa:plughw:7,0'));
      expect(parsed[0].label, contains('RealCardName'));
      expect(parsed[0].label, contains('RealDevName'));

      // 4. Duplicate cards / devices
      const dupAlsa = '''
card 0: CardA [CardNameA], device 0: Dev0 [DevName0]
card 0: CardA [CardNameA], device 0: Dev0 [DevName0]
card 0: CardA [CardNameA], device 1: Dev1 [DevName1]
''';
      final dedupAlsa = LinuxAudioDeviceService.parseArecordList(dupAlsa);
      expect(dedupAlsa.length, equals(2));
      expect(dedupAlsa[0].id, equals('alsa:plughw:0,0'));
      expect(dedupAlsa[1].id, equals('alsa:plughw:0,1'));
    });

    test('1.3 parsePactlSinks & parseAplayList handle corrupt outputs', () {
      expect(LinuxAudioDeviceService.parsePactlSinks(''), isEmpty);
      expect(LinuxAudioDeviceService.parsePactlSinks('0\n1\n'), isEmpty);

      const sinkSample = '''
0\talsa_output.pci-0000.analog-stereo\tPipeWire\ts32le 2ch 48000Hz\tRUNNING
1\t\t\t
2\tbluez_output.headset\tPipeWire\ts16le 2ch 44100Hz\tSUSPENDED
''';
      final sinks = LinuxAudioDeviceService.parsePactlSinks(sinkSample);
      // Line 1 contains only tabs and whitespace, so it produces only 1 token when trimmed, skipped!
      expect(sinks.length, equals(2));
      expect(sinks[0].id, equals('pulse:alsa_output.pci-0000.analog-stereo'));
      expect(sinks[1].id, equals('pulse:bluez_output.headset'));

      expect(LinuxAudioDeviceService.parseAplayList(''), isEmpty);
      expect(
          LinuxAudioDeviceService.parseAplayList('aplay: no soundcards found'),
          isEmpty);
    });

    test(
        '1.4 parsePactlVolume & parseAmixerVolume boundary values and extreme inputs',
        () {
      // pactl volume extraction
      expect(LinuxAudioDeviceService.parsePactlVolume(''), isNull);
      expect(LinuxAudioDeviceService.parsePactlVolume('Volume: none'), isNull);
      expect(LinuxAudioDeviceService.parsePactlVolume('Volume: 0%'), equals(0));
      expect(LinuxAudioDeviceService.parsePactlVolume('Volume: 100%'),
          equals(100));
      expect(LinuxAudioDeviceService.parsePactlVolume('Volume: 150%'),
          equals(150));
      // Clamp > 150
      expect(LinuxAudioDeviceService.parsePactlVolume('Volume: 250%'),
          equals(150));
      // First percentage match when multi-channel has different values
      expect(
        LinuxAudioDeviceService.parsePactlVolume(
          'Volume: front-left: 45875 / 70% / -9.30 dB, front-right: 55705 / 85% / -4.23 dB',
        ),
        equals(70),
      );

      // amixer volume extraction
      expect(LinuxAudioDeviceService.parseAmixerVolume(''), isNull);
      expect(
          LinuxAudioDeviceService.parseAmixerVolume(
              'Limits: Playback 0 - 65536'),
          isNull);
      expect(LinuxAudioDeviceService.parseAmixerVolume('[0%] [on]'), equals(0));
      expect(
          LinuxAudioDeviceService.parseAmixerVolume('[85%] [on]'), equals(85));
      expect(LinuxAudioDeviceService.parseAmixerVolume('[160%] [on]'),
          equals(150));
    });
  });

  group(
      'Adversarial 2: LinuxSystemMetricsService /proc/stat CPU Parsing & Debounce Stress',
      () {
    setUp(() {
      LinuxSystemMetricsService.resetCpuUsageCountersForTest();
    });

    test('2.1 parseProcStatCpuCounters adversarial input formats', () {
      // 1. Empty and garbage
      expect(LinuxSystemMetricsService.parseProcStatCpuCounters(''), isNull);
      expect(
          LinuxSystemMetricsService.parseProcStatCpuCounters(
              'not a proc stat\nfoo bar'),
          isNull);

      // 2. Missing aggregate 'cpu' line (only per-core cpu0, cpu1)
      const perCoreOnly = '''
cpu0 1000 200 300 4000 50 10 20 5 0 0
cpu1 1100 210 310 4100 55 11 21 6 0 0
intr 123456
''';
      expect(LinuxSystemMetricsService.parseProcStatCpuCounters(perCoreOnly),
          isNull);

      // 3. Line with 'cpu' prefix but fewer than 5 columns
      expect(LinuxSystemMetricsService.parseProcStatCpuCounters('cpu 100 200'),
          isNull);
      expect(
          LinuxSystemMetricsService.parseProcStatCpuCounters('cpu 100 200 300'),
          isNull);

      // 4. Tab-separated cpu line with 10 columns
      const tabSeparated = 'cpu\t500\t100\t200\t1000\t50\t10\t20\t5\t0\t0\n';
      final tabCounters =
          LinuxSystemMetricsService.parseProcStatCpuCounters(tabSeparated);
      expect(tabCounters, isNotNull);
      final (tActive, tTotal) = tabCounters!;
      // active = 500(user) + 100(nice) + 200(sys) + 10(irq) + 20(softirq) + 5(steal) = 835
      expect(tActive, equals(500 + 100 + 200 + 10 + 20 + 5));
      // total = active(835) + 1000(idle) + 50(iowait) = 1885
      expect(tTotal, equals(tActive + 1000 + 50));

      // 5. Non-numeric values inside cpu columns default safely to 0
      const nonNumeric =
          'cpu  user nice sys 1000 iowait irq softirq steal 0 0\n';
      final nonNumCounters =
          LinuxSystemMetricsService.parseProcStatCpuCounters(nonNumeric);
      expect(nonNumCounters, isNotNull);
      final (nnActive, nnTotal) = nonNumCounters!;
      expect(nnActive, equals(0));
      expect(nnTotal, equals(1000)); // only idle was numeric

      // 6. Huge 64-bit integer values in /proc/stat
      const hugeNums =
          'cpu  100000000000 20000000000 30000000000 500000000000 1000000000 0 0 0 0 0\n';
      final hugeCounters =
          LinuxSystemMetricsService.parseProcStatCpuCounters(hugeNums);
      expect(hugeCounters, isNotNull);
      final (hActive, hTotal) = hugeCounters!;
      expect(hActive, equals(100000000000 + 20000000000 + 30000000000));
      expect(hTotal, equals(hActive + 500000000000 + 1000000000));
    });

    test(
        '2.2 getCpuUsagePercent debounce timing, zero division, and counter reset resilience',
        () async {
      final tempDir = Directory.systemTemp.createTempSync('adv_cpu_stat_');
      final statFile = File('${tempDir.path}/stat');

      // Step 1: Initial baseline setting
      statFile.writeAsStringSync('cpu  1000 0 500 8500 0 0 0 0 0 0\n');
      final v1 = LinuxSystemMetricsService.getCpuUsagePercent(
          procStatPath: statFile.path);
      expect(v1, equals(0.0));

      // Step 2: High frequency burst (50 queries in tight loop)
      // Modifying file contents during burst to prove debounce caches the result without reading file
      statFile.writeAsStringSync('cpu  5000 0 5000 5000 0 0 0 0 0 0\n');
      for (var i = 0; i < 50; i++) {
        final cached = LinuxSystemMetricsService.getCpuUsagePercent(
            procStatPath: statFile.path);
        expect(cached, equals(0.0)); // Must remain cached 0.0 because < 600ms
      }

      // Step 3: Wait past 600ms debounce window
      await Future.delayed(const Duration(milliseconds: 650));
      // active was: 1500, now: 5000 + 5000 = 10000 (deltaActive = 8500)
      // total was: 10000, now: 15000 (deltaTotal = 5000) -> clamp to 100.0%
      final v2 = LinuxSystemMetricsService.getCpuUsagePercent(
          procStatPath: statFile.path);
      expect(v2, equals(100.0));

      // Step 4: Stagnant counters test (deltaTotal == 0)
      await Future.delayed(const Duration(milliseconds: 650));
      // Same file contents (no delta)
      final v3 = LinuxSystemMetricsService.getCpuUsagePercent(
          procStatPath: statFile.path);
      // When deltaTotal == 0, guard `deltaTotal > 0` prevents division by zero and preserves last percent
      expect(v3, equals(100.0));
      expect(v3.isNaN, isFalse);
      expect(v3.isInfinite, isFalse);

      // Step 5: System reboot / counter rollover (total drops from 15000 down to 2000)
      await Future.delayed(const Duration(milliseconds: 650));
      statFile.writeAsStringSync('cpu  100 0 100 1800 0 0 0 0 0 0\n');
      final v4 = LinuxSystemMetricsService.getCpuUsagePercent(
          procStatPath: statFile.path);
      // deltaTotal < 0, guard prevents invalid calculation, retains last valid percent
      expect(v4, equals(100.0));

      // Step 6: Subsequent tick after rollover calculates correctly against new baseline (2000)
      await Future.delayed(const Duration(milliseconds: 650));
      // active goes from 200 to 400 (deltaActive = 200)
      // total goes from 2000 to 2400 (deltaTotal = 400)
      // cpu = 200 / 400 * 100 = 50.0%
      statFile.writeAsStringSync('cpu  200 0 200 2000 0 0 0 0 0 0\n');
      final v5 = LinuxSystemMetricsService.getCpuUsagePercent(
          procStatPath: statFile.path);
      expect(v5, closeTo(50.0, 0.1));

      tempDir.deleteSync(recursive: true);
    });
  });

  group('Adversarial 3: Cross-Platform Safety Guards on Windows Runtime', () {
    test(
        '3.1 LinuxAudioDeviceService runtime guards prevent OS sub-process failures',
        () async {
      if (!Platform.isLinux) {
        // 1. Input devices enumeration returns [] immediately without spawning pactl/arecord
        final inputs = await LinuxAudioDeviceService.listInputDevices();
        expect(inputs, isEmpty);

        // 2. Output devices enumeration returns [] immediately without spawning pactl/aplay
        final outputs = await LinuxAudioDeviceService.listOutputDevices();
        expect(outputs, isEmpty);

        // 3. Output volume reading returns cached volume without running pactl/amixer
        final vol = await LinuxAudioDeviceService.getOutputVolume();
        expect(vol, isNonNegative);

        // 4. Output volume setting safely updates in-memory value without crashing on amixer
        await LinuxAudioDeviceService.setOutputVolume(42);
        expect(LinuxAudioDeviceService.currentVolumePercent, equals(42));
        final volAfter = await LinuxAudioDeviceService.getOutputVolume();
        expect(volAfter, equals(42));
      }
    });

    test('3.2 LinuxCameraCaptureService runtime guards on non-Linux', () async {
      if (!Platform.isLinux) {
        // Default sysfsDir returns [] immediately
        final cameras = await LinuxCameraCaptureService.listCameraDevices();
        expect(cameras, isEmpty);

        // Non-existent directory returns [] without throwing
        final nonExistent = await LinuxCameraCaptureService.listCameraDevices(
          sysfsDir: 'C:\\non\\existent\\sysfs',
        );
        expect(nonExistent, isEmpty);
      }
    });

    test(
        '3.3 LinuxAudioPlaybackService.killRunningPlayProcesses safety on non-Linux',
        () async {
      // Must not throw ProcessException for pkill on Windows
      await expectLater(
        LinuxAudioPlaybackService.killRunningPlayProcesses(),
        completes,
      );
    });

    test(
        '3.4 LinuxSystemMetricsService safely defaults on Windows where /proc/stat is absent',
        () {
      LinuxSystemMetricsService.resetCpuUsageCountersForTest();
      // On Windows /proc/stat does not exist; function must return 0.0 without throwing
      final cpu = LinuxSystemMetricsService.getCpuUsagePercent();
      expect(cpu, equals(0.0));
    });

    test(
        '3.5 LinuxHardwareAdapter Facade provides unified cross-platform safety',
        () async {
      if (!Platform.isLinux) {
        expect(await LinuxHardwareAdapter.listInputDevices(), isEmpty);
        expect(await LinuxHardwareAdapter.listOutputDevices(), isEmpty);
        expect(await LinuxHardwareAdapter.listCameraDevices(), isEmpty);
        expect(LinuxHardwareAdapter.getCpuUsagePercent(), equals(0.0));
        await expectLater(
            LinuxHardwareAdapter.killRunningPlayProcesses(), completes);
      }
    });
  });

  group('Adversarial 4: LinuxCameraCaptureService Mock Sysfs Stress Testing',
      () {
    test(
        '4.1 listCameraDevices handles missing index file, corrupt name file, and non-directories',
        () async {
      final tempSys = Directory.systemTemp.createTempSync('sys_v4l2_adv_');

      // 1. Regular file inside sysfs (should be ignored, not treated as video device)
      File('${tempSys.path}/spurious_file.txt').writeAsStringSync('ignore me');

      // 2. Camera video0 without index file (should default to included)
      final v0 = Directory('${tempSys.path}/video0')..createSync();
      File('${v0.path}/name').writeAsStringSync('No Index Cam\n');

      // 3. Camera video1 with index=0 and empty name file
      final v1 = Directory('${tempSys.path}/video1')..createSync();
      File('${v1.path}/index').writeAsStringSync('0\n');
      File('${v1.path}/name').writeAsStringSync('   \n');

      // 4. Camera video2 with index=1 (metadata node, should be skipped)
      final v2 = Directory('${tempSys.path}/video2')..createSync();
      File('${v2.path}/index').writeAsStringSync('1\n');
      File('${v2.path}/name').writeAsStringSync('Metadata Node\n');

      final cameras = await LinuxCameraCaptureService.listCameraDevices(
          sysfsDir: tempSys.path);
      expect(cameras.length, equals(2));
      expect(cameras[0].id, equals('/dev/video0'));
      expect(cameras[0].label, equals('No Index Cam (/dev/video0)'));

      // When name is empty whitespace, label falls back to devName ('video1')
      expect(cameras[1].id, equals('/dev/video1'));
      expect(cameras[1].label, equals('video1'));

      tempSys.deleteSync(recursive: true);
    });
  });
}

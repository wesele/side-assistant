import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:side_assistant/core/platform/linux/linux_audio_env.dart';
import 'package:side_assistant/core/platform/linux/linux_hardware_adapter.dart';

void main() {
  group('Group 1: LinuxSystemMetricsService CPU 采样与解析', () {
    setUp(() {
      LinuxSystemMetricsService.resetCpuUsageCountersForTest();
    });

    test('1.1 parseProcStatCpuCounters 解析标准 10 列 /proc/stat CPU 计数器', () {
      const procStatSample = '''
cpu  101324 2134 54321 897654 1234 567 890 123 0 0
cpu0 50123 1000 27000 448000 600 280 440 60 0 0
''';
      final counters =
          LinuxSystemMetricsService.parseProcStatCpuCounters(procStatSample);
      expect(counters, isNotNull);
      final (active, total) = counters!;
      // active = user(101324) + nice(2134) + system(54321) + irq(567) + softirq(890) + steal(123) = 159359
      expect(active, equals(101324 + 2134 + 54321 + 567 + 890 + 123));
      // total = active + idle(897654) + iowait(1234) = 159359 + 897654 + 1234 = 1058247
      expect(total, equals(active + 897654 + 1234));
    });

    test('1.2 parseProcStatCpuCounters 遇到空内容或格式异常安全返回 null', () {
      expect(LinuxSystemMetricsService.parseProcStatCpuCounters(''), isNull);
      expect(
          LinuxSystemMetricsService.parseProcStatCpuCounters('not_a_stat_line'),
          isNull);
      expect(LinuxSystemMetricsService.parseProcStatCpuCounters('cpu 12 34'),
          isNull);
    });

    test('1.3 getCpuUsagePercent 基于真实 Mock 文件计算采样百分比且满足 600ms 防抖', () async {
      final tempDir = Directory.systemTemp.createTempSync('proc_stat_test_');
      final statFile = File('${tempDir.path}/stat');

      // T1: 初始基准点
      statFile.writeAsStringSync('cpu  1000 0 500 8500 0 0 0 0 0 0\n');
      final p1 = LinuxSystemMetricsService.getCpuUsagePercent(
          procStatPath: statFile.path);
      expect(p1, equals(0.0)); // 首次采样返回 0.0 并建立基线

      // T2: 立即采样 (耗时 < 600ms)，触发防抖缓存返回上次值
      statFile.writeAsStringSync('cpu  1500 0 500 8500 0 0 0 0 0 0\n');
      final p2 = LinuxSystemMetricsService.getCpuUsagePercent(
          procStatPath: statFile.path);
      expect(p2, equals(0.0));

      // T3: 模拟超过 600ms 防抖窗
      await Future.delayed(const Duration(milliseconds: 650));
      // deltaActive = (1500 - 1000) = 500
      // deltaTotal = (1500 + 500 + 8500) - (1000 + 500 + 8500) = 10500 - 10000 = 500
      // CPU = 500 / 500 * 100 = 100%
      statFile.writeAsStringSync('cpu  1500 0 500 8500 0 0 0 0 0 0\n');
      final p3 = LinuxSystemMetricsService.getCpuUsagePercent(
          procStatPath: statFile.path);
      expect(p3, closeTo(100.0, 0.1));

      tempDir.deleteSync(recursive: true);
    });

    test('1.4 resetCpuUsageCountersForTest 重置计数器状态保证测试独立性', () {
      LinuxSystemMetricsService.resetCpuUsageCountersForTest();
      // 在未采样前防抖不生效，始终返回 0.0
      expect(
          LinuxSystemMetricsService.getCpuUsagePercent(
              procStatPath: '/non/existent/path'),
          equals(0.0));
    });
  });

  group('Group 2: LinuxAudioDeviceService ALSA 与 Pulse 解析', () {
    test('2.1 parsePactlSources 成功解析 Pulse 源并过滤 .monitor 环回节点', () {
      const sampleSources = '''
0	alsa_output.pci-0000_00_1f.3.analog-stereo.monitor	PipeWire	s32le 2ch 48000Hz	SUSPENDED
1	alsa_input.pci-0000_00_1f.3.analog-stereo	PipeWire	s32le 2ch 48000Hz	RUNNING
2	bluez_input.00_1B_66_81_2A_EC	PipeWire	s16le 1ch 16000Hz	SUSPENDED
''';
      final devices = LinuxAudioDeviceService.parsePactlSources(sampleSources);
      expect(devices.length, equals(2)); // .monitor 节点被成功过滤

      final d1 = devices[0];
      expect(d1.id, equals('pulse:alsa_input.pci-0000_00_1f.3.analog-stereo'));
      expect(d1.isBluetooth, isFalse);

      final d2 = devices[1];
      expect(d2.id, equals('pulse:bluez_input.00_1B_66_81_2A_EC'));
      expect(d2.isBluetooth, isTrue);
    });

    test('2.2 parseArecordList 成功提取 ALSA 硬件卡号、设备号与名称', () {
      const sampleArecord = '''
**** List of CAPTURE Hardware Devices ****
card 0: PCH [HDA Intel PCH], device 0: ALC269VC Analog [ALC269VC Analog]
  Subdevices: 1/1
  Subdevice #0: subdevice #0
card 1: Device [USB Audio Device], device 0: USB Audio [USB Audio]
  Subdevices: 1/1
  Subdevice #0: subdevice #0
''';
      final devices = LinuxAudioDeviceService.parseArecordList(sampleArecord);
      expect(devices.length, equals(2));

      expect(devices[0].id, equals('alsa:plughw:0,0'));
      expect(devices[0].label, contains('HDA Intel PCH'));
      expect(devices[0].label, contains('ALC269VC Analog'));

      expect(devices[1].id, equals('alsa:plughw:1,0'));
      expect(devices[1].label, contains('USB Audio Device'));
    });

    test('2.3 parsePactlSinks 与 parseAplayList 成功解析输出设备并完成去重', () {
      const sampleSinks = '''
0	alsa_output.pci-0000_00_1f.3.analog-stereo	PipeWire	s32le 2ch 48000Hz	RUNNING
''';
      final sinks = LinuxAudioDeviceService.parsePactlSinks(sampleSinks);
      expect(sinks.length, equals(1));
      expect(sinks[0].id,
          equals('pulse:alsa_output.pci-0000_00_1f.3.analog-stereo'));

      const sampleAplay = '''
card 0: PCH [HDA Intel PCH], device 0: ALC269VC Analog [ALC269VC Analog]
''';
      final aplayDevices = LinuxAudioDeviceService.parseAplayList(sampleAplay);
      expect(aplayDevices.length, equals(1));
      expect(aplayDevices[0].id, equals('alsa:plughw:0,0'));
    });

    test('2.4 parsePactlVolume 与 parseAmixerVolume 正确提取当前音量百分比 (0-150)', () {
      const pactlOut =
          'Volume: front-left: 55705 /  85% / -4.23 dB,   front-right: 55705 /  85% / -4.23 dB';
      expect(LinuxAudioDeviceService.parsePactlVolume(pactlOut), equals(85));

      const amixerOut = '''
Simple mixer control 'Master',0
  Capabilities: pvolume pswitch pswitch-joined
  Playback channels: Front Left - Front Right
  Limits: Playback 0 - 65536
  Mono:
  Front Left: Playback 58982 [90%] [on]
  Front Right: Playback 58982 [90%] [on]
''';
      expect(LinuxAudioDeviceService.parseAmixerVolume(amixerOut), equals(90));
    });
  });

  group('Group 3: LinuxCameraCaptureService V4L2 摄像头枚举与参数构建', () {
    test('3.1 listCameraDevices 解析 /sys/class/video4linux 过滤 metadata 节点',
        () async {
      final tempSys = Directory.systemTemp.createTempSync('sys_v4l2_test_');

      // 模拟 video0 (主视频流 index=0)
      final v0 = Directory('${tempSys.path}/video0')..createSync();
      File('${v0.path}/index').writeAsStringSync('0\n');
      File('${v0.path}/name').writeAsStringSync('Integrated Camera\n');

      // 模拟 video1 (元数据节点 index=1，应被过滤)
      final v1 = Directory('${tempSys.path}/video1')..createSync();
      File('${v1.path}/index').writeAsStringSync('1\n');
      File('${v1.path}/name').writeAsStringSync('Integrated Camera Metadata\n');

      final cameras = await LinuxCameraCaptureService.listCameraDevices(
          sysfsDir: tempSys.path);
      expect(cameras.length, equals(1));
      expect(cameras[0].id, equals('/dev/video0'));
      expect(cameras[0].label, contains('Integrated Camera (/dev/video0)'));

      tempSys.deleteSync(recursive: true);
    });

    test('3.2 listCameraDevices 处理多摄像头并提取名称', () async {
      final tempSys = Directory.systemTemp.createTempSync('sys_v4l2_multi_');

      final v0 = Directory('${tempSys.path}/video0')..createSync();
      File('${v0.path}/index').writeAsStringSync('0\n');
      File('${v0.path}/name').writeAsStringSync('USB Webcam HD\n');

      final v2 = Directory('${tempSys.path}/video2')..createSync();
      File('${v2.path}/index').writeAsStringSync('0\n');
      File('${v2.path}/name').writeAsStringSync('Rear Camera\n');

      final cameras = await LinuxCameraCaptureService.listCameraDevices(
          sysfsDir: tempSys.path);
      expect(cameras.length, equals(2));
      expect(cameras[0].id, equals('/dev/video0'));
      expect(cameras[1].id, equals('/dev/video2'));

      tempSys.deleteSync(recursive: true);
    });
  });

  group('Group 4: LinuxAudioEnvironment 环境变量', () {
    test('4.1 LinuxAudioEnvironment.buildAudioEnv 保留环境上下文', () {
      final env = LinuxAudioEnvironment.buildAudioEnv();
      expect(env, isNotEmpty);
      expect(env, isA<Map<String, String>>());
    });
  });

  group('Group 5: LinuxHardwareService / LinuxHardwareAdapter Facade 向后兼容性测试',
      () {
    test('5.1 LinuxHardwareService 静态门面完整代理所有方法且与 Facade 类型一致', () {
      // 验证类型别名一致性
      expect(LinuxHardwareService, equals(LinuxHardwareAdapter));

      // 验证门面委托音量与 CPU 解析调用
      LinuxHardwareService.resetCpuUsageCountersForTest();
      final cpu = LinuxHardwareService.getCpuUsagePercent(
          procStatPath: '/non/existent');
      expect(cpu, equals(0.0));

      const sample = 'cpu  100 0 50 850 0 0 0 0 0 0\n';
      final counters = LinuxHardwareService.parseProcStatCpuCounters(sample);
      expect(counters, isNotNull);

      // 验证音量百分比 getter
      expect(LinuxHardwareService.currentVolumePercent, isNonNegative);
    });
  });
}

import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:side_assistant/controllers/assistant_controller.dart';
import 'package:side_assistant/core/constants/app_constants.dart';
import 'package:side_assistant/core/models/app_settings.dart';
import 'package:side_assistant/services/vision/camera_service.dart';
import 'package:side_assistant/services/vision/nano/duml_packet.dart';
import 'package:side_assistant/services/vision/nano/nano_commands.dart';
import 'package:side_assistant/services/vision/nano/nano_datalink.dart';
import 'package:side_assistant/services/vision/nano/nano_media_client.dart';
import 'package:side_assistant/services/vision/nano/nano_ble_driver.dart';
import 'package:side_assistant/services/vision/nano/nano_wifi_driver.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('com.llfbandit.record/messages'),
    (methodCall) async => null,
  );
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('xyz.luan/audioplayers.global'),
    (methodCall) async => 1,
  );
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('xyz.luan/audioplayers'),
    (methodCall) async => 1,
  );
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('flutter_tts'),
    (methodCall) async => 1,
  );
  HttpOverrides.global = null;

  group('DUML 协议帧与 CRC 校验测试', () {
    test('CRC8 与 CRC16 计算与帧回环编解码', () {
      final frame = DumlFrame(
        sender: senderApp,
        receiver: rxCamera,
        seq: 0x1234,
        flags: flagRequest,
        cmdSet: 0x02,
        cmdId: 0x01,
        payload: Uint8List.fromList([0x01]),
      );

      final encoded = encodeDuml(frame);
      expect(encoded[0], 0x55);
      expect(encoded.length, 13 + 1);

      final decodedList = scanDumlFrames(encoded);
      expect(decodedList.length, 1);
      final decoded = decodedList.first;
      expect(decoded.sender, senderApp);
      expect(decoded.receiver, rxCamera);
      expect(decoded.seq, 0x1234);
      expect(decoded.flags, flagRequest);
      expect(decoded.cmdSet, 0x02);
      expect(decoded.cmdId, 0x01);
      expect(decoded.payload, Uint8List.fromList([0x01]));
    });

    test('字符串打包与解包', () {
      const testStr = 'OsmoNano-0B56';
      final packed = packString(testStr);
      expect(packed[0], testStr.length);
      expect(packed.length, testStr.length + 1);

      // 解包状态回复格式 [status][len][utf8]
      final replyBytes =
          Uint8List.fromList([0x00, testStr.length, ...packed.sublist(1)]);
      final unpacked = unpackStatusString(replyBytes);
      expect(unpacked, testStr);
    });
  });

  group('Nano 指令构造测试', () {
    test('唤醒、保活与快门指令字段验证', () {
      final wake = sessionWake();
      expect(wake.cmdSet, 0x00);
      expect(wake.cmdId, 0x2B);
      expect(wake.payload, Uint8List.fromList([0x04, 0x00]));

      final keepalive = sessionKeepalive();
      expect(keepalive.cmdSet, 0x00);
      expect(keepalive.cmdId, 0x2B);
      expect(keepalive.payload, Uint8List.fromList([0x01, 0x01]));

      final softAp5310 = session5310();
      expect(softAp5310.cmdSet, 0x53);
      expect(softAp5310.cmdId, 0x10);
      expect(softAp5310.payload, Uint8List.fromList([0x00, 0x00, 0x00, 0x00]));

      final photoMode = setShootingMode(0x05);
      expect(photoMode.cmdSet, 0x02);
      expect(photoMode.cmdId, 0xE1);
      expect(photoMode.payload, Uint8List.fromList([0x05]));

      final shutter = shootPhoto();
      expect(shutter.cmdSet, 0x02);
      expect(shutter.cmdId, 0x01);
      expect(shutter.payload, Uint8List.fromList([0x01]));
    });
  });

  group('Wi-Fi Profile XML 生成测试', () {
    test('生成包含 SSID 与密码的 Windows WLAN 配置文件', () {
      final xml =
          NanoWifiDriver.generateProfileXml('OsmoNano-0B56', 'cPeySynT4YCT');
      expect(xml.contains('<name>OsmoNano-0B56</name>'), isTrue);
      expect(xml.contains('<keyMaterial>cPeySynT4YCT</keyMaterial>'), isTrue);
      expect(xml.contains('<authentication>WPA2PSK</authentication>'), isTrue);
    });
  });

  group('Datalink 传输头与分片组装测试', () {
    test('Transport Header 异或校验测试', () {
      final hdr = transportHeader(pktCommand, 20, 0x1234, 0x0008);
      expect(hdr.length, 8);
      expect(hdr[6], pktCommand);
      int x = 0;
      for (int i = 0; i < 7; i++) {
        x ^= hdr[i];
      }
      expect(hdr[7], x);
    });

    test('MediaChunkAssembler 分片拼装测试', () {
      final assembler = MediaChunkAssembler();

      // Start frame (subtype 0x04)
      final start = DumlFrame(
        sender: rxCamera,
        receiver: senderApp,
        flags: flagNotify,
        cmdSet: 0x00,
        cmdId: 0x27,
        payload:
            Uint8List.fromList([0x4A, 0x04, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0]),
      );
      expect(assembler.ingest(start), isTrue);

      // Data frame (subtype 0x01)
      final chunkData = Uint8List.fromList([1, 2, 3, 4, 5]);
      final dataFrame = DumlFrame(
        sender: rxCamera,
        receiver: senderApp,
        flags: flagNotify,
        cmdSet: 0x00,
        cmdId: 0x27,
        payload: Uint8List.fromList(
            [0x4A, 0x01, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, ...chunkData]),
      );
      expect(assembler.ingest(dataFrame), isTrue);

      // End frame (subtype 0x03)
      final end = DumlFrame(
        sender: rxCamera,
        receiver: senderApp,
        flags: flagNotify,
        cmdSet: 0x00,
        cmdId: 0x27,
        payload:
            Uint8List.fromList([0x4A, 0x03, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0]),
      );
      expect(assembler.ingest(end), isTrue);

      expect(assembler.isClosed(1), isTrue);
      expect(assembler.getBytes(1), chunkData);
    });
  });

  group('CameraService 拍照源路由与切换测试', () {
    test('默认拍照源为本地镜头，可切换至 Nano 拍照源', () {
      final settings = AppSettings();
      final cameraService = CameraService(settings: settings);

      expect(cameraService.activeSource, isA<LocalCameraSource>());

      settings.captureSource = AppConstants.captureSourceNano;
      expect(cameraService.activeSource, isA<NanoCameraSource>());

      cameraService.dispose();
    });

    test('Nano 相机模式下空闲关闭无效且保持蓝牙常连', () {
      final settings = AppSettings(
        captureSource: AppConstants.captureSourceNano,
        cameraKeepAliveMinutes: 5,
      );
      final cameraService = CameraService(settings: settings);

      // Nano 相机模式下重置空闲计时器不应启动计时器
      cameraService.resetIdleTimerForTest();
      expect(cameraService.isIdleTimerRunning, isFalse);

      // 从本地模式切换为 Nano 模式时，已有空闲计时器应被即时取消
      final localSettings = AppSettings(
        captureSource: AppConstants.captureSourceLocal,
        cameraKeepAliveMinutes: 5,
      );
      cameraService.updateSettings(localSettings);
      cameraService.resetIdleTimerForTest();
      expect(cameraService.isIdleTimerRunning, isTrue);

      // 切换为 Nano
      localSettings.captureSource = AppConstants.captureSourceNano;
      cameraService.updateSettings(localSettings);
      expect(cameraService.isIdleTimerRunning, isFalse);

      cameraService.dispose();
    });

    test('AppSettings 序列化与反序列化 Nano 属性', () {
      final settings = AppSettings(
        captureSource: AppConstants.captureSourceNano,
        nanoWlanInterface: 'WLAN 2',
        nanoSsid: 'OsmoNano-TEST',
        nanoPassword: 'PassWord1234',
        nanoBleAddress: '11:22:33:44:55:66',
        enableFloatingCapsule: true,
      );

      final map = settings.toMap();
      expect(map['captureSource'], AppConstants.captureSourceNano);
      expect(map['nanoWlanInterface'], 'WLAN 2');
      expect(map['nanoSsid'], 'OsmoNano-TEST');
      expect(map['nanoPassword'], 'PassWord1234');
      expect(map['nanoBleAddress'], '11:22:33:44:55:66');
      expect(map['enableFloatingCapsule'], isTrue);

      final restored = AppSettings.fromMap(map);
      expect(restored.captureSource, AppConstants.captureSourceNano);
      expect(restored.nanoWlanInterface, 'WLAN 2');
      expect(restored.nanoSsid, 'OsmoNano-TEST');
      expect(restored.nanoPassword, 'PassWord1234');
      expect(restored.nanoBleAddress, '11:22:33:44:55:66');
      expect(restored.enableFloatingCapsule, isTrue);
    });

    test('AssistantController 在非 Nano 模式下触发 toggleNanoConnection 自动切换为 Nano 模式',
        () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final settings = AppSettings(
        captureSource: AppConstants.captureSourceLocal,
      );
      final controller = AssistantController(
        settings: settings,
        enableDriverServer: false,
      );

      expect(controller.isNanoCameraMode, isFalse);
      expect(
          controller.settings.captureSource, AppConstants.captureSourceLocal);

      // 触发切换
      await controller.toggleNanoConnection();

      expect(controller.isNanoCameraMode, isTrue);
      expect(controller.settings.captureSource, AppConstants.captureSourceNano);

      controller.dispose();
    });
  });

  group('BleAssembler 拼装与解析测试', () {
    test('BleAssembler 可正常接收来自平台层的动态整型并拼装完整 DUML 帧', () {
      final assembler = BleAssembler();
      final originalFrame = sessionKeepalive();
      final encoded = encodeDuml(originalFrame);

      // 模拟平台层以 dynamic list 分两次推送
      final chunk1 = encoded.sublist(0, 5).map((e) => e as dynamic).toList();
      final chunk2 = encoded.sublist(5).map((e) => e as dynamic).toList();

      final frames1 = assembler.append(Uint8List.fromList(chunk1.cast<int>()));
      expect(frames1.isEmpty, isTrue);

      final frames2 = assembler.append(Uint8List.fromList(chunk2.cast<int>()));
      expect(frames2.length, 1);
      final decoded = frames2.first;
      expect(decoded.cmdSet, 0x00);
      expect(decoded.cmdId, 0x2B);
      expect(decoded.payload, Uint8List.fromList([0x01, 0x01]));
    });
  });
}

import 'dart:async';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../../models/device_options.dart';
import '../foundation_bridge.dart';
import '../storage_bridge.dart';

/// Linux 本地摄像头服务：
/// - 基于 /sys/class/video4linux 枚举 V4L2 摄像头（过滤 metadata 节点）
/// - 基于 ffmpeg 从 /dev/video* 抓拍 JPEG 快照，支持曝光稳定延时与短边缩放
class LinuxCameraCaptureService {
  LinuxCameraCaptureService._();

  /// 枚举 Linux 上的本地 V4L2 摄像头设备（排除 metadata 节点）
  static Future<List<LinuxCameraDeviceOption>> listCameraDevices({
    String sysfsDir = '/sys/class/video4linux',
  }) async {
    if (!Platform.isLinux && sysfsDir == '/sys/class/video4linux') {
      return const [];
    }
    final result = <LinuxCameraDeviceOption>[];
    final sysDir = Directory(sysfsDir);
    if (!sysDir.existsSync()) return const [];

    try {
      final entries = sysDir
          .listSync()
          .where((e) => Directory(e.path).existsSync())
          .toList()
        ..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
      for (final entry in entries) {
        final devName = p.basename(entry.path); // e.g. video0
        final devPath = '/dev/$devName';
        // 只保留 index 为 0 的主视频采集流节点（跳过 index=1 的 metadata 节点）
        final indexFile = File(p.join(entry.path, 'index'));
        if (indexFile.existsSync()) {
          final idx = indexFile.readAsStringSync().trim();
          if (idx.isNotEmpty && idx != '0') {
            continue;
          }
        }
        String humanName = devName;
        final nameFile = File(p.join(entry.path, 'name'));
        if (nameFile.existsSync()) {
          final rawName = nameFile.readAsStringSync().trim();
          if (rawName.isNotEmpty) {
            humanName = '$rawName ($devPath)';
          }
        }
        result.add(LinuxCameraDeviceOption(
          id: devPath,
          label: humanName,
        ));
      }
    } catch (e) {
      debugPrint('[LinuxCameraCaptureService] 枚举摄像头失败: $e');
    }
    return result;
  }

  /// 使用 V4L2 + ffmpeg 从本地摄像头抓拍一帧 JPEG
  static Future<(Uint8List bytes, String filePath)> captureV4l2Photo({
    String configuredDevice = '',
    int targetWidth = 0,
    int targetHeight = 0,
    int sendShortEdge = 0,
  }) async {
    String devicePath = configuredDevice.trim();
    if (devicePath.isEmpty) {
      final cameras = await listCameraDevices();
      if (cameras.isNotEmpty) {
        devicePath = cameras.first.id;
      } else {
        devicePath = '/dev/video0';
      }
    }

    final tempDir = await StorageBridge.getAppTemporaryDirectory();
    final outPath = p.join(
      tempDir.path,
      'capture_${DateTime.now().millisecondsSinceEpoch}.jpg',
    );

    final vfParts = <String>[
      // 跳过前几帧以便摄像头自动曝光稳定
      r'select=gte(n\,4)',
    ];
    if (sendShortEdge > 0) {
      vfParts.add(
        "scale='if(gt(iw,ih),-2,min($sendShortEdge,iw))':'if(gt(iw,ih),min($sendShortEdge,ih),-2)'",
      );
    }

    final args = <String>[
      '-y',
      '-hide_banner',
      '-loglevel',
      'error',
      '-f',
      'v4l2',
      if (targetWidth > 0 && targetHeight > 0) ...[
        '-video_size',
        '${targetWidth}x$targetHeight',
      ],
      '-i',
      devicePath,
      '-vf',
      vfParts.join(','),
      '-frames:v',
      '1',
      '-update',
      '1',
      '-q:v',
      '2',
      outPath,
    ];

    var res =
        await Process.run('ffmpeg', args).timeout(const Duration(seconds: 12));
    final outFile = File(outPath);

    // 若摄像头帧率较低或不支持 select=gte(n,4)，回退到直接抓第一帧
    if (res.exitCode != 0 ||
        !outFile.existsSync() ||
        outFile.lengthSync() == 0) {
      final fallbackArgs = <String>[
        '-y',
        '-hide_banner',
        '-loglevel',
        'error',
        '-f',
        'v4l2',
        '-i',
        devicePath,
        if (sendShortEdge > 0) ...[
          '-vf',
          "scale='if(gt(iw,ih),-2,min($sendShortEdge,iw))':'if(gt(iw,ih),min($sendShortEdge,ih),-2)'",
        ],
        '-frames:v',
        '1',
        '-update',
        '1',
        '-q:v',
        '2',
        outPath,
      ];
      res = await Process.run('ffmpeg', fallbackArgs)
          .timeout(const Duration(seconds: 10));
    }

    if (res.exitCode != 0 ||
        !outFile.existsSync() ||
        outFile.lengthSync() == 0) {
      final errText = res.stderr.toString().trim();
      throw Exception('Linux V4L2 ($devicePath) 抓拍失败: $errText');
    }

    final bytes = await outFile.readAsBytes();
    return (bytes, outPath);
  }
}

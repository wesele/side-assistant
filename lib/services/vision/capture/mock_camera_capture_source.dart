import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../../../core/platform/storage_bridge.dart';
import '../android_camera_bridge.dart';
import 'camera_capture_source.dart';

/// 专用于 CI / 自动化测试与无硬件环境的模拟相机捕获策略
class MockCameraCaptureSource implements CameraCaptureSource {
  static final Uint8List minimalJpegBytes = Uint8List.fromList([
    0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01,
    0x01, 0x01, 0x00, 0x48, 0x00, 0x48, 0x00, 0x00, 0xFF, 0xDB, 0x00, 0x43,
    0x00, 0x08, 0x06, 0x06, 0x07, 0x06, 0x05, 0x08, 0x07, 0x07, 0x07, 0x09,
    0x09, 0x08, 0x0A, 0x0C, 0x14, 0x0D, 0x0C, 0x0B, 0x0B, 0x0C, 0x19, 0x12,
    0x13, 0x0F, 0x14, 0x1D, 0x1A, 0x1F, 0x1E, 0x1D, 0x1A, 0x1C, 0x1C, 0x20,
    0x24, 0x2E, 0x27, 0x20, 0x22, 0x2C, 0x23, 0x1C, 0x1C, 0x28, 0x37, 0x29,
    0x2C, 0x30, 0x31, 0x34, 0x34, 0x34, 0x1F, 0x27, 0x39, 0x3D, 0x38, 0x32,
    0x3C, 0x2E, 0x33, 0x34, 0x32, 0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x01,
    0x00, 0x01, 0x01, 0x01, 0x11, 0x00, 0xFF, 0xC4, 0x00, 0x1F, 0x00, 0x00,
    0x01, 0x05, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
    0x09, 0x0A, 0x0B, 0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F,
    0x00, 0x7F, 0x00, 0xFF, 0xD9
  ]);

  final Uint8List _customBytes;
  final String? _customPath;
  final bool _simulateAvailability;
  bool _isOpen = false;
  StreamController<CameraFrame>? _previewController;

  MockCameraCaptureSource({
    Uint8List? customBytes,
    String? customPath,
    bool simulateAvailability = true,
  })  : _customBytes = customBytes ?? minimalJpegBytes,
        _customPath = customPath,
        _simulateAvailability = simulateAvailability;

  @override
  CameraSourceType get type => CameraSourceType.mock;

  @override
  bool get isAvailable => _simulateAvailability;

  @override
  bool get isOpen => _isOpen;

  @override
  Stream<CameraFrame>? get previewStream {
    _previewController ??= StreamController<CameraFrame>.broadcast();
    return _previewController?.stream;
  }

  /// 模拟向预览流中注入一帧画面
  void emitPreviewFrame(CameraFrame frame) {
    if (_previewController != null && !_previewController!.isClosed) {
      _previewController!.add(frame);
    }
  }

  @override
  Future<void> initialize() async {
    _isOpen = true;
  }

  @override
  Future<bool> ensureOpen() async {
    _isOpen = true;
    return true;
  }

  @override
  Future<CameraCaptureResult> captureFrame({CameraResolution? resolution}) async {
    _isOpen = true;
    String filePath = _customPath ?? '';
    if (filePath.isEmpty) {
      try {
        final tempDir = await StorageBridge.getAppTemporaryDirectory();
        final file = File(
            '${tempDir.path}/mock_camera_${DateTime.now().millisecondsSinceEpoch}.jpg');
        await file.writeAsBytes(_customBytes);
        filePath = file.path;
      } catch (_) {
        filePath = '';
      }
    }

    return CameraCaptureResult(
      imageBytes: _customBytes,
      filePath: filePath,
      isSimulated: true,
      sourceType: CameraSourceType.mock,
      metadata: {
        'resolution': resolution?.label ?? '1x1 (Mock)',
        'timestamp': DateTime.now().toIso8601String(),
      },
    );
  }

  @override
  Future<CameraCaptureResult> capturePhoto() => captureFrame();

  @override
  Future<void> close() async {
    _isOpen = false;
  }

  @override
  Future<void> dispose() async {
    await close();
    await _previewController?.close();
    _previewController = null;
  }
}

import 'dart:typed_data';

enum CameraLensDirection { front, back, external }

enum ResolutionPreset { low, medium, high, veryHigh, ultraHigh, max }

enum ImageFormatGroup { unknown, yuv420, bgra8888, jpeg, nv21 }

class CameraDescription {
  final String name;
  final CameraLensDirection lensDirection;
  final int sensorOrientation;

  const CameraDescription({
    required this.name,
    required this.lensDirection,
    required this.sensorOrientation,
  });
}

class CameraValue {
  final bool isInitialized;
  const CameraValue({this.isInitialized = false});
}

class XFile {
  final String path;
  const XFile(this.path);
  Future<Uint8List> readAsBytes() async => Uint8List(0);
}

class CameraController {
  final CameraDescription description;
  final ResolutionPreset resolutionPreset;
  final bool enableAudio;
  final ImageFormatGroup? imageFormatGroup;

  CameraValue value = const CameraValue(isInitialized: false);

  CameraController(
    this.description,
    this.resolutionPreset, {
    this.enableAudio = true,
    this.imageFormatGroup,
  });

  Future<void> initialize() async {}
  Future<XFile> takePicture() async => const XFile('');
  Future<void> dispose() async {}
}

Future<List<CameraDescription>> availableCameras() async => const [];

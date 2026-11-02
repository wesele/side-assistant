import 'dart:typed_data';

import '../models/app_settings.dart';
import 'speaker_verification_port.dart';

/// 目标说话人语音抽取服务端口 (Target Speaker Extraction Port)
abstract interface class TargetSpeakerExtractionPort {
  bool get hasEnrolledOwner;
  dynamic extractTargetSpeaker(Float32List audio);
}

/// 目标说话人抽取服务 SPI 工厂注册表
class TargetSpeakerExtractionFactoryRegistry {
  static TargetSpeakerExtractionPort Function(
    AppSettings settings,
    SpeakerVerifierPort? speakerVerificationService,
  )? defaultFactory;
}

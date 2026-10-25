import 'dart:io';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/widgets.dart' show WidgetsBinding;
export 'package:flutter/foundation.dart';
export 'dart:typed_data';

bool get isAndroidPlatform => defaultTargetPlatform == TargetPlatform.android;

bool get isRunningInFlutterTest {
  if (Platform.environment.containsKey('FLUTTER_TEST')) return true;
  try {
    final bindingName = WidgetsBinding.instance.runtimeType.toString();
    if (bindingName.contains('Test') || bindingName.contains('Automated')) {
      return true;
    }
  } catch (_) {}
  return false;
}

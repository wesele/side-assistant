import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';

/// Android 自动定位：获取当前坐标并反向地理编码为地址文本。
/// 其他平台返回 null，由调用方使用设置里配置的地址。
class LocationBridge {
  static String? _cached;
  static DateTime? _cachedAt;
  static const Duration _cacheTtl = Duration(minutes: 10);

  static Future<String?> getCurrentAddress() async {
    if (!Platform.isAndroid) return null;
    final at = _cachedAt;
    if (_cached != null &&
        at != null &&
        DateTime.now().difference(at) < _cacheTtl) {
      return _cached;
    }
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return _cached;
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        return _cached;
      }

      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 6),
        ),
      ).catchError((_) async {
        final last = await Geolocator.getLastKnownPosition();
        if (last == null) throw StateError('no position');
        return last;
      });

      String text =
          '${pos.latitude.toStringAsFixed(5)}, ${pos.longitude.toStringAsFixed(5)}';
      try {
        final marks =
            await placemarkFromCoordinates(pos.latitude, pos.longitude)
                .timeout(const Duration(seconds: 4));
        if (marks.isNotEmpty) {
          final m = marks.first;
          final parts = <String>[
            m.street ?? '',
            m.subLocality ?? '',
            '${m.postalCode ?? ''} ${m.locality ?? ''}'.trim(),
            m.administrativeArea ?? '',
            m.country ?? '',
          ].where((s) => s.trim().isNotEmpty).toList();
          if (parts.isNotEmpty) {
            text = '${parts.join(', ')}（坐标 $text）';
          }
        }
      } catch (e) {
        debugPrint('[LocationBridge] 反向地理编码失败: $e');
      }
      _cached = text;
      _cachedAt = DateTime.now();
      return text;
    } catch (e) {
      debugPrint('[LocationBridge] 定位失败: $e');
      return _cached;
    }
  }
}

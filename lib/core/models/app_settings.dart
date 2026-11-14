import 'dart:convert';
import 'dart:io';
import '../platform/storage_bridge.dart';
import 'domain_configs.dart';
import 'gemini_api_key_entry.dart';

export 'domain_configs.dart';
export 'gemini_api_key_entry.dart';

part 'app_settings.g.dart';

/// 别名：遵循目标架构四层整洁架构的领域配置命名
typedef AppConfig = AppSettings;

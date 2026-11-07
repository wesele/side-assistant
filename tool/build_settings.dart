import 'dart:io';
import 'package:path/path.dart' as p;

/// 领域配置代码生成器 (Settings Facade Generator)
///
/// 功能：
/// 1. 解析 lib/core/models/domain_configs.dart 中的 5 大领域配置类：
///    - AudioConfig (audio)
///    - LlmConfig (llm)
///    - TtsConfig (tts)
///    - VisionConfig (vision)
///    - ServerConfig (server)
/// 2. 自动生成 lib/core/models/app_settings.g.dart，提供：
///    - 扁平构造参数及领域分发
///    - 领域属性代理 getter / setter
///    - toMap / fromMap 序列化
///    - copyWithMap / applyMap 增量更新方法
///    - 持久化 save / load 方法
/// 3. 使新增或修改配置项时，仅需在 domain_configs.dart 中维护领域类，
///    门面层完全自动派生，彻底根治霰弹式修改。
void main(List<String> args) {
  final projectRoot = Directory.current.path;
  final domainConfigsFile = File(
    p.join(projectRoot, 'lib', 'core', 'models', 'domain_configs.dart'),
  );
  final targetFile = File(
    p.join(projectRoot, 'lib', 'core', 'models', 'app_settings.g.dart'),
  );

  if (!domainConfigsFile.existsSync()) {
    stderr.writeln('❌ 找不到源文件: ${domainConfigsFile.path}');
    exit(1);
  }

  final source = domainConfigsFile.readAsStringSync();
  final generated = generateAppSettingsCode(source);

  targetFile.writeAsStringSync(generated);
  stdout.writeln('✅ 已成功生成: ${p.relative(targetFile.path, from: projectRoot)}');
}

/// 用官方 `dart format` 将生成源码收敛为格式化态，保证「生成 → 比对」闭环一致。
///
/// [generateAppSettingsCode] 被 `tool/check_deps.dart` 直接调用来做字符串比对，
/// 若只格式化写盘后的文件，比对时必然不一致；因此把格式化收敛进返回值本身。
/// `dart format` 没有同步 stdin 入口，这里用临时文件 + [Process.runSync] 实现，
/// 从而保持本函数同步、可被纯同步调用方复用。
String formatDartSource(String source) {
  final tempDir = Directory.systemTemp.createTempSync('side_assistant_fmt_');
  try {
    final tempFile = File(p.join(tempDir.path, 'generated.dart'));
    tempFile.writeAsStringSync(source);
    final result = Process.runSync('dart', ['format', tempFile.path]);
    if (result.exitCode != 0) {
      throw StateError('dart format 执行失败: ${result.stderr}');
    }
    return tempFile.readAsStringSync();
  } finally {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  }
}

class DomainField {
  final String type;
  final String name;

  const DomainField(this.type, this.name);
}

class DomainClassMeta {
  final String className;
  final String propName;
  final String defaultInst;
  final List<DomainField> fields;
  final List<DomainField> extraConstructorParams;

  const DomainClassMeta({
    required this.className,
    required this.propName,
    required this.defaultInst,
    required this.fields,
    this.extraConstructorParams = const [],
  });
}

String generateAppSettingsCode(String domainConfigsSource) {
  final domainClasses = <DomainClassMeta>[
    DomainClassMeta(
      className: 'AudioConfig',
      propName: 'audio',
      defaultInst: 'const AudioConfig()',
      fields: _extractFields(domainConfigsSource, 'AudioConfig'),
      extraConstructorParams: const [
        DomainField('bool', 'enableStartWordDetection'),
      ],
    ),
    DomainClassMeta(
      className: 'LlmConfig',
      propName: 'llm',
      defaultInst: 'LlmConfig()',
      fields: _extractFields(domainConfigsSource, 'LlmConfig'),
    ),
    DomainClassMeta(
      className: 'TtsConfig',
      propName: 'tts',
      defaultInst: 'const TtsConfig()',
      fields: _extractFields(domainConfigsSource, 'TtsConfig'),
    ),
    DomainClassMeta(
      className: 'VisionConfig',
      propName: 'vision',
      defaultInst: 'const VisionConfig()',
      fields: _extractFields(domainConfigsSource, 'VisionConfig'),
    ),
    DomainClassMeta(
      className: 'ServerConfig',
      propName: 'server',
      defaultInst: 'ServerConfig(autoStartMicOnLaunch: Platform.isLinux)',
      fields: _extractFields(domainConfigsSource, 'ServerConfig'),
    ),
  ];

  final buffer = StringBuffer();
  buffer.writeln('// GENERATED CODE - DO NOT MODIFY BY HAND');
  buffer.writeln('// Generator: tool/build_settings.dart');
  buffer.writeln();
  buffer.writeln("part of 'app_settings.dart';");
  buffer.writeln();
  buffer.writeln('/// 统一配置对象（领域化拆分 + 平坦持久化兼容）');
  buffer.writeln('///');
  buffer.writeln('/// 遵循六边形架构与 AGENTS.md 规范：');
  buffer.writeln(
      '/// 1. 内存中领域化隔离：拆分为 [audio]、[llm]、[tts]、[vision]、[server] 五大领域子配置；');
  buffer.writeln(
      '/// 2. 外部持久化 100% 平坦兼容：[toMap] 与 [fromMap] 完全兼容既有 flat JSON 格式；');
  buffer.writeln('/// 3. 全局平滑向后兼容：保留全部扁平字段的 getter/setter，已有调用代码零改动。');
  buffer.writeln('class AppSettings {');
  buffer.writeln('  AudioConfig audio;');
  buffer.writeln('  LlmConfig llm;');
  buffer.writeln('  TtsConfig tts;');
  buffer.writeln('  VisionConfig vision;');
  buffer.writeln('  ServerConfig server;');
  buffer.writeln();

  // 构造函数
  buffer.writeln('  AppSettings({');
  buffer.writeln('    AudioConfig? audio,');
  buffer.writeln('    LlmConfig? llm,');
  buffer.writeln('    TtsConfig? tts,');
  buffer.writeln('    VisionConfig? vision,');
  buffer.writeln('    ServerConfig? server,');
  buffer.writeln('    // 兼容既有扁平参数初始化');
  for (final domain in domainClasses) {
    for (final field in domain.fields) {
      buffer.writeln('    ${field.type}? ${field.name},');
      if (field.name == 'startWordMode') {
        buffer.writeln('    bool? enableStartWordDetection,');
      }
    }
  }
  buffer.write('  })  : audio = (audio ?? const AudioConfig()).copyWith(');
  buffer.writeln();
  for (final field
      in domainClasses.firstWhere((d) => d.propName == 'audio').fields) {
    buffer.writeln('          ${field.name}: ${field.name},');
    if (field.name == 'startWordMode') {
      buffer.writeln(
          '          enableStartWordDetection: enableStartWordDetection,');
    }
  }
  buffer.writeln('        ),');

  for (final domain in domainClasses.skip(1)) {
    buffer.writeln(
        '        ${domain.propName} = (${domain.propName} ?? ${domain.defaultInst}).copyWith(');
    for (final field in domain.fields) {
      buffer.writeln('          ${field.name}: ${field.name},');
    }
    buffer.writeln('        )${domain == domainClasses.last ? ';' : ','}');
  }
  buffer.writeln();

  // 属性代理 (getters & setters)
  for (final domain in domainClasses) {
    buffer.writeln('  // --- ${domain.className} 属性代理 ---');
    for (final field in domain.fields) {
      buffer.writeln(
          '  ${field.type} get ${field.name} => ${domain.propName}.${field.name};');
      buffer.writeln(
          '  set ${field.name}(${field.type} v) => ${domain.propName} = ${domain.propName}.copyWith(${field.name}: v);');
      buffer.writeln();

      if (field.name == 'startWordMode') {
        buffer.writeln(
            '  bool get enableStartWordDetection => audio.enableStartWordDetection;');
        buffer.writeln('  set enableStartWordDetection(bool v) =>');
        buffer.writeln(
            '      audio = audio.copyWith(enableStartWordDetection: v);');
        buffer.writeln();
      }
    }
  }

  // Audio 特殊派生 getters
  buffer.writeln('  bool get isGeminiLiveMode => audio.isGeminiLiveMode;');
  buffer.writeln('  List<String> get startWords => audio.startWords;');
  buffer.writeln('  List<String> get endWords => audio.endWords;');
  buffer.writeln('  List<String> get resetWords => audio.resetWords;');
  buffer.writeln(
      '  List<String> get exitContinuousWords => audio.exitContinuousWords;');
  buffer.writeln();
  buffer.writeln('  static List<String> splitTriggerWords(String raw) =>');
  buffer.writeln('      AudioConfig.splitTriggerWords(raw);');
  buffer.writeln();

  // toMap
  buffer.writeln('  /// 序列化为平坦 JSON Map（完全匹配 233 服务器 preferences.json）');
  buffer.writeln('  Map<String, dynamic> toMap() {');
  buffer.writeln('    return {');
  for (final domain in domainClasses) {
    buffer.writeln('      ...${domain.propName}.toMap(),');
  }
  buffer.writeln('    };');
  buffer.writeln('  }');
  buffer.writeln();

  // fromMap
  buffer.writeln('  /// 从平坦 JSON Map 解析构建领域化对象');
  buffer.writeln('  factory AppSettings.fromMap(Map<String, dynamic> map) {');
  buffer.writeln('    return AppSettings(');
  for (final domain in domainClasses) {
    buffer
        .writeln('      ${domain.propName}: ${domain.className}.fromMap(map),');
  }
  buffer.writeln('    );');
  buffer.writeln('  }');
  buffer.writeln();

  // copyWithMap & applyMap
  buffer.writeln('  /// 增量合并平坦配置字典，返回全新的不可变 AppSettings');
  buffer.writeln('  AppSettings copyWithMap(Map<String, dynamic> delta) {');
  buffer.writeln('    return AppSettings(');
  for (final domain in domainClasses) {
    buffer.writeln(
        '      ${domain.propName}: ${domain.propName}.copyWithMap(delta),');
  }
  buffer.writeln('    );');
  buffer.writeln('  }');
  buffer.writeln();
  buffer.writeln('  /// 局部增量就地更新配置');
  buffer.writeln('  void applyMap(Map<String, dynamic> delta) {');
  for (final domain in domainClasses) {
    buffer.writeln(
        '    ${domain.propName} = ${domain.propName}.copyWithMap(delta);');
  }
  buffer.writeln('  }');
  buffer.writeln();

  // 持久化逻辑
  buffer.writeln("  static const String _prefsKey = 'app_settings_data_v1';");
  buffer.writeln();
  buffer.writeln('  Future<void> save() async {');
  buffer.writeln(
      '    await StorageBridge.writePreferenceString(_prefsKey, jsonEncode(toMap()));');
  buffer.writeln('  }');
  buffer.writeln();
  buffer.writeln('  static Future<AppSettings> load() async {');
  buffer.writeln(
      '    final jsonStr = await StorageBridge.readPreferenceString(_prefsKey);');
  buffer.writeln('    if (jsonStr == null || jsonStr.isEmpty) {');
  buffer.writeln('      return AppSettings();');
  buffer.writeln('    }');
  buffer.writeln('    try {');
  buffer.writeln(
      '      final map = jsonDecode(jsonStr) as Map<String, dynamic>;');
  buffer.writeln('      return AppSettings.fromMap(map);');
  buffer.writeln('    } catch (_) {');
  buffer.writeln('      return AppSettings();');
  buffer.writeln('    }');
  buffer.writeln('  }');

  buffer.writeln('}');
  return formatDartSource(buffer.toString());
}

List<DomainField> _extractFields(String source, String className) {
  final classPattern = RegExp('class\\s+$className\\b[^{]*\\{');
  final match = classPattern.firstMatch(source);
  if (match == null) return [];

  final classStart = match.end;
  // 类字段均声明在构造函数之前
  final ctorIndex = source.indexOf('$className(', classStart);
  if (ctorIndex == -1) return [];

  final fieldsSection = source.substring(classStart, ctorIndex);
  final fieldRegex = RegExp(
      r'^\s*final\s+([A-Za-z0-9_<>,\s]+?)\s+([A-Za-z0-9_]+);',
      multiLine: true);
  final fields = <DomainField>[];
  for (final m in fieldRegex.allMatches(fieldsSection)) {
    final type = m.group(1)!.trim();
    final name = m.group(2)!.trim();
    fields.add(DomainField(type, name));
  }
  return fields;
}

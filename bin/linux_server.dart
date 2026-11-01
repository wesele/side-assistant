// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:io';
import 'package:side_assistant/core/di/app_container.dart';
import 'package:side_assistant/core/engine/assistant_engine.dart';
import 'package:side_assistant/core/models/app_settings.dart';
import 'package:side_assistant/core/platform/storage_bridge.dart';
import 'package:side_assistant/services/automation/app_driver_server.dart';
import 'package:side_assistant/services/speech/asr_engine_factory.dart';

void _printHelp() {
  print('''
SideAssistant Linux 无头语音视觉服务端 (Headless Server)

用法:
  dart run bin/linux_server.dart [选项]
  ./side_assistant_server [选项]

选项:
  --host=<IP>          监听地址 (默认: 0.0.0.0，可通过 SIDE_ASSISTANT_HOST 设置)
  --port=<PORT>        监听端口 (默认: 19823，可通过 SIDE_ASSISTANT_PORT 设置)
  --data-dir=<PATH>    配置与会话历史存储目录 (默认: ~/.local/share/side_assistant)
  --password=<PWD>     设置 Web 访问密码 (可通过 SIDE_ASSISTANT_PASSWORD 设置)
  --no-auto-mic        启动时不自动开启麦克风常驻监听
  -h, --help           显示此帮助信息
''');
}

Future<void> main(List<String> args) async {
  if (args.contains('-h') || args.contains('--help')) {
    _printHelp();
    return;
  }

  String host = Platform.environment['SIDE_ASSISTANT_HOST'] ?? '0.0.0.0';
  int port =
      int.tryParse(Platform.environment['SIDE_ASSISTANT_PORT'] ?? '') ?? 19823;
  String dataDir = Platform.environment['SIDE_ASSISTANT_DATA_DIR'] ?? '';
  String? passwordOverride = Platform.environment['SIDE_ASSISTANT_PASSWORD'];
  bool forceNoAutoMic = false;

  for (final arg in args) {
    if (arg.startsWith('--host=')) {
      host = arg.substring('--host='.length).trim();
    } else if (arg.startsWith('--port=')) {
      port = int.tryParse(arg.substring('--port='.length).trim()) ?? port;
    } else if (arg.startsWith('--data-dir=')) {
      dataDir = arg.substring('--data-dir='.length).trim();
    } else if (arg.startsWith('--password=')) {
      passwordOverride = arg.substring('--password='.length).trim();
    } else if (arg == '--no-auto-mic') {
      forceNoAutoMic = true;
    }
  }

  if (dataDir.isNotEmpty) {
    StorageBridge.configureCustomDataDir(dataDir);
  }

  print('============================================================');
  print('  SideAssistant Linux Server 正在启动...');
  print('  操作系统: ${Platform.operatingSystem} (${Platform.operatingSystemVersion})');
  print('  工作目录: ${Directory.current.path}');
  print('============================================================');

  final settings = await AppSettings.load();
  if (passwordOverride != null) {
    settings.webAccessPassword = passwordOverride;
    await settings.save();
  }

  AsrEngineFactory.registerDefault();
  final container = await AppContainer.initializeHeadlessServer(settings);
  final engine = container.get<AssistantEngine>();

  final bindAddr =
      host == '0.0.0.0' ? InternetAddress.anyIPv4 : InternetAddress(host);
  final server = AppDriverServer(
    driverPort: engine,
    port: port,
    bindAddress: bindAddr,
  );

  await server.start();
  if (!server.isRunning) {
    stderr.writeln('[ERROR] 无法绑定端口 $host:$port，请检查端口是否被占用。');
    exit(1);
  }

  print('[OK] Web 管理与对话控制台已启动: http://$host:$port');

  if (settings.autoStartMicOnLaunch && !forceNoAutoMic) {
    // 稍作延迟让 ASR 模型启动加载流程后再开启麦克风实时流
    Future<void>.delayed(const Duration(milliseconds: 600), () async {
      print('[INFO] 正在自动开启服务器端麦克风常驻唤醒监听...');
      final ok = await engine.voiceService.startContinuousListening();
      print(ok
          ? '[OK] 服务器麦克风常驻监听已开启（唤醒词: ${settings.startWord}，结束词: ${settings.endWord}）'
          : '[WARN] 服务器麦克风自动开启未成功，可在网页端检查录音设备');
    });
  } else {
    print('[INFO] 启动自动开启麦克风已设为关闭，可通过网页端随时开启。');
  }

  final completer = Completer<void>();

  Future<void> shutdown(String signalName) async {
    if (completer.isCompleted) return;
    print('\n[INFO] 收到 $signalName 信号，正在优雅关闭服务...');
    await server.stop();
    await engine.disposeAsync();
    completer.complete();
  }

  ProcessSignal.sigint.watch().listen((_) => shutdown('SIGINT'));
  if (!Platform.isWindows) {
    ProcessSignal.sigterm.watch().listen((_) => shutdown('SIGTERM'));
  }

  await completer.future;
  exit(0);
}

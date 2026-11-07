import 'dart:async';
import 'dart:io';
import '../../core/ports/assistant_driver_port.dart';
import 'http_router.dart';
import 'sse_client_manager.dart';
import 'handlers/web_console_handler.dart';
import 'handlers/state_metrics_handler.dart';
import 'handlers/chat_handler.dart';
import 'handlers/audio_handler.dart';
import 'handlers/device_handler.dart';
import 'handlers/tts_handler.dart';
import 'handlers/speaker_handler.dart';
import 'handlers/settings_handler.dart';
import 'handlers/session_handler.dart';
import 'handlers/diagnostics_handler.dart';
import 'handlers/custom_tools_handler.dart';

/// 自动化助手驱动 HTTP/SSE 传输服务：
/// 遵循六边形架构，面向 AssistantDriverPort 抽象，通过 HttpRouter 与 10 个领域处理器
/// 提供统一的 Web Console 与 REST/SSE 控制端点。
class AppDriverServer implements DriverServerPort {
  static void registerDefault() {
    DriverServerFactoryRegistry.defaultFactory =
        (driverPort) => AppDriverServer(driverPort: driverPort);
  }

  final AssistantDriverPort driverPort;
  AssistantDriverPort get controller => driverPort;
  final int port;
  final InternetAddress? bindAddress;

  HttpServer? _server;
  late final HttpRouter _router;
  late final SseClientManager _sseManager;
  late final StateMetricsHandler _stateMetricsHandler;
  bool _listenerAttached = false;
  Timer? _metricsTimer;

  AppDriverServer({
    AssistantDriverPort? controller,
    AssistantDriverPort? driverPort,
    this.port = 19823,
    this.bindAddress,
  }) : driverPort = (driverPort ?? controller)! {
    _initRouterAndHandlers();
  }

  void _initRouterAndHandlers() {
    _sseManager = SseClientManager();
    _router = HttpRouter(driverPort: driverPort);

    _stateMetricsHandler = StateMetricsHandler(
      driverPort: driverPort,
      sseManager: _sseManager,
      port: port,
    );

    // 注册 10 个高内聚领域处理器
    WebConsoleHandler(driverPort).registerRoutes(_router);
    _stateMetricsHandler.registerRoutes(_router);
    ChatHandler(driverPort).registerRoutes(_router);
    AudioHandler(driverPort).registerRoutes(_router);
    DeviceHandler(driverPort).registerRoutes(_router);
    TtsHandler(driverPort).registerRoutes(_router);
    SpeakerHandler(driverPort).registerRoutes(_router);
    SettingsHandler(driverPort).registerRoutes(_router);
    SessionHandler(driverPort).registerRoutes(_router);
    DiagnosticsHandler(driverPort).registerRoutes(_router);
    CustomToolsHandler(driverPort).registerRoutes(_router);
  }

  bool get isRunning => _server != null;

  @override
  Future<void> start() async {
    if (_server != null) return;
    try {
      final addr = bindAddress ??
          (Platform.isLinux
              ? InternetAddress.anyIPv4
              : InternetAddress.loopbackIPv4);
      _server = await HttpServer.bind(addr, port);
      if (!_listenerAttached) {
        controller.addListener(_broadcastSseState);
        _listenerAttached = true;
      }
      _metricsTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (_sseManager.hasClients) {
          _broadcastSseState();
        }
      });
      _server!.listen(_router.handle);
    } catch (_) {
      // 端口被占用或受限时静默处理，不影响主应用
    }
  }

  void _broadcastSseState() {
    if (!_sseManager.hasClients) return;
    final state = _stateMetricsHandler.buildFullStateMap();
    _sseManager.broadcast(state);
  }

  @override
  Future<void> stop() async {
    _metricsTimer?.cancel();
    _metricsTimer = null;
    if (_listenerAttached) {
      controller.removeListener(_broadcastSseState);
      _listenerAttached = false;
    }
    await _sseManager.closeAll();
    await _server?.close(force: true);
    _server = null;
  }
}

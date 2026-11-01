import '../http_router.dart';
import '../../../core/ports/assistant_driver_port.dart';

/// 领域路由处理器基类：
/// 各领域（Chat, Audio, Device, Settings...）处理器均继承此类，负责注册专属路由。
abstract class BaseHandler {
  final AssistantDriverPort driverPort;

  const BaseHandler(this.driverPort);

  void registerRoutes(HttpRouter router);
}

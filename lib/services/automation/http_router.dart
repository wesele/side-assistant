import 'dart:async';
import 'dart:io';
import '../../core/ports/assistant_driver_port.dart';
import 'request_context.dart';

typedef RouteHandler = FutureOr<void> Function(RequestContext context);

/// HTTP 路由条目定义
class HttpRoute {
  final String method;
  final String pathPattern;
  final bool requiresAuth;
  final RouteHandler handler;
  final RegExp? _regex;
  final List<String> _paramNames;

  HttpRoute({
    required this.method,
    required this.pathPattern,
    required this.handler,
    this.requiresAuth = true,
  })  : _paramNames = _extractParamNames(pathPattern),
        _regex = _compileRegex(pathPattern);

  static List<String> _extractParamNames(String pattern) {
    final names = <String>[];
    for (final segment in pattern.split('/')) {
      if (segment.startsWith(':')) {
        names.add(segment.substring(1));
      }
    }
    return names;
  }

  static RegExp? _compileRegex(String pattern) {
    if (!pattern.contains(':') && !pattern.endsWith('*')) return null;
    var regexStr = '^';
    final segments = pattern.split('/');
    for (var i = 0; i < segments.length; i++) {
      final s = segments[i];
      if (s.isEmpty && i == 0) continue;
      regexStr += '/';
      if (s.startsWith(':')) {
        regexStr += r'([^/]+)';
      } else if (s == '*') {
        regexStr += r'(.*)';
      } else {
        regexStr += RegExp.escape(s);
      }
    }
    regexStr += r'$';
    return RegExp(regexStr);
  }

  Map<String, String>? match(String reqMethod, String reqPath) {
    if (method != '*' && method != reqMethod.toUpperCase()) return null;
    if (_regex == null) {
      return pathPattern == reqPath ? const {} : null;
    }
    final match = _regex.firstMatch(reqPath);
    if (match == null) return null;
    final params = <String, String>{};
    for (var i = 0; i < _paramNames.length; i++) {
      params[_paramNames[i]] = match.group(i + 1) ?? '';
    }
    return params;
  }
}

/// 轻量级纯 Dart HTTP 路由与中间件调度器：
/// 负责 CORS 处理、OPTIONS 预检、鉴权拦截、路由匹配与全局错误边界捕获。
class HttpRouter {
  final AssistantDriverPort driverPort;
  final List<HttpRoute> _routes = [];

  HttpRouter({required this.driverPort});

  void get(String path, RouteHandler handler, {bool requiresAuth = true}) {
    addRoute('GET', path, handler, requiresAuth: requiresAuth);
  }

  void post(String path, RouteHandler handler, {bool requiresAuth = true}) {
    addRoute('POST', path, handler, requiresAuth: requiresAuth);
  }

  void addRoute(
    String method,
    String pathPattern,
    RouteHandler handler, {
    bool requiresAuth = true,
  }) {
    _routes.add(HttpRoute(
      method: method.toUpperCase(),
      pathPattern: pathPattern,
      handler: handler,
      requiresAuth: requiresAuth,
    ));
  }

  /// 校验请求是否满足 Web 访问鉴权密码
  bool checkAuthorized(HttpRequest request) {
    final requiredPwd = driverPort.settings.webAccessPassword.trim();
    if (requiredPwd.isEmpty) return true;

    final headerPwd = request.headers.value('x-access-password')?.trim() ?? '';
    if (headerPwd == requiredPwd) return true;

    final authHeader = request.headers.value('authorization')?.trim() ?? '';
    if (authHeader.startsWith('Bearer ') &&
        authHeader.substring(7).trim() == requiredPwd) {
      return true;
    }

    final queryToken = request.uri.queryParameters['token']?.trim() ?? '';
    if (queryToken == requiredPwd) return true;

    return false;
  }

  /// 统一处理流入的 HttpRequest
  Future<void> handle(HttpRequest request) async {
    // 1. CORS 响应头注入
    request.response.headers.add('Access-Control-Allow-Origin', '*');
    request.response.headers
        .add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    request.response.headers.add(
      'Access-Control-Allow-Headers',
      'Content-Type, Authorization, X-Access-Password',
    );

    if (request.method == 'OPTIONS') {
      request.response.statusCode = HttpStatus.ok;
      await request.response.close();
      return;
    }

    // 2. 路由匹配
    HttpRoute? matchedRoute;
    Map<String, String> pathParams = const {};
    final reqPath = request.uri.path;
    final reqMethod = request.method;

    for (final route in _routes) {
      final params = route.match(reqMethod, reqPath);
      if (params != null) {
        matchedRoute = route;
        pathParams = params;
        break;
      }
    }

    final ctx = RequestContext(
      request: request,
      driverPort: driverPort,
      pathParams: pathParams,
    );

    if (matchedRoute == null) {
      ctx.sendError('Not found', status: HttpStatus.notFound);
      return;
    }

    // 3. 鉴权管道拦截
    if (matchedRoute.requiresAuth && !checkAuthorized(request)) {
      ctx.sendError('Unauthorized', status: HttpStatus.unauthorized);
      return;
    }

    // 4. 执行路由处理器（带顶层 Error Boundary）
    try {
      await matchedRoute.handler(ctx);
    } catch (e) {
      try {
        ctx.sendError(e.toString(), status: HttpStatus.internalServerError);
      } catch (_) {}
    }
  }
}

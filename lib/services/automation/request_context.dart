import 'dart:convert';
import 'dart:io';
import '../../core/ports/assistant_driver_port.dart';

/// HTTP 请求上下文封装：
/// 隔离底层的 HttpRequest / HttpResponse，提供统一的参数解析与强类型响应助手方法。
class RequestContext {
  final HttpRequest request;
  final AssistantDriverPort driverPort;
  final Map<String, String> pathParams;

  RequestContext({
    required this.request,
    required this.driverPort,
    this.pathParams = const {},
  });

  HttpResponse get response => request.response;
  String get method => request.method;
  String get path => request.uri.path;
  Map<String, String> get queryParams => request.uri.queryParameters;
  Map<String, String> get params => pathParams;

  String? _cachedBodyString;
  Map<String, dynamic>? _cachedJsonMap;

  /// 异步读取请求体 UTF-8 字符串（带内存缓存）
  Future<String> readBodyString() async {
    _cachedBodyString ??= await utf8.decodeStream(request);
    return _cachedBodyString!;
  }

  /// 异步读取并解析 JSON 请求体（空体返回空 Map，非法 JSON 格式抛出异常由全局异常拦截器处理为 500）
  Future<Map<String, dynamic>> readJsonMap() async {
    if (_cachedJsonMap != null) return _cachedJsonMap!;
    final bodyStr = await readBodyString();
    if (bodyStr.trim().isEmpty) {
      _cachedJsonMap = <String, dynamic>{};
      return _cachedJsonMap!;
    }
    final decoded = jsonDecode(bodyStr);
    if (decoded is Map<String, dynamic>) {
      _cachedJsonMap = decoded;
      return decoded;
    }
    return <String, dynamic>{};
  }

  /// 发送 JSON 响应
  void sendJson(Map<String, dynamic> data, {int status = HttpStatus.ok}) {
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(data));
    response.close();
  }

  /// 发送 HTML 响应（带自定义响应头）
  void sendHtml(
    String html, {
    int status = HttpStatus.ok,
    Map<String, String>? headers,
  }) {
    response.statusCode = status;
    response.headers.contentType =
        ContentType('text', 'html', charset: 'utf-8');
    headers?.forEach((k, v) => response.headers.set(k, v));
    response.write(html);
    response.close();
  }

  /// 发送二进制字节流响应
  void sendBytes(
    List<int> bytes, {
    required ContentType contentType,
    int status = HttpStatus.ok,
  }) {
    response.statusCode = status;
    response.headers.contentType = contentType;
    response.add(bytes);
    response.close();
  }

  /// 发送统一格式的错误 JSON 响应
  void sendError(String message,
      {int status = HttpStatus.internalServerError}) {
    sendJson({'error': message}, status: status);
  }
}

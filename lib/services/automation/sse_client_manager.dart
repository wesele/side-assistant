import 'dart:convert';
import 'dart:io';

/// SSE (Server-Sent Events) 客户端连接与事件广播管理器：
/// 维护当前活跃的 SSE 客户端流，并在状态变更时进行并发安全广播与失联连接清理。
class SseClientManager {
  final Set<HttpResponse> _clients = <HttpResponse>{};

  bool get hasClients => _clients.isNotEmpty;
  int get clientCount => _clients.length;

  /// 添加新客户端连接，设置 SSE 响应头并推送初始全量状态
  void addClient(HttpResponse response, Map<String, dynamic> initialState) {
    response.statusCode = HttpStatus.ok;
    response.bufferOutput = false;
    response.headers.set('Content-Type', 'text/event-stream; charset=utf-8');
    response.headers.set('Cache-Control', 'no-cache');
    response.headers.set('Connection', 'keep-alive');
    response.write('data: ${jsonEncode(initialState)}\n\n');
    _clients.add(response);
    response.done.whenComplete(() {
      _clients.remove(response);
    });
  }

  /// 向所有当前已连接的活跃客户端广播最新状态
  void broadcast(Map<String, dynamic> stateMap) {
    if (_clients.isEmpty) return;
    final payload = 'data: ${jsonEncode(stateMap)}\n\n';
    final dead = <HttpResponse>[];
    for (final res in _clients) {
      try {
        res.write(payload);
      } catch (_) {
        dead.add(res);
      }
    }
    for (final d in dead) {
      _clients.remove(d);
    }
  }

  /// 优雅关闭所有存量客户端连接
  Future<void> closeAll() async {
    for (final client in _clients.toList()) {
      try {
        await client.close();
      } catch (_) {}
    }
    _clients.clear();
  }
}

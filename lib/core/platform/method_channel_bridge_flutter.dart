import 'package:flutter/services.dart';

class PlatformMethodCall {
  final String method;
  final dynamic arguments;
  const PlatformMethodCall(this.method, [this.arguments]);
}

class PlatformMethodChannel {
  final String name;
  const PlatformMethodChannel(this.name);

  MethodChannel get _channel => MethodChannel(name);

  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) {
    return _channel.invokeMethod<T>(method, arguments);
  }

  void setMethodCallHandler(
    Future<dynamic> Function(PlatformMethodCall call)? handler,
  ) {
    if (handler == null) {
      _channel.setMethodCallHandler(null);
    } else {
      _channel.setMethodCallHandler((call) {
        return handler(PlatformMethodCall(call.method, call.arguments));
      });
    }
  }
}

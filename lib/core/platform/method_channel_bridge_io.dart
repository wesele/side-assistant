class PlatformMethodCall {
  final String method;
  final dynamic arguments;
  const PlatformMethodCall(this.method, [this.arguments]);
}

class PlatformMethodChannel {
  final String name;
  const PlatformMethodChannel(this.name);

  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async => null;

  void setMethodCallHandler(
    Future<dynamic> Function(PlatformMethodCall call)? handler,
  ) {}
}

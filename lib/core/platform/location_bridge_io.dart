/// 纯 Dart（Linux 服务端 / 命令行）环境不支持自动定位，使用设置中配置的地址。
class LocationBridge {
  static Future<String?> getCurrentAddress() async => null;
}

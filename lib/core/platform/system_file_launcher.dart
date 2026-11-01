import 'dart:io';
import 'package:path/path.dart' as p;
import 'foundation_bridge.dart';
import 'method_channel_bridge.dart';
import 'storage_bridge.dart';

class SystemFileLauncher {
  static const PlatformMethodChannel _channel =
      PlatformMethodChannel('com.sideassistant.side_assistant/file_launcher');

  static bool get _isFlutterTest => isRunningInFlutterTest;

  /// 调用系统默认图片查看器打开本地图片文件。
  /// 返回 true 表示已成功拉起系统查看器；返回 false 表示未能拉起（调用方应回退到应用内全屏缩放查看器）。
  static Future<bool> openImageWithSystemViewer(String filePath) async {
    if (filePath.trim().isEmpty) return false;

    try {
      if (_isFlutterTest) {
        return false;
      }

      final file = File(filePath);
      if (!file.existsSync()) return false;

      if (Platform.isAndroid) {
        final ok = await _channel.invokeMethod<bool>(
          'openImage',
          {'path': file.absolute.path},
        );
        return ok == true;
      } else if (Platform.isWindows) {
        final res = await Process.run(
          'cmd',
          ['/c', 'start', '', file.absolute.path],
          runInShell: false,
        );
        return res.exitCode == 0;
      } else if (Platform.isMacOS) {
        final res = await Process.run('open', [file.absolute.path]);
        return res.exitCode == 0;
      } else if (Platform.isLinux) {
        final res = await Process.run('xdg-open', [file.absolute.path]);
        return res.exitCode == 0;
      }
    } catch (e) {
      debugPrint('[SystemFileLauncher] 调用系统图片查看器失败: $e');
    }
    return false;
  }

  /// 调用系统默认浏览器打开外部链接（http / https 等）。
  static Future<bool> openUrlInBrowser(String rawUrl) async {
    final trimmed = rawUrl.trim();
    if (trimmed.isEmpty) return false;
    final url = trimmed.contains('://') ? trimmed : 'https://$trimmed';

    try {
      if (_isFlutterTest) {
        return false;
      }

      if (Platform.isAndroid) {
        final ok = await _channel.invokeMethod<bool>(
          'openUrl',
          {'url': url},
        );
        return ok == true;
      } else if (Platform.isWindows) {
        final res = await Process.run(
          'rundll32',
          ['url.dll,FileProtocolHandler', url],
          runInShell: false,
        );
        return res.exitCode == 0;
      } else if (Platform.isMacOS) {
        final res = await Process.run('open', [url]);
        return res.exitCode == 0;
      } else if (Platform.isLinux) {
        final res = await Process.run('xdg-open', [url]);
        return res.exitCode == 0;
      }
    } catch (e) {
      debugPrint('[SystemFileLauncher] 打开外部链接失败: $e');
    }
    return false;
  }

  /// 将导出的单个 HTML 文件保存到本地（下载/文档目录），并在真实运行环境下拉起系统打开或分享面板。
  /// 返回保存后的文件路径。
  static Future<String> saveAndLaunchHtml({
    required String fileName,
    required String htmlContent,
    Directory? customOutputDir,
  }) async {
    if (customOutputDir != null) {
      if (!customOutputDir.existsSync()) {
        customOutputDir.createSync(recursive: true);
      }
      final outFile = File(p.join(customOutputDir.path, fileName));
      outFile.writeAsStringSync(htmlContent, flush: true);
      return outFile.path;
    }

    if (Platform.isAndroid && !_isFlutterTest) {
      try {
        final savedPath = await _channel.invokeMethod<String>(
          'saveAndShareHtml',
          {
            'fileName': fileName,
            'htmlContent': htmlContent,
          },
        );
        if (savedPath != null && savedPath.isNotEmpty) {
          return savedPath;
        }
      } catch (e) {
        debugPrint(
            '[SystemFileLauncher] Android 导出分享 HTML 通道调用异常，转入本地目录兜底: $e');
      }
    }

    final targetDir = await _resolveDesktopOrFallbackExportDir();
    final outFile = File(p.join(targetDir.path, fileName));
    outFile.writeAsStringSync(htmlContent, flush: true);

    if (!_isFlutterTest) {
      try {
        if (Platform.isWindows) {
          await Process.run(
            'cmd',
            ['/c', 'start', '', outFile.absolute.path],
            runInShell: false,
          );
        } else if (Platform.isMacOS) {
          await Process.run('open', [outFile.absolute.path]);
        } else if (Platform.isLinux) {
          await Process.run('xdg-open', [outFile.absolute.path]);
        }
      } catch (e) {
        debugPrint('[SystemFileLauncher] 自动打开导出 HTML 文件失败: $e');
      }
    }

    return outFile.path;
  }

  static Future<Directory> _resolveDesktopOrFallbackExportDir() async {
    if (Platform.isWindows) {
      final userProfile = Platform.environment['USERPROFILE'];
      if (userProfile != null && userProfile.isNotEmpty) {
        final downloads = Directory(p.join(userProfile, 'Downloads'));
        if (downloads.existsSync()) {
          return downloads;
        }
      }
    }

    try {
      final docsDir = await StorageBridge.getAppDocumentsDirectory();
      if (docsDir.existsSync()) {
        return docsDir;
      }
    } catch (_) {}

    return Directory.systemTemp;
  }
}

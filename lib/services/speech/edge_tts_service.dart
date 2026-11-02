import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../../core/platform/foundation_bridge.dart';
import '../../core/platform/storage_bridge.dart';

/// 微软 Edge Neural 神经网络语音合成服务
/// 通过后台守护进程复用长连接，毫秒级流式获取超自然中文语音
class EdgeTtsService {
  Process? _process;
  bool _isAvailable = true;
  bool _isStarting = false;
  int _requestIdCounter = 0;
  final Map<String, Completer<String>> _pendingRequests = {};
  StreamSubscription? _stdoutSub;
  StreamSubscription? _stderrSub;

  bool get isAvailable => _isAvailable;

  EdgeTtsService();

  /// 格式化语速倍率（如 1.2x -> +20%, 0.85x -> -15%）
  static String formatRate(double speed) {
    if ((speed - 1.0).abs() < 0.01) return '+0%';
    final pct = ((speed - 1.0) * 100).round();
    return pct >= 0 ? '+$pct%' : '$pct%';
  }

  Future<void> _initWorker() async {
    if (_process != null || _isStarting) return;
    _isStarting = true;

    try {
      final scriptPath = await _resolveScriptPath();
      if (!File(scriptPath).existsSync()) {
        debugPrint('[EdgeTtsService] 脚本文件不存在: $scriptPath');
        _isAvailable = false;
        _isStarting = false;
        return;
      }

      final pythonBin = await _resolvePythonExecutable();
      final proc = await Process.start(pythonBin, [scriptPath]);
      _process = proc;
      _isAvailable = true;

      _stdoutSub = proc.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_handleStdoutLine, onError: (e) {
        debugPrint('[EdgeTtsService] stdout 异常: $e');
      });

      _stderrSub = proc.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        if (line.contains('edge_tts package is not installed')) {
          _isAvailable = false;
        }
      });

      proc.exitCode.then((code) {
        debugPrint('[EdgeTtsService] 守护进程退出: $code');
        _cleanupProcess();
      });

      // 发送 ping 验证连通性
      final pingOk = await _pingWorker();
      if (!pingOk) {
        _isAvailable = false;
      }
    } catch (e) {
      debugPrint('[EdgeTtsService] 初始化失败 (未安装 Python 或环境受限): $e');
      _isAvailable = false;
    } finally {
      _isStarting = false;
    }
  }

  Future<String> _resolvePythonExecutable() async {
    final envPy = Platform.environment['SIDE_ASSISTANT_PYTHON'];
    if (envPy != null && envPy.trim().isNotEmpty && File(envPy).existsSync()) {
      return envPy.trim();
    }
    if (Platform.isLinux) {
      final home = Platform.environment['HOME'] ?? '';
      final venvCandidates = <String>[
        if (home.isNotEmpty)
          p.join(home, '.local', 'share', 'side_assistant', 'venv', 'bin',
              'python'),
        p.join(Directory.current.path, '.venv', 'bin', 'python'),
        p.join(p.dirname(Platform.resolvedExecutable), 'venv', 'bin', 'python'),
      ];
      for (final c in venvCandidates) {
        if (File(c).existsSync()) return c;
      }
      return 'python3';
    }
    return 'python';
  }

  Future<String> _resolveScriptPath() async {
    final exeDir = p.dirname(Platform.resolvedExecutable);
    final candidates = [
      // 1. 标准应用资源路径（当前工作目录：开发环境、测试环境、服务端常规启动）
      p.join(Directory.current.path, 'assets', 'scripts', 'edge_tts_worker.py'),
      // 2. 服务端/原生执行文件所在目录下的 assets 路径
      p.join(exeDir, 'assets', 'scripts', 'edge_tts_worker.py'),
      // 3. Flutter 桌面端 (Windows/Linux) Release 打包资源路径
      p.join(exeDir, 'data', 'flutter_assets', 'assets', 'scripts',
          'edge_tts_worker.py'),
      // 4. 工具脚本备选路径 (tool/)
      p.join(Directory.current.path, 'tool', 'edge_tts_worker.py'),
      p.join(exeDir, 'tool', 'edge_tts_worker.py'),
      // 5. 执行文件同级目录（单文件绿色分发模式）
      p.join(exeDir, 'edge_tts_worker.py'),
      // 6. 历史兼容路径（平滑过渡未迁移的 233 服务端旧代码目录）
      p.join(Directory.current.path, 'lib', 'services', 'speech',
          'edge_tts_worker.py'),
      p.join(exeDir, 'lib', 'services', 'speech', 'edge_tts_worker.py'),
    ];

    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }

    return candidates.first;
  }

  Future<bool> _pingWorker() async {
    if (_process == null) return false;
    final id = (++_requestIdCounter).toString();
    final completer = Completer<String>();
    _pendingRequests[id] = completer;

    try {
      _process!.stdin.writeln(jsonEncode({
        'id': id,
        'cmd': 'ping',
      }));
      await completer.future.timeout(const Duration(seconds: 4));
      return true;
    } catch (_) {
      _pendingRequests.remove(id);
      return false;
    }
  }

  void _handleStdoutLine(String line) {
    final clean = line.trim();
    if (clean.isEmpty) return;

    try {
      final data = jsonDecode(clean) as Map<String, dynamic>;
      final id = data['id']?.toString();
      if (id != null && _pendingRequests.containsKey(id)) {
        final completer = _pendingRequests.remove(id)!;
        if (data['success'] == true) {
          completer.complete(data['out']?.toString() ?? 'pong');
        } else {
          completer.completeError(data['error']?.toString() ?? '合成失败');
        }
      }
    } catch (e) {
      debugPrint('[EdgeTtsService] 解析行异常: $e');
    }
  }

  /// 合成文本到指定的本地临时 MP3 文件并返回其路径
  Future<String?> synthesizeToFile(
    String text, {
    String voice = 'zh-CN-XiaoxiaoNeural',
    double speed = 1.0,
  }) async {
    final cleanText = text.trim();
    if (cleanText.isEmpty) return null;

    if (_process == null && _isAvailable) {
      await _initWorker();
    }

    if (_process == null || !_isAvailable) {
      return null;
    }

    final id = (++_requestIdCounter).toString();
    final tempDir = await _getAudioTempDirectory();
    final outFile = p.join(
        tempDir.path, 'tts_${DateTime.now().millisecondsSinceEpoch}_$id.mp3');

    final completer = Completer<String>();
    _pendingRequests[id] = completer;

    try {
      _process!.stdin.writeln(jsonEncode({
        'id': id,
        'cmd': 'synthesize',
        'text': cleanText,
        'out': outFile,
        'voice': voice,
        'rate': formatRate(speed),
        'pitch': '+0Hz',
      }));

      final resultPath = await completer.future.timeout(
        Duration(seconds: (cleanText.length * 0.5).clamp(5, 45).toInt()),
      );
      if (File(resultPath).existsSync()) {
        return resultPath;
      }
      return null;
    } catch (e) {
      _pendingRequests.remove(id);
      debugPrint('[EdgeTtsService] 合成文本失败: $e');
      return null;
    }
  }

  Future<Directory> _getAudioTempDirectory() async {
    try {
      final base = await StorageBridge.getAppTemporaryDirectory();
      final dir = Directory(p.join(base.path, 'side_assistant_tts'));
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      return dir;
    } catch (_) {
      final dir =
          Directory(p.join(Directory.systemTemp.path, 'side_assistant_tts'));
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      return dir;
    }
  }

  void cancelAll() {
    for (final c in _pendingRequests.values) {
      if (!c.isCompleted) {
        c.completeError('已取消');
      }
    }
    _pendingRequests.clear();
  }

  void _cleanupProcess() {
    _stdoutSub?.cancel();
    _stderrSub?.cancel();
    _stdoutSub = null;
    _stderrSub = null;
    _process = null;
    cancelAll();
  }

  void dispose() {
    cancelAll();
    try {
      _process?.kill();
    } catch (_) {}
    _cleanupProcess();
  }
}

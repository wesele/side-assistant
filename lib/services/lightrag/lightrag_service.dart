import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../../core/models/chat_message.dart';
import '../../core/models/chat_session.dart';
import '../../core/platform/foundation_bridge.dart';
import '../../core/platform/storage_bridge.dart';

/// LightRAG 知识库服务：
/// - [queryContext]：供大模型 lightrag_query 工具调用（只读）
/// - [archiveSession]/[retryPending]：会话结束时把对话（含图片）归档到 LightRAG，失败落本地待传队列
class LightRagService {
  final String baseUrl;
  final http.Client? _injectedClient;
  final Directory? customPendingDir;

  /// 为图片生成文字描述的回调（LightRAG 不理解图片内容，需先转成文字）
  final Future<String?> Function(Uint8List imageBytes)? describeImage;

  static const Duration _queryTimeout = Duration(seconds: 30);
  static const Duration _uploadTimeout = Duration(seconds: 120);
  static const int maxContextChars = 8000;

  /// 同一进程内正在处理的待传队列，避免并发重复上传
  static bool _retrying = false;

  LightRagService({
    required String baseUrl,
    http.Client? client,
    this.customPendingDir,
    this.describeImage,
  })  : baseUrl = baseUrl.trim().replaceAll(RegExp(r'/+$'), ''),
        _injectedClient = client;

  bool get isConfigured => baseUrl.isNotEmpty;

  http.Client _client() => _injectedClient ?? http.Client();
  void _release(http.Client c) {
    if (_injectedClient == null) c.close();
  }

  // ───────────────────────── 查询 ─────────────────────────

  /// 查询知识库，仅返回检索到的上下文文本（交由当前大模型自行组织回答）
  Future<String> queryContext(String query, {String mode = 'mix'}) async {
    if (!isConfigured) return 'LightRAG 服务地址未配置。';
    final q = query.trim();
    if (q.isEmpty) return '查询内容为空。';
    const allowed = {'mix', 'local', 'global', 'naive'};
    final client = _client();
    try {
      final resp = await client
          .post(
            Uri.parse('$baseUrl/api/workbench/query'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({
              'query': q,
              'mode': allowed.contains(mode) ? mode : 'mix',
              'only_need_context': true,
            }),
          )
          .timeout(_queryTimeout);
      if (resp.statusCode != 200) {
        return 'LightRAG 查询失败（HTTP ${resp.statusCode}）。';
      }
      final text = _extractContext(utf8.decode(resp.bodyBytes));
      if (text.trim().isEmpty) return '知识库中没有找到相关内容。';
      return text.length > maxContextChars
          ? '${text.substring(0, maxContextChars)}\n…（已截断）'
          : text;
    } catch (e) {
      return 'LightRAG 查询异常：$e';
    } finally {
      _release(client);
    }
  }

  static String _extractContext(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        for (final key in const ['context', 'response', 'result', 'content']) {
          final v = decoded[key];
          if (v is String && v.isNotEmpty) return v;
        }
        return const JsonEncoder.withIndent(' ').convert(decoded);
      }
      if (decoded is String) return decoded;
    } catch (_) {}
    return body;
  }

  // ───────────────────────── 归档 ─────────────────────────

  /// 将会话归档到 LightRAG；失败时落本地待传队列，之后由 [retryPending] 重试
  Future<void> archiveSession(ChatSession session) async {
    if (!isConfigured || session.messages.isEmpty) return;
    try {
      final job = await _buildJob(session);
      await _writeJob(job);
      await retryPending();
    } catch (e) {
      debugPrint('[LightRag] 归档会话失败: $e');
    }
  }

  Future<Map<String, dynamic>> _buildJob(ChatSession session) async {
    final stamp = _fmt(session.createdAt);
    final title = '$stamp ${session.title}';
    final md = StringBuffer()
      ..writeln('# $title')
      ..writeln()
      ..writeln('会话时间：$stamp ~ ${_fmt(session.updatedAt)}')
      ..writeln();
    final images = <String>[];
    for (final m in session.messages) {
      if (m.role != 'user' && m.role != 'assistant') continue;
      final who = m.role == 'user' ? '主人浩哥' : '助手';
      md.writeln('**$who**（${_fmt(m.timestamp)}）：${m.content}');
      final desc = await _describe(m);
      if (desc != null) {
        final name = p.basename(m.imagePath!);
        images.add(m.imagePath!);
        md.writeln('[图片 $name 的内容描述] $desc');
      }
      md.writeln();
    }
    return {
      'sessionId': session.id,
      'title': title,
      'markdown': md.toString(),
      'images': images,
      'textDone': false,
      'imagesDone': images.isEmpty,
    };
  }

  Future<String?> _describe(ChatMessage m) async {
    final path = m.imagePath;
    if (path == null || path.isEmpty) return null;
    final f = File(path);
    if (!f.existsSync()) return null;
    String? desc;
    try {
      desc = await describeImage?.call(await f.readAsBytes());
    } catch (e) {
      debugPrint('[LightRag] 图片描述失败: $e');
    }
    return (desc != null && desc.trim().isNotEmpty)
        ? desc.trim().replaceAll(RegExp(r'\s+'), ' ')
        : '（未能生成描述）';
  }

  static String _fmt(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }

  // ───────────────────────── 待传队列 ─────────────────────────

  Future<Directory> _pendingDir() async {
    final dir = customPendingDir ??
        Directory(p.join(
          (await StorageBridge.getAppSupportDirectory()).path,
          'lightrag_pending',
        ));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  File _jobFile(Directory dir, String sessionId) =>
      File(p.join(dir.path, '$sessionId.json'));

  Future<void> _writeJob(Map<String, dynamic> job) async {
    final dir = await _pendingDir();
    // 以 sessionId 为文件名，同一会话重复触发时覆盖而不会重复入队
    await _jobFile(dir, job['sessionId'] as String)
        .writeAsString(jsonEncode(job));
  }

  /// 重试所有待传任务（App 启动 / 每次归档后调用）
  Future<void> retryPending() async {
    if (!isConfigured || _retrying) return;
    _retrying = true;
    try {
      final dir = await _pendingDir();
      for (final f in dir.listSync().whereType<File>()) {
        if (!f.path.endsWith('.json')) continue;
        try {
          final job = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
          final ok = await _runJob(job, f);
          if (ok) await f.delete();
        } catch (e) {
          debugPrint('[LightRag] 待传任务处理失败 ${f.path}: $e');
        }
      }
    } catch (e) {
      debugPrint('[LightRag] 重试队列异常: $e');
    } finally {
      _retrying = false;
    }
  }

  Future<bool> _runJob(Map<String, dynamic> job, File jobFile) async {
    if (job['textDone'] != true) {
      if (!await _ingestText(job['title'] as String, job['markdown'] as String)) {
        return false;
      }
      job['textDone'] = true;
      await jobFile.writeAsString(jsonEncode(job));
    }
    if (job['imagesDone'] != true) {
      final paths = (job['images'] as List).cast<String>();
      final ok = await _uploadImagesZip(job['sessionId'] as String, paths);
      if (!ok) return false;
      job['imagesDone'] = true;
      await jobFile.writeAsString(jsonEncode(job));
    }
    return true;
  }

  Future<bool> _ingestText(String title, String text) async {
    final client = _client();
    try {
      final resp = await client
          .post(
            Uri.parse('$baseUrl/api/workbench/ingest-text'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({
              'text': text,
              'title': title,
              'template': 'minimal_cleanup',
            }),
          )
          .timeout(_uploadTimeout);
      return resp.statusCode >= 200 && resp.statusCode < 300;
    } catch (e) {
      debugPrint('[LightRag] ingest-text 失败: $e');
      return false;
    } finally {
      _release(client);
    }
  }

  /// 原图打成 zip 经 /api/workbench/upload 上传，由服务器在 raw 目录归档
  Future<bool> _uploadImagesZip(String sessionId, List<String> paths) async {
    final archive = Archive();
    for (final path in paths) {
      final f = File(path);
      if (!f.existsSync()) continue;
      final bytes = await f.readAsBytes();
      archive.addFile(ArchiveFile(p.basename(path), bytes.length, bytes));
    }
    if (archive.isEmpty) return true; // 图片已被清理，无需上传
    final zipBytes = ZipEncoder().encode(archive);
    final client = _client();
    try {
      final req = http.MultipartRequest(
        'POST',
        Uri.parse('$baseUrl/api/workbench/upload'),
      )..files.add(http.MultipartFile.fromBytes(
          'file',
          zipBytes,
          filename: 'session_$sessionId.zip',
        ));
      final resp = await http.Response.fromStream(
        await client.send(req).timeout(_uploadTimeout),
      );
      return resp.statusCode >= 200 && resp.statusCode < 300;
    } catch (e) {
      debugPrint('[LightRag] 图片 zip 上传失败: $e');
      return false;
    } finally {
      _release(client);
    }
  }
}

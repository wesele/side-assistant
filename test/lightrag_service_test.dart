import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:side_assistant/core/models/chat_message.dart';
import 'package:side_assistant/core/models/chat_session.dart';
import 'package:side_assistant/services/lightrag/lightrag_service.dart';

ChatSession _session(String? imagePath) {
  final t = DateTime(2026, 10, 24, 23, 0);
  return ChatSession(
    id: 's1',
    title: '测试会话',
    createdAt: t,
    updatedAt: t.add(const Duration(minutes: 3)),
    messages: [
      ChatMessage(
          id: '1',
          role: 'user',
          content: '看看这张图',
          timestamp: t,
          imagePath: imagePath),
      ChatMessage(id: '2', role: 'assistant', content: '是一只猫', timestamp: t),
    ],
  );
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('lr_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('queryContext 使用 only_need_context 并默认 mix', () async {
    late Map body;
    final svc = LightRagService(
      baseUrl: 'http://x:1/',
      client: MockClient((req) async {
        expect(req.url.path, '/api/workbench/query');
        body = jsonDecode(req.body);
        return http.Response.bytes(
            utf8.encode(jsonEncode({'context': '浩哥喜欢啤酒'})), 200);
      }),
    );
    expect(await svc.queryContext('偏好', mode: 'bad'), '浩哥喜欢啤酒');
    expect(body['only_need_context'], true);
    expect(body['mode'], 'mix');
  });

  test('归档：文本入库 + 图片 zip 上传；失败留队列，重试后清空', () async {
    final img = File('${tmp.path}/a.jpg')..writeAsBytesSync([1, 2, 3]);
    var online = false;
    final calls = <String>[];
    final svc = LightRagService(
      baseUrl: 'http://x:1',
      customPendingDir: Directory('${tmp.path}/pending'),
      describeImage: (_) async => '一只橘猫',
      client: MockClient((req) async {
        calls.add(req.url.path);
        if (!online) throw const SocketException('down');
        if (req.url.path.endsWith('ingest-text')) {
          final b = jsonDecode(req.body) as Map;
          expect(b['text'], contains('一只橘猫'));
          expect(b['text'], contains('主人浩哥'));
          expect(b['title'], startsWith('2026-10-24 23:00'));
        }
        return http.Response('{}', 200);
      }),
    );

    await svc.archiveSession(_session(img.path));
    final pending = Directory('${tmp.path}/pending').listSync();
    expect(pending.length, 1);

    online = true;
    await svc.retryPending();
    expect(Directory('${tmp.path}/pending').listSync(), isEmpty);
    expect(calls.where((c) => c.endsWith('ingest-text')).length, 2);
    expect(calls.where((c) => c.endsWith('/upload')).length, 1);
  });
}

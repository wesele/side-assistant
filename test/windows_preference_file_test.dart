import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:side_assistant/core/platform/windows_preference_file.dart';

void main() {
  late Directory directory;
  late File file;
  late WindowsPreferenceFile store;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('windows_preferences_');
    file = File('${directory.path}/shared_preferences.json');
    store = WindowsPreferenceFile(resolveFile: () async => file);
  });

  tearDown(() async => directory.delete(recursive: true));

  test('save survives a fresh read and preserves history and previous settings',
      () async {
    final original = jsonEncode({
      'flutter.app_settings_data_v1': '{"geminiLiveVoice":"old"}',
      'flutter.chat_history_sessions_v1': '[{"id":"existing-session"}]',
      'another.preference': true,
    });
    await file.writeAsString(original);
    const settings = '{"geminiLiveVoice":"new","pipelineMode":"gemini_live"}';
    await store.writeString('flutter.app_settings_data_v1', settings);

    final reloaded = jsonDecode(await File(file.path).readAsString()) as Map;
    expect(reloaded['flutter.app_settings_data_v1'], settings);
    expect(reloaded['flutter.chat_history_sessions_v1'],
        '[{"id":"existing-session"}]');
    expect(reloaded['another.preference'], isTrue);
    expect(await File('${file.path}.bak').readAsString(), original);
    expect(await directory.list().where((f) => f.path.contains('.tmp.')).length,
        0);
  });

  test('concurrent saves preserve all keys and the latest settings', () async {
    await Future.wait([
      store.writeString('flutter.app_settings_data_v1', 'first'),
      store.writeString('flutter.chat_history_sessions_v1', 'history'),
      store.writeString('flutter.app_settings_data_v1', 'latest'),
    ]);
    final reloaded = jsonDecode(await file.readAsString()) as Map;
    expect(reloaded['flutter.app_settings_data_v1'], 'latest');
    expect(reloaded['flutter.chat_history_sessions_v1'], 'history');
  });

  for (final invalid in ['broken JSON', '[]', '']) {
    test(
        'refuses to overwrite an invalid existing file: ${jsonEncode(invalid)}',
        () async {
      await file.writeAsString(invalid);
      await expectLater(
          store.writeString('key', 'value'), throwsA(isA<FormatException>()));
      expect(await file.readAsString(), invalid);
      expect(await File('${file.path}.bak').exists(), isFalse);
    });
  }

  test('write failure is reported and does not block a later successful save',
      () async {
    final blocked = File('${directory.path}/blocked');
    await Directory(blocked.path).create();
    var target = blocked;
    final failingStore = WindowsPreferenceFile(resolveFile: () async => target);
    await expectLater(failingStore.writeString('key', 'failed'),
        throwsA(isA<FileSystemException>()));
    target = file;
    await failingStore.writeString('key', 'saved');
    expect((jsonDecode(await file.readAsString()) as Map)['key'], 'saved');
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:side_assistant/controllers/assistant_controller.dart';

void main() {
  group('两遍解码文本选择', () {
    test('离线结果覆盖流式文本时优先采用离线结果', () {
      expect(
        AssistantController.chooseFinalTranscript('今天几号', '今天几号？'),
        '今天几号？',
      );
    });

    test('离线结果包含结束词时完整保留', () {
      expect(
        AssistantController.chooseFinalTranscript('今天几号', '今天几号回答'),
        '今天几号回答',
      );
    });

    test('流式文本更完整时保留流式文本', () {
      expect(
        AssistantController.chooseFinalTranscript('今天天气怎么样', '今天天气'),
        '今天天气怎么样',
      );
    });

    test('两者互补时按重叠关系合并', () {
      expect(
        AssistantController.chooseFinalTranscript('今天天气', '天气怎么样'),
        '今天天气怎么样',
      );
    });

    test('空值处理', () {
      expect(AssistantController.chooseFinalTranscript('', '回答'), '回答');
      expect(AssistantController.chooseFinalTranscript('回答', ''), '回答');
      expect(AssistantController.chooseFinalTranscript('', ''), '');
    });
  });
}

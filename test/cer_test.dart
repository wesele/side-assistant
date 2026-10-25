import 'package:flutter_test/flutter_test.dart';
import 'package:side_assistant/services/speech/asr_post_processor.dart';

import '../tool/cer.dart' as cer;

void main() {
  group('CER 计算', () {
    test('完全相同为 0', () {
      expect(cer.characterErrorRate('今天天气怎么样', '今天天气怎么样'), 0.0);
    });

    test('单字替换', () {
      final value = cer.characterErrorRate('今天天气怎么样', '今天天气怎幺样');
      expect(value, closeTo(1 / 7, 1e-9));
    });

    test('标点与空白不计入', () {
      expect(cer.characterErrorRate('今天天气怎么样。', '今天天气怎么样'), 0.0);
    });

    test('阿拉伯数字与中文数字等价（ITN 不算错）', () {
      expect(cer.characterErrorRate('下午五点', '下午5点'), 0.0);
    });

    test('空参考文本', () {
      expect(cer.characterErrorRate('', ''), 0.0);
      expect(cer.characterErrorRate('', '有内容'), 1.0);
    });

    test('整句准确率', () {
      expect(cer.isExactMatch('今天几号？', '今天几号'), isTrue);
      expect(cer.isExactMatch('今天几号', '今天几号啊'), isFalse);
    });
  });

  group('ASR 同音词后处理', () {
    final processor = AsrPostProcessor.forTest(const [
      AsrReplacement('小曼', '晓漫'),
      AsrReplacement('回大', '回答'),
      AsrReplacement('新启一个', '新起一个'),
    ]);

    test('待机语境纠正唤醒词', () {
      expect(processor.process('小曼', wakeContext: true), '晓漫');
      expect(processor.process('小曼今天几号', wakeContext: true), '晓漫今天几号');
    });

    test('短句自动纠正', () {
      expect(processor.process('小曼今天几号'), '晓漫今天几号');
    });

    test('长句中间的普通同音词不误改', () {
      const text = '我今天路过一片小麦田，风景很不错';
      expect(processor.process(text), text);
    });

    test('长句中的“小麦田”即使有唤醒词规则也不误改', () {
      final wheatProcessor = AsrPostProcessor.forTest(const [
        AsrReplacement('小麦', '晓漫'),
      ]);
      const text = '我今天路过一片小麦田，风景很不错';
      expect(wheatProcessor.process(text), text);
      expect(wheatProcessor.process('小麦', wakeContext: true), '晓漫');
    });

    test('句尾命中仍然纠正', () {
      expect(processor.process('今天几号回大'), '今天几号回答');
    });

    test('长词优先', () {
      expect(processor.process('新启一个', wakeContext: true), '新起一个');
    });
  });
}

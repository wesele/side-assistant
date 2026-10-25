import 'package:flutter_test/flutter_test.dart';
import 'package:side_assistant/core/constants/app_constants.dart';
import 'package:side_assistant/core/models/app_settings.dart';
import 'package:side_assistant/services/speech/gemini_live_asr_service.dart';

void main() {
  group('GeminiLiveAsrService 语种过滤', () {
    test('中文识别结果保留', () {
      expect(GeminiLiveAsrService.isChineseLike('开放时间早上9点至下午5点。'), isTrue);
      expect(GeminiLiveAsrService.isChineseLike('回答。'), isTrue);
      expect(GeminiLiveAsrService.isChineseLike('帮我查一下明天北京的天气'), isTrue);
    });

    test('纯外语识别结果丢弃', () {
      expect(
        GeminiLiveAsrService.isChineseLike(
          'Hola, ¿cómo estás? Quiero comprar un billete de tren para mañana.',
        ),
        isFalse,
      );
      expect(
        GeminiLiveAsrService.isChineseLike(
          'Hello, can you help me book a table for two tonight?',
        ),
        isFalse,
      );
      expect(
        GeminiLiveAsrService.isChineseLike('こんにちは。明日の天気はどうですか？'),
        isFalse,
      );
      expect(
        GeminiLiveAsrService.isChineseLike('안녕하세요. 내일 날씨가 어때요?'),
        isFalse,
      );
    });

    test('中英混说仍保留', () {
      expect(
        GeminiLiveAsrService.isChineseLike('打开 Spotify 播放周杰伦的歌'),
        isTrue,
      );
      expect(
        GeminiLiveAsrService.isChineseLike('帮我把这个文件发到 Teams 上'),
        isTrue,
      );
    });

    test('汉字之间的 interim 空格会被清理，英文单词空格保留', () {
      expect(
        GeminiLiveAsrService.normalizeChineseSpacing('开放 时间 早上 9 点 至 下午 5 点。'),
        '开放时间早上 9 点至下午 5 点。',
      );
      expect(
        GeminiLiveAsrService.normalizeChineseSpacing('打开 Spotify 播放 周杰伦'),
        '打开 Spotify 播放周杰伦',
      );
    });

    test('空文本与纯标点丢弃', () {
      expect(GeminiLiveAsrService.isChineseLike(''), isFalse);
      expect(GeminiLiveAsrService.isChineseLike('   '), isFalse);
      expect(GeminiLiveAsrService.isChineseLike('。，！？'), isFalse);
      expect(GeminiLiveAsrService.isChineseLike('12345'), isFalse);
    });
  });

  group('GeminiLiveAsrService setup 消息', () {
    test('语言提示放在 inputAudioTranscription.languageCodes', () {
      final message = GeminiLiveAsrService.buildSetupMessage(
        model: 'models/gemini-3.5-transcribe-live',
      );
      final setup = message['setup'] as Map<String, dynamic>;
      expect(setup['model'], 'models/gemini-3.5-transcribe-live');
      expect(setup['generationConfig'], {
        'responseModalities': ['TEXT'],
      });
      // 必须嵌在 inputAudioTranscription 里面；放到 setup 顶层会被静默忽略。
      expect(setup.containsKey('languageCodes'), isFalse);
      final transcription =
          setup['inputAudioTranscription'] as Map<String, dynamic>;
      expect(transcription['languageCodes'], ['cmn-Hans-CN']);
    });

    test('传空字符串可以关闭语言提示', () {
      final message = GeminiLiveAsrService.buildSetupMessage(
        model: 'models/x',
        languageCode: '',
      );
      final setup = message['setup'] as Map<String, dynamic>;
      expect(setup['inputAudioTranscription'], isEmpty);
    });

    test('支持传入 customVocabulary 热词偏置', () {
      final message = GeminiLiveAsrService.buildSetupMessage(
        model: 'models/gemini-3.5-transcribe-live',
        customVocabulary: ['晓漫', ' 回答 ', '', '新起一个'],
      );
      final setup = message['setup'] as Map<String, dynamic>;
      final transcription =
          setup['inputAudioTranscription'] as Map<String, dynamic>;
      expect(
        transcription['customVocabulary'],
        ['晓漫', '回答', '新起一个'],
      );
    });
  });

  group('GeminiLiveAsrService 多子轮次拼接 (combineSubTurns)', () {
    test('换气产生多子句时，中间结果保留已归档的前半句', () {
      final text = GeminiLiveAsrService.combineSubTurns(
        completedTurns: ['今天北京天气怎么样，'],
        currentTurnFinalText: '',
        interimText: '回答',
      );
      expect(text, '今天北京天气怎么样，回答');
    });

    test('中文子句穿插短英文词或数字子句时不被误删', () {
      final text = GeminiLiveAsrService.combineSubTurns(
        completedTurns: ['帮我打开', ' Spotify '],
        currentTurnFinalText: '回答。',
        interimText: '',
      );
      expect(text, '帮我打开 Spotify 回答。');
    });

    test('剔除混入的日韩或长外语背景串音', () {
      final text = GeminiLiveAsrService.combineSubTurns(
        completedTurns: [
          'Hola, ¿cómo estás? Quiero comprar un billete.',
          '帮我查一下明天天气',
          'こんにちは',
        ],
        currentTurnFinalText: '回答。',
        interimText: '',
      );
      expect(text, '帮我查一下明天天气回答。');
    });
  });

  group('GeminiLiveAsrService VAD 尾静音', () {
    test('默认 0.50s 时使用云端专用 0.40s', () {
      final service = GeminiLiveAsrService(settings: AppSettings());
      expect(
        service.adjustVadMinSilence(AppConstants.defaultVadMinSilenceSeconds),
        closeTo(AppConstants.geminiVadMinSilenceSeconds, 0.0001),
      );
      service.dispose();
    });

    test('用户手工调整的尾静音不被覆盖', () {
      final service = GeminiLiveAsrService(settings: AppSettings());
      expect(service.adjustVadMinSilence(0.65), closeTo(0.65, 0.0001));
      expect(service.adjustVadMinSilence(0.20), closeTo(0.20, 0.0001));
      service.dispose();
    });
  });
}

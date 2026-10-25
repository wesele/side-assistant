import '../platform/foundation_bridge.dart';

class AppConstants {
  // 默认触发词
  static const String defaultStartWord = '晓漫';
  static const String defaultEndWord = '回答';
  static const String defaultResetWord = '新起一个';

  // 默认阈值与超时
  static const double defaultSimilarityThreshold = 0.80;
  static const int defaultSilenceTimeoutSeconds = 12;

  // 语音识别引擎（只保留内置模型，零下载）
  static const String asrEngineStreaming = 'streaming';   // 低延迟流式 Zipformer（内置 14M 小模型，逐字实时）
  static const String asrEngineSenseVoice = 'sensevoice'; // 高精度离线 SenseVoice（内置，VAD 分段）
  static const String asrEngineGeminiLive = 'gemini_live'; // Gemini 3.5 Transcribe Live（云端，需联网）
  // 默认走高精度离线 SenseVoice：实测中文准确率显著优于 14M 流式小模型，
  // 代价是首次加载多约 1s、常驻内存多约 200MB（int8 模型推理本身很快，RTF≈0.03）。
  static const String defaultAsrEngine = asrEngineSenseVoice;

  // Gemini 云端识别（可选，供用户自行对比测试）
  static const String defaultGeminiApiKey = '';
  static const String defaultGeminiAsrModel = 'gemini-3.5-transcribe-live';
  // 语言提示必须放在 inputAudioTranscription.languageCodes（BCP-47）。
  // 它只是“偏置”不是硬约束：实测同一段粤语音频，不传会原样输出粤语，
  // 传 cmn-Hans-CN 会稳定转成普通话；但韩语/英语仍按原语种输出，
  // 所以结果侧仍保留非中文过滤。
  static const String geminiAsrLanguageCode = 'cmn-Hans-CN';
  static const String geminiLiveWsUrl =
      'wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent';

  // VAD 与分段参数（针对“说话换气被切断”做过实测调优）
  static const double defaultVadThreshold = 0.40;
  static const double defaultVadMinSilenceSeconds = 0.50;
  // 云端实时识别（Gemini）专用：用户保持默认尾静音时使用更短的 0.40s，
  // 减少说完“回答”后等待 VAD 收尾的固定延迟。用户手工改过则不覆盖。
  static const double geminiVadMinSilenceSeconds = 0.40;
  static const double defaultVadMinSpeechSeconds = 0.25;
  static const double defaultVadMaxSpeechSeconds = 30.0;
  static const int defaultPreRollMs = 300;
  static const int defaultPostRollMs = 200;

  // 两遍解码：流式先出字，端点后用内置 SenseVoice 对整段音频复检
  static const bool defaultEnableTwoPass = true;
  // 超时自动提交：静音超时时若已识别到内容，自动提交而不是丢弃
  static const bool defaultAutoSubmitOnTimeout = true;

  // 默认 LLM 配置 (从 workbench 获取)
  // 安卓版默认走公网中转；其它平台保持原有局域网地址。
  static const String _defaultOpenAiBaseUrlOther = 'http://192.168.31.233:8080/v1';
  static const String _defaultOpenAiApiKeyOther = '';
  static const String _defaultOpenAiBaseUrlAndroid = 'https://wesele-aws.duckdns.org/v1';
  static const String _defaultOpenAiApiKeyAndroid = '';
  static String get defaultOpenAiBaseUrl =>
      isAndroidPlatform
          ? _defaultOpenAiBaseUrlAndroid
          : _defaultOpenAiBaseUrlOther;
  static String get defaultOpenAiApiKey =>
      isAndroidPlatform
          ? _defaultOpenAiApiKeyAndroid
          : _defaultOpenAiApiKeyOther;
  static const String defaultOpenAiModel = 'WB.deepseek-v4.1-flash';
  static const bool defaultDisableThinking = false;
  static const bool defaultEnableWebSearch = true;

  // LightRAG 知识库（查询工具 + 会话自动归档）
  static const bool defaultEnableLightRag = true;
  static const String defaultLightRagBaseUrl = 'http://192.168.31.233:9621';
  static const int lightRagIdleMinutes = 10;
  static const String defaultSystemPrompt =
      '你是一个幽默、体贴、言简意赅的中文随身语音管家。请以口语化、精炼的中文回答，适合语音朗读。注意直接给出回答内容，严禁以“回你：”、“回答：”等前缀开头。';

  // 默认 Embedding 配置 (从 workbench 获取)
  static const String defaultEmbeddingBaseUrl = 'https://integrate.api.nvidia.com/v1';
  static const String defaultEmbeddingApiKey = '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';
  static const String defaultEmbeddingModel = 'nvidia/nemotron-3-embed-1b';


  // TTS 引擎与音色默认配置
  static const String defaultTtsEngine = 'edge'; // 'edge' (微软神经网络) 或 'system' (系统SAPI)
  static const String defaultLocationAddress =
      'C. de Andorra, 65, Hortaleza, 28043 Madrid';
  static const String defaultEdgeVoice = 'zh-CN-XiaoxiaoNeural'; // 晓晓温柔女声

  // 视觉与摄像头相关默认配置
  static const String captureSourceLocal = 'local';
  static const String captureSourceNano = 'nano';
  static const String defaultCaptureSource = captureSourceLocal;

  static const String defaultNanoWlanInterface = 'auto';
  static const String defaultNanoSsid = '';
  static const String defaultNanoPassword = '';
  static const String defaultNanoBleAddress = '';

  static const bool defaultEnableVisionIntent = true;
  static const double defaultVisionSimilarityThreshold = 0.68;
  static const int defaultCameraKeepAliveMinutes = 3;
  static const String defaultCameraLensDirection = 'back'; // 'back' 或 'front'
  static const List<String> defaultVisionPrototypes = [
    '这是什么',
    '介绍一下面前这个建筑',
    '电视画面里有啥',
    '这是什么花',
    '帮我看看这个东西',
    '看看我眼前是什么',
    '画面里有什么东西',
    '这上面写了什么字',
    '帮我读一下这段文字',
    '看一下周围环境',
    '帮我识别一下这个',
    '这个东西叫什么名字',
    '拍照',
    '拍张照片看一下',
    '照相识别一下',
    '拍一下面前的物体',
    '拍摄当前视野',
  ];

  // 提示语
  static const String resetPromptReply = '好的';
  static const String timeoutPromptReply = '已取消';
  static const String startListeningPrompt = '请说';
}


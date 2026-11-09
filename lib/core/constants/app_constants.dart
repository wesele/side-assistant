import '../platform/foundation_bridge.dart';

class AppConstants {
  // 默认触发词
  static const String defaultStartWord = '晓漫';
  static const String defaultEndWord = '回答';
  static const String defaultResetWord = '新起一个';
  static const bool defaultEnableStartWordDetection = true;

  // 开始词检测模式选项：1. 启用 2. 关闭 3. 自动
  static const String startWordModeEnabled = 'enabled'; // 启用：每次对话前均需说开始词
  static const String startWordModeDisabled = 'disabled'; // 关闭：无需开始词，直接说话交互
  static const String startWordModeAuto = 'auto'; // 自动：说开始词触发后进入连续对话，超时或口令退出
  static const String defaultStartWordMode = startWordModeAuto;

  // 连续对话默认配置
  static const int defaultContinuousModeTimeoutMinutes = 10;
  static const String exitContinuousPromptReply = '好的，已退出连续对话';
  static const String defaultExitContinuousWord = '结束对话;退下';
  static const List<String> exitContinuousWords = [
    '结束对话',
    '退下',
    '停止对话',
    '退出对话',
    '退出连续对话',
    '结束会话',
  ];

  // 默认阈值与超时
  static const double defaultSimilarityThreshold = 0.80;

  /// 静音断句超时（秒）：倾听态无有效语音多久后结束本轮并提交。
  ///
  /// 取值范围 [minSilenceTimeoutSeconds, maxSilenceTimeoutSeconds]，
  /// 下限 0.1 秒用于“说完立刻收尾”的抢答式交互，上限 10 秒避免长时间空等；
  /// 默认取上限，等价于旧版 12 秒的行为上限（旧值超出新上限时按 10 秒处理）。
  static const double defaultSilenceTimeoutSeconds = 10.0;
  static const double minSilenceTimeoutSeconds = 0.1;
  static const double maxSilenceTimeoutSeconds = 10.0;

  /// 静音断句超时的调节步进（秒），UI 滑块与 Web 控制台共用。
  static const double silenceTimeoutStepSeconds = 0.1;

  // 顶层对话管线模式：1. 标准级联管线 (ASR + LLM + TTS) 2. Gemini 3.8 Live 端到端全双工模式
  static const String pipelineModeCascade = 'cascade';
  static const String pipelineModeGeminiLive = 'gemini_live';
  static const String defaultPipelineMode = pipelineModeCascade;

  // Gemini 3.8 Live 端到端全双工对话默认配置
  static const String defaultGeminiLiveModel = 'gemini-3.8-live';
  static const String defaultGeminiLiveVoice = 'Aoede';
  static const List<String> geminiLiveVoices = [
    'Aoede',
    'Zephyr',
    'Puck',
    'Charon',
    'Kore',
    'Fenrir',
    'Leda',
    'Orus',
    'Callirrhoe',
    'Autonoe',
    'Enceladus',
    'Iapetus',
    'Umbriel',
    'Algieba',
    'Despina',
    'Erinome',
    'Algenib',
    'Rasalgethi',
    'Laomedeia',
    'Achernar',
    'Alnilam',
    'Schedar',
    'Gacrux',
    'Pulcherrima',
    'Achird',
    'Zubenelgenubi',
    'Vindemiatrix',
    'Sadachbia',
    'Sadaltager',
    'Sulafat',
    'Fola',
  ];

  static const Map<String, String> geminiLiveVoiceLabels = {
    'Aoede': 'Aoede（自然轻快女声 · 默认）',
    'Zephyr': 'Zephyr（明亮清脆女声）',
    'Puck': 'Puck（活泼阳光男声）',
    'Charon': 'Charon（沉稳知性男声）',
    'Kore': 'Kore（坚定干练女声）',
    'Fenrir': 'Fenrir（热情活力男声）',
    'Leda': 'Leda（青春元气女声）',
    'Orus': 'Orus（稳重有力男声）',
    'Callirrhoe': 'Callirrhoe（随和亲切女声）',
    'Autonoe': 'Autonoe（明快爽朗女声）',
    'Enceladus': 'Enceladus（柔和空气感男声）',
    'Iapetus': 'Iapetus（清晰透亮男声）',
    'Umbriel': 'Umbriel（随性从容男声）',
    'Algieba': 'Algieba（温润顺滑男声）',
    'Despina': 'Despina（柔美顺滑女声）',
    'Erinome': 'Erinome（清亮知性女声）',
    'Algenib': 'Algenib（磁性低沉男声）',
    'Rasalgethi': 'Rasalgethi（专业播报男声）',
    'Laomedeia': 'Laomedeia（欢快明丽女声）',
    'Achernar': 'Achernar（轻柔温婉女声）',
    'Alnilam': 'Alnilam（刚毅果断男声）',
    'Schedar': 'Schedar（平实稳健男声）',
    'Gacrux': 'Gacrux（成熟醇厚女声）',
    'Pulcherrima': 'Pulcherrima（大气直率女声）',
    'Achird': 'Achird（友善温暖男声）',
    'Zubenelgenubi': 'Zubenelgenubi（轻松休闲男声）',
    'Vindemiatrix': 'Vindemiatrix（温柔恬静女声）',
    'Sadachbia': 'Sadachbia（生动活泼男声）',
    'Sadaltager': 'Sadaltager（博学睿智男声）',
    'Sulafat': 'Sulafat（温暖治愈女声）',
    'Fola': 'Fola（亲切自然女声）',
  };

  // 语音识别引擎（只保留内置模型，零下载）
  static const String asrEngineStreaming =
      'streaming'; // 低延迟流式 Zipformer（内置 14M 小模型，逐字实时）
  static const String asrEngineSenseVoice =
      'sensevoice'; // 高精度离线 SenseVoice（内置，VAD 分段）
  static const String asrEngineGeminiLive =
      'gemini_live'; // Gemini 3.5 Transcribe Live（云端，需联网）
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
  static const String _defaultOpenAiBaseUrlOther =
      'http://192.168.31.233:8080/v1';
  static const String _defaultOpenAiApiKeyOther = '';
  static const String _defaultOpenAiBaseUrlAndroid =
      'https://wesele-aws.duckdns.org/v1';
  static const String _defaultOpenAiApiKeyAndroid = '';
  static String get defaultOpenAiBaseUrl => isAndroidPlatform
      ? _defaultOpenAiBaseUrlAndroid
      : _defaultOpenAiBaseUrlOther;
  static String get defaultOpenAiApiKey => isAndroidPlatform
      ? _defaultOpenAiApiKeyAndroid
      : _defaultOpenAiApiKeyOther;
  static const String defaultOpenAiModel = 'WB.deepseek-v4.1-flash';
  static const bool defaultDisableThinking = false;
  static const bool defaultEnableWebSearch = true;

  // OpenCode CLI execution tool (用于受限执行 opencode 命令)
  static const bool defaultEnableOpenCode = true;
  static const String codeAgentProviderOpenCode = 'opencode';
  static const String codeAgentProviderHermes = 'hermes';
  static const String defaultCodeAgentProvider = codeAgentProviderOpenCode;
  static const String defaultOpenCodeCommand = 'opencode';
  static const String defaultHermesCommand = 'hermes';
  static const int defaultOpenCodeTimeoutSeconds = 120;

  // LightRAG 知识库（查询工具 + 会话自动归档）
  static const bool defaultEnableLightRag = true;
  static const String defaultLightRagBaseUrl = 'http://192.168.31.233:9621';
  static const int lightRagIdleMinutes = 10;
  static const String defaultSystemPrompt =
      '你是一个幽默、体贴、言简意赅的中文随身语音管家。请以口语化、精炼的中文回答，适合语音朗读。注意直接给出回答内容，严禁以“回你：”、“回答：”等前缀开头。';

  // TTS 引擎与音色默认配置
  static const String defaultTtsEngine =
      'edge'; // 'edge' (微软神经网络) 或 'system' (系统SAPI)
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

  // 主人声纹识别（Speaker Verification）
  static const bool defaultEnableSpeakerVerification = false;
  static const double defaultSpeakerSimilarityThreshold = 0.55;
  static const bool defaultSpeakerVerifyWakeOnly = true;
  static const double defaultSpeakerMinSpeechSeconds = 0.30;
  static const double minSpeakerMinSpeechSeconds = 0.20;
  static const double maxSpeakerMinSpeechSeconds = 0.60;
  static const double defaultSpeakerEnergyThreshold = 0.00005;
  static const double minSpeakerEnergyThreshold = 0.00001;
  static const double maxSpeakerEnergyThreshold = 0.00025;
  // 默认使用 CAM++ (192 维)：实测其非语音/背景噪声音余弦相似度接近 0，
  // 而 ERes2Net 在静音/噪声上的相似度基线可达 0.4~0.5，容易把电视声误判为主人。
  static const String defaultSpeakerModelAssetPath =
      'assets/models/speaker/3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx';
  static const String fallbackSpeakerModelAssetPath =
      defaultSpeakerModelAssetPath;

  // 目标说话人语音抽取（Target Speaker Extraction, TSE 滤声）
  static const bool defaultEnableTargetSpeakerExtraction = false;
  static const double defaultTseSimilarityThreshold = 0.50;
  static const double defaultTseAttenuationDb = 20.0;
}

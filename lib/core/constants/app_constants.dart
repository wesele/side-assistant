class AppConstants {
  // 默认触发词
  static const String defaultStartWord = '晓漫';
  static const String defaultEndWord = '回答';
  static const String defaultResetWord = '新起一个';

  // 默认阈值与超时
  static const double defaultSimilarityThreshold = 0.80;
  static const int defaultSilenceTimeoutSeconds = 12;

  // 默认 LLM 配置 (从 workbench 获取)
  static const String defaultOpenAiBaseUrl = 'http://192.168.31.233:8080/v1';
  static const String defaultOpenAiApiKey = 'sk-d311359183128865b46d0fa2d79c3bdcae023e9e';
  static const String defaultOpenAiModel = 'WB.deepseek-v4.1-flash';
  static const String defaultSystemPrompt =
      '你是一个幽默、体贴、言简意赅的中文随身语音管家。请以口语化、精炼的中文回答，适合语音朗读。';

  // 默认 Embedding 配置 (从 workbench 获取)
  static const String defaultEmbeddingBaseUrl = 'https://integrate.api.nvidia.com/v1';
  static const String defaultEmbeddingApiKey = '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';
  static const String defaultEmbeddingModel = 'nvidia/nemotron-3-embed-1b';


  // TTS 引擎与音色默认配置
  static const String defaultTtsEngine = 'edge'; // 'edge' (微软神经网络) 或 'system' (系统SAPI)
  static const String defaultEdgeVoice = 'zh-CN-XiaoxiaoNeural'; // 晓晓温柔女声

  // 提示语
  static const String resetPromptReply = '好的';
  static const String timeoutPromptReply = '已取消';
  static const String startListeningPrompt = '请说';
}

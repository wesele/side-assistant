import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../controllers/assistant_controller.dart';
import '../../core/models/app_settings.dart';
import '../../services/nlp/embedding_service.dart';
import '../../services/nlp/vector_math.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _startWordCtrl;
  late final TextEditingController _endWordCtrl;
  late final TextEditingController _resetWordCtrl;
  late final TextEditingController _openAiBaseUrlCtrl;
  late final TextEditingController _openAiApiKeyCtrl;
  late final TextEditingController _openAiModelCtrl;
  late final TextEditingController _systemPromptCtrl;
  late final TextEditingController _embeddingBaseUrlCtrl;
  late final TextEditingController _embeddingApiKeyCtrl;
  late final TextEditingController _embeddingModelCtrl;

  late double _similarityThreshold;
  late int _silenceTimeoutSeconds;
  late bool _useRemoteEmbedding;
  late bool _enableBargeIn;
  late bool _enableTtsPlayback;
  late double _ttsSpeed;
  late bool _enableAcousticWakeFilter;
  late bool _enablePromptTone;
  late String _ttsEngine;
  late String _edgeVoice;
  bool _isPreviewingVoice = false;

  // 语义测试工具状态
  final TextEditingController _testPhraseCtrl = TextEditingController();
  String _testResultText = '';
  bool _isTestingEmbedding = false;

  @override
  void initState() {
    super.initState();
    final settings = context.read<AssistantController>().settings;

    _startWordCtrl = TextEditingController(text: settings.startWord);
    _endWordCtrl = TextEditingController(text: settings.endWord);
    _resetWordCtrl = TextEditingController(text: settings.resetWord);
    _openAiBaseUrlCtrl = TextEditingController(text: settings.openAiBaseUrl);
    _openAiApiKeyCtrl = TextEditingController(text: settings.openAiApiKey);
    _openAiModelCtrl = TextEditingController(text: settings.openAiModel);
    _systemPromptCtrl = TextEditingController(text: settings.systemPrompt);
    _embeddingBaseUrlCtrl = TextEditingController(text: settings.embeddingBaseUrl);
    _embeddingApiKeyCtrl = TextEditingController(text: settings.embeddingApiKey);
    _embeddingModelCtrl = TextEditingController(text: settings.embeddingModel);

    _similarityThreshold = settings.similarityThreshold;
    _silenceTimeoutSeconds = settings.silenceTimeoutSeconds;
    _useRemoteEmbedding = settings.useRemoteEmbedding;
    _enableBargeIn = settings.enableBargeIn;
    _enableTtsPlayback = settings.enableTtsPlayback;
    _ttsSpeed = settings.ttsSpeed;
    _enableAcousticWakeFilter = settings.enableAcousticWakeFilter;
    _enablePromptTone = settings.enablePromptTone;
    _ttsEngine = settings.ttsEngine;
    _edgeVoice = settings.edgeVoice;
  }

  @override
  void dispose() {
    _startWordCtrl.dispose();
    _endWordCtrl.dispose();
    _resetWordCtrl.dispose();
    _openAiBaseUrlCtrl.dispose();
    _openAiApiKeyCtrl.dispose();
    _openAiModelCtrl.dispose();
    _systemPromptCtrl.dispose();
    _embeddingBaseUrlCtrl.dispose();
    _embeddingApiKeyCtrl.dispose();
    _embeddingModelCtrl.dispose();
    _testPhraseCtrl.dispose();
    super.dispose();
  }

  Future<void> _saveSettings() async {
    final newSettings = AppSettings(
      startWord: _startWordCtrl.text.trim(),
      endWord: _endWordCtrl.text.trim(),
      resetWord: _resetWordCtrl.text.trim(),
      similarityThreshold: _similarityThreshold,
      silenceTimeoutSeconds: _silenceTimeoutSeconds,
      openAiBaseUrl: _openAiBaseUrlCtrl.text.trim(),
      openAiApiKey: _openAiApiKeyCtrl.text.trim(),
      openAiModel: _openAiModelCtrl.text.trim(),
      systemPrompt: _systemPromptCtrl.text.trim(),
      useRemoteEmbedding: _useRemoteEmbedding,
      embeddingBaseUrl: _embeddingBaseUrlCtrl.text.trim(),
      embeddingApiKey: _embeddingApiKeyCtrl.text.trim(),
      embeddingModel: _embeddingModelCtrl.text.trim(),
      enableBargeIn: _enableBargeIn,
      enableTtsPlayback: _enableTtsPlayback,
      ttsSpeed: _ttsSpeed,
      enableAcousticWakeFilter: _enableAcousticWakeFilter,
      enablePromptTone: _enablePromptTone,
      ttsEngine: _ttsEngine,
      edgeVoice: _edgeVoice,
    );

    await context.read<AssistantController>().updateSettings(newSettings);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('配置已成功保存并立即生效')),
      );
    }
  }

  Future<void> _previewCurrentVoice() async {
    if (_isPreviewingVoice) return;
    setState(() => _isPreviewingVoice = true);
    try {
      final tts = context.read<AssistantController>().ttsService;
      await tts.previewVoice(
        voice: _edgeVoice,
        text: '你好，我是晓漫，这是我的全新神经网络发音效果。',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('音色试听失败: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isPreviewingVoice = false);
      }
    }
  }

  Future<void> _runEmbeddingTest() async {
    final candidate = _testPhraseCtrl.text.trim();
    if (candidate.isEmpty) return;

    setState(() {
      _isTestingEmbedding = true;
      _testResultText = '正在计算相似度...';
    });

    try {
      final currentSettings = context.read<AssistantController>().settings;
      EmbeddingService service;
      if (_useRemoteEmbedding) {
        service = RemoteOpenAiEmbeddingService(settings: currentSettings);
      } else {
        service = LocalQwenEmbeddingService(settings: currentSettings);
      }

      final startWord = _startWordCtrl.text.trim();
      final vecA = await service.getEmbedding(startWord);
      final vecB = await service.getEmbedding(candidate);
      final sim = VectorMath.cosineSimilarity(vecA, vecB);

      final isPass = sim >= _similarityThreshold;
      setState(() {
        _testResultText = '与开始词「$startWord」余弦相似度: ${(sim * 100).toStringAsFixed(2)}% '
            '(${isPass ? "✅ 判定命中唤醒" : "❌ 未达到阈值 ${( _similarityThreshold * 100).toInt()}%"})';
      });
    } catch (e) {
      setState(() {
        _testResultText = '计算失败: $e';
      });
    } finally {
      setState(() {
        _isTestingEmbedding = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('助手设置'),
        actions: [
          IconButton(
            icon: const Icon(Icons.check),
            tooltip: '保存配置',
            onPressed: _saveSettings,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildSectionHeader('语音触发词与语义匹配', Icons.record_voice_over),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  TextField(
                    controller: _startWordCtrl,
                    decoration: const InputDecoration(
                      labelText: '开始词（唤醒并开始收集内容）',
                      helperText: '例如：“晓漫”',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _endWordCtrl,
                    decoration: const InputDecoration(
                      labelText: '结束词（内容结束并发送大模型）',
                      helperText: '例如：“回答”',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _resetWordCtrl,
                    decoration: const InputDecoration(
                      labelText: '新起会话词（清空上下文并回答“好的”）',
                      helperText: '例如：“新起一个”',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Text('语义匹配阈值: ${(_similarityThreshold * 100).toInt()}%'),
                      Expanded(
                        child: Slider(
                          value: _similarityThreshold,
                          min: 0.50,
                          max: 0.95,
                          divisions: 45,
                          label: '${(_similarityThreshold * 100).toInt()}%',
                          onChanged: (v) => setState(() => _similarityThreshold = v),
                        ),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      Text('静音超时保护: $_silenceTimeoutSeconds 秒'),
                      Expanded(
                        child: Slider(
                          value: _silenceTimeoutSeconds.toDouble(),
                          min: 5,
                          max: 30,
                          divisions: 25,
                          label: '$_silenceTimeoutSeconds 秒',
                          onChanged: (v) => setState(() => _silenceTimeoutSeconds = v.toInt()),
                        ),
                      ),
                    ],
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('低功耗声学唤醒过滤 (MFCC-DTW)'),
                    subtitle: const Text('转文本前在纯音频层过滤无关杂音与非唤醒语音，大幅降低待机 CPU 消耗'),
                    value: _enableAcousticWakeFilter,
                    onChanged: (v) => setState(() => _enableAcousticWakeFilter = v),
                  ),
                  const Divider(height: 24),
                  // 语义测试工具
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('触发词向量匹配实时测试', style: theme.textTheme.titleSmall),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _testPhraseCtrl,
                              decoration: const InputDecoration(
                                hintText: '输入测试词，如“小曼”或“嗨晓漫”',
                                isDense: true,
                                border: OutlineInputBorder(),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton(
                            onPressed: _isTestingEmbedding ? null : _runEmbeddingTest,
                            child: _isTestingEmbedding
                                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                                : const Text('测试相似度'),
                          ),
                        ],
                      ),
                      if (_testResultText.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          _testResultText,
                          style: TextStyle(
                            fontSize: 13,
                            color: _testResultText.contains('✅') ? Colors.green : Colors.deepOrange,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          _buildSectionHeader('大语言模型（OpenAI 兼容）', Icons.psychology),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  TextField(
                    controller: _openAiBaseUrlCtrl,
                    decoration: const InputDecoration(
                      labelText: 'API Base URL',
                      helperText: '如 https://api.openai.com/v1 或 OneAPI/Ollama 服务地址',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _openAiApiKeyCtrl,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'API Key',
                      helperText: '您的 OpenAI 或第三方兼容平台的 API 密钥',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _openAiModelCtrl,
                    decoration: const InputDecoration(
                      labelText: '模型名称',
                      helperText: '如 gpt-4o-mini、deepseek-chat、qwen-turbo 等',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _systemPromptCtrl,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      labelText: '系统提示词（控制助手性格与风格）',
                      helperText: '用于控制大模型回答口吻、口语化程度及角色设定',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          _buildSectionHeader('Embedding 语义向量服务', Icons.hub),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  SwitchListTile(
                    title: const Text('使用远程 OpenAI 规范 Embedding API'),
                    subtitle: Text(_useRemoteEmbedding ? '使用远程 API 推理' : '使用本地 Qwen3-0.6b-embedding 模型'),
                    value: _useRemoteEmbedding,
                    onChanged: (v) => setState(() => _useRemoteEmbedding = v),
                  ),
                  if (_useRemoteEmbedding) ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: _embeddingBaseUrlCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Embedding Base URL',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _embeddingApiKeyCtrl,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Embedding API Key (若留空则复用上方 Key)',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _embeddingModelCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Embedding 模型名',
                        helperText: '如 text-embedding-3-small、bge-m3 等',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ] else ...[
                    const Padding(
                      padding: EdgeInsets.all(8.0),
                      child: Text('当前已启用本地集成 Qwen3-0.6b 向量推理引擎，离线高效计算。'),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          _buildSectionHeader('语音合成与交互选项', Icons.volume_up),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  SwitchListTile(
                    title: const Text('启用 TTS 自动播放'),
                    subtitle: const Text('大模型回复后自动按句播放，新会话自动播报“好的”'),
                    value: _enableTtsPlayback,
                    onChanged: (v) => setState(() => _enableTtsPlayback = v),
                  ),
                  SwitchListTile(
                    title: const Text('支持语音打断（Barge-in）'),
                    subtitle: const Text('朗读期间检测到开始词或“停止”立即停止朗读'),
                    value: _enableBargeIn,
                    onChanged: (v) => setState(() => _enableBargeIn = v),
                  ),
                  SwitchListTile(
                    title: const Text('识别到结束词播放提示音（轻滴声）'),
                    subtitle: const Text('确认识别“回答”后立即播放提示音，代表指令已成功捕获并在等待大模型思考'),
                    value: _enablePromptTone,
                    onChanged: (v) => setState(() => _enablePromptTone = v),
                  ),
                  Row(
                    children: [
                      Text('朗读书语速: ${_ttsSpeed.toStringAsFixed(1)}x'),
                      Expanded(
                        child: Slider(
                          value: _ttsSpeed,
                          min: 0.5,
                          max: 2.0,
                          divisions: 15,
                          label: '${_ttsSpeed.toStringAsFixed(1)}x',
                          onChanged: (v) => setState(() => _ttsSpeed = v),
                        ),
                      ),
                    ],
                  ),
                  const Divider(height: 24),
                  DropdownButtonFormField<String>(
                    value: _ttsEngine,
                    decoration: const InputDecoration(
                      labelText: 'TTS 语音合成引擎',
                      helperText: '选择“微软 Edge Neural 神经网络”享受超自然真人发音',
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'edge',
                        child: Text('微软 Edge Neural (超自然高品质 · 强烈推荐)'),
                      ),
                      DropdownMenuItem(
                        value: 'system',
                        child: Text('Windows 系统原生 SAPI5 (离线机械发音)'),
                      ),
                    ],
                    onChanged: (v) {
                      if (v != null) setState(() => _ttsEngine = v);
                    },
                  ),
                  if (_ttsEngine == 'edge') ...[
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      value: _edgeVoice,
                      decoration: const InputDecoration(
                        labelText: '微软神经网络音色',
                        helperText: '推荐与“小曼/晓漫”人设高度匹配的温柔女声',
                        border: OutlineInputBorder(),
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: 'zh-CN-XiaoxiaoNeural',
                          child: Text('晓晓 (温柔自然女声 · 推荐)'),
                        ),
                        DropdownMenuItem(
                          value: 'zh-CN-YunxiNeural',
                          child: Text('云希 (阳光沉稳男声)'),
                        ),
                        DropdownMenuItem(
                          value: 'zh-CN-XiaoyiNeural',
                          child: Text('小艺 (活泼亲切女声)'),
                        ),
                        DropdownMenuItem(
                          value: 'zh-CN-YunjianNeural',
                          child: Text('云健 (影视解说/磁性男声)'),
                        ),
                        DropdownMenuItem(
                          value: 'zh-CN-YunyangNeural',
                          child: Text('云扬 (专业新闻播音男声)'),
                        ),
                      ],
                      onChanged: (v) {
                        if (v != null) setState(() => _edgeVoice = v);
                      },
                    ),
                    const SizedBox(height: 10),
                    Align(
                      alignment: Alignment.centerRight,
                      child: OutlinedButton.icon(
                        icon: _isPreviewingVoice
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.play_circle_outline),
                        label: Text(_isPreviewingVoice ? '正在试听中...' : '试听当前音色'),
                        onPressed: _isPreviewingVoice ? null : _previewCurrentVoice,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),

          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              minimumSize: const Size.fromHeight(50),
              backgroundColor: theme.colorScheme.primary,
              foregroundColor: theme.colorScheme.onPrimary,
            ),
            icon: const Icon(Icons.save),
            label: const Text('保存所有设置', style: TextStyle(fontSize: 16)),
            onPressed: _saveSettings,
          ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title, IconData icon) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Row(
        children: [
          Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}

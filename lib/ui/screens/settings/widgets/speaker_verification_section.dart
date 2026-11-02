import 'package:flutter/material.dart';
import '../../../../controllers/assistant_controller.dart';
import 'settings_shared.dart';

class SpeakerVerificationSection extends StatefulWidget {
  final AssistantController controller;
  final bool enableSpeakerVerification;
  final double speakerSimilarityThreshold;
  final bool speakerVerifyWakeOnly;
  final double speakerMinSpeechSeconds;
  final double speakerEnergyThreshold;
  final bool enableTargetSpeakerExtraction;
  final double tseAttenuationDb;
  final ValueChanged<bool> onEnableChanged;
  final ValueChanged<double> onSimilarityThresholdChanged;
  final ValueChanged<bool> onWakeOnlyChanged;
  final ValueChanged<double> onMinSpeechSecondsChanged;
  final ValueChanged<double> onEnergyThresholdChanged;
  final ValueChanged<bool> onTargetSpeakerExtractionChanged;
  final ValueChanged<double> onTseAttenuationDbChanged;
  final void Function({bool immediate}) onAutoSave;

  const SpeakerVerificationSection({
    super.key,
    required this.controller,
    required this.enableSpeakerVerification,
    required this.speakerSimilarityThreshold,
    required this.speakerVerifyWakeOnly,
    required this.speakerMinSpeechSeconds,
    required this.speakerEnergyThreshold,
    required this.enableTargetSpeakerExtraction,
    required this.tseAttenuationDb,
    required this.onEnableChanged,
    required this.onSimilarityThresholdChanged,
    required this.onWakeOnlyChanged,
    required this.onMinSpeechSecondsChanged,
    required this.onEnergyThresholdChanged,
    required this.onTargetSpeakerExtractionChanged,
    required this.onTseAttenuationDbChanged,
    required this.onAutoSave,
  });

  @override
  State<SpeakerVerificationSection> createState() =>
      _SpeakerVerificationSectionState();
}

class _SpeakerVerificationSectionState
    extends State<SpeakerVerificationSection> {
  bool _isEnrollingSpeaker = false;
  bool _isTestingSpeaker = false;
  String _speakerTestResult = '';
  double? _speakerTestSimilarity;
  double? _speakerTestThreshold;
  bool _speakerTestPassed = false;
  double _speakerTestSpeechSeconds = 0;
  int _speakerTestEnrolledCount = 0;
  List<double> _speakerTestSamplePercents = const [];

  void _resetSpeakerTestResult() {
    _speakerTestResult = '';
    _speakerTestSimilarity = null;
    _speakerTestThreshold = null;
    _speakerTestPassed = false;
    _speakerTestSpeechSeconds = 0;
    _speakerTestEnrolledCount = 0;
    _speakerTestSamplePercents = const [];
  }

  Future<void> _handleEnrollSpeaker() async {
    setState(() => _isEnrollingSpeaker = true);
    try {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('🎙️ 录音中，请清晰朗读 3 秒（例如：“小曼小曼，今天天气怎么样”）...'),
            duration: Duration(milliseconds: 3500),
          ),
        );
      }
      final success =
          await widget.controller.recordAndEnrollOwnerSpeaker(seconds: 3.5);
      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        if (success) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                '✅ 成功录入声纹样本！当前共有 ${widget.controller.speakerVerificationService.enrolledSampleCount} 个样本',
              ),
            ),
          );
          setState(_resetSpeakerTestResult);
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('❌ 录入未成功：声音过短或未检测到声音，请朗读时间稍长一些再试'),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('录入异常: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isEnrollingSpeaker = false);
      }
    }
  }

  Future<void> _handleTestSpeaker() async {
    setState(() {
      _isTestingSpeaker = true;
      _resetSpeakerTestResult();
      _speakerTestResult = '正在录音检测...';
    });
    try {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('🎙️ 正在录音 3 秒：请只说一句话，或只播放电视声（不要同时有人说话）...'),
            duration: Duration(milliseconds: 3000),
          ),
        );
      }
      final res =
          await widget.controller.recordAndTestOwnerSpeakerSimilarity(seconds: 3.0);
      if (mounted) {
        setState(() {
          _speakerTestResult =
              res['text'] as String? ?? res['error'] as String? ?? '';
          final sim = res['similarity'];
          _speakerTestSimilarity = sim is num ? sim.toDouble() : null;
          final threshold = res['threshold'];
          _speakerTestThreshold =
              threshold is num ? threshold.toDouble() : null;
          _speakerTestPassed = res['passed'] == true;
          final speech = res['speechSeconds'];
          _speakerTestSpeechSeconds =
              speech is num ? speech.toDouble() : 0.0;
          final count = res['enrolledCount'];
          _speakerTestEnrolledCount = count is num ? count.toInt() : 0;
          final percents = res['samplePercents'];
          _speakerTestSamplePercents = percents is List
              ? percents
                  .whereType<num>()
                  .map((e) => e.toDouble())
                  .toList(growable: false)
              : const [];
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _speakerTestResult = '测试异常: $e');
      }
    } finally {
      if (mounted) {
        setState(() => _isTestingSpeaker = false);
      }
    }
  }

  Future<void> _handleClearSpeaker() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空主人声纹'),
        content: const Text('确定要删除所有已保存的主人声纹样本吗？清空后将无法进行声纹拦截。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确定清空', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await widget.controller.clearOwnerSpeaker();
      if (mounted) {
        setState(_resetSpeakerTestResult);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已清空所有主人声纹样本')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final speakerService = widget.controller.speakerVerificationService;
    final enrolledCount = speakerService.enrolledSampleCount;
    final storedTotal =
        widget.controller.settings.ownerSpeakerEmbeddings.length;
    final staleCount = (storedTotal - enrolledCount).clamp(0, storedTotal);
    final hasOwner = enrolledCount > 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        buildSectionHeader(context, '主人声纹识别（声纹锁）', Icons.fingerprint),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('启用主人声纹识别'),
                  subtitle: Text(
                    hasOwner
                        ? '已启用声纹锁，仅响应主人声音'
                        : '开启后需先录制声纹样本；未录制样本前保持放行',
                    style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  value: widget.enableSpeakerVerification,
                  onChanged: (v) {
                    widget.onEnableChanged(v);
                    widget.onAutoSave(immediate: true);
                  },
                ),
                if (widget.enableSpeakerVerification) ...[
                  const Divider(height: 16),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('仅在唤醒与打断时校验'),
                    subtitle: Text(
                      '推荐开启。避免提问时极短词（如“回答”）因有效语音过短而被拦截',
                      style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    value: widget.speakerVerifyWakeOnly,
                    onChanged: (v) {
                      widget.onWakeOnlyChanged(v);
                      widget.onAutoSave(immediate: true);
                    },
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '声纹匹配阈值: ${(widget.speakerSimilarityThreshold * 100).toInt()}%',
                              style: theme.textTheme.titleSmall,
                            ),
                            Text(
                              '较宽松 (45%) ~ 推荐 (55%~60%) ~ 较严格 (70%)',
                              style: TextStyle(
                                fontSize: 11,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: Slider(
                          value: widget.speakerSimilarityThreshold,
                          min: 0.35,
                          max: 0.85,
                          divisions: 50,
                          label:
                              '${(widget.speakerSimilarityThreshold * 100).toInt()}%',
                          onChanged: (v) {
                            widget.onSimilarityThresholdChanged(v);
                            widget.onAutoSave();
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '有效人声最短时长: ${widget.speakerMinSpeechSeconds.toStringAsFixed(2)} 秒',
                              style: theme.textTheme.titleSmall,
                            ),
                            Text(
                              '短唤醒词（如“小满”）建议 0.25~0.35 秒；值越小越灵敏',
                              style: TextStyle(
                                fontSize: 11,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: Slider(
                          value: widget.speakerMinSpeechSeconds,
                          min: 0.20,
                          max: 0.60,
                          divisions: 8,
                          label:
                              '${widget.speakerMinSpeechSeconds.toStringAsFixed(2)} 秒',
                          onChanged: (v) {
                            widget.onMinSpeechSecondsChanged(v);
                            widget.onAutoSave();
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '声纹有效人声起振门限: ${widget.speakerEnergyThreshold.toStringAsFixed(5)}',
                              style: theme.textTheme.titleSmall,
                            ),
                            Text(
                              '3~5米远场或低增益蓝牙麦建议 0.00003~0.00008；近场防噪建议 0.00015~0.00020',
                              style: TextStyle(
                                fontSize: 12,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: Slider(
                          value: widget.speakerEnergyThreshold.clamp(0.00001, 0.00025),
                          min: 0.00001,
                          max: 0.00025,
                          divisions: 24,
                          label: widget.speakerEnergyThreshold.toStringAsFixed(5),
                          onChanged: (v) {
                            widget.onEnergyThresholdChanged(v);
                            widget.onAutoSave();
                          },
                        ),
                      ),
                    ],
                  ),
                  const Divider(height: 16),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('目标说话人语音抽取 (TSE 智能滤声)'),
                    subtitle: Text(
                      '【方案二】利用主人声纹波形分离，消除电视背景音与户外路人闲聊，只保留主人声音',
                      style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    value: widget.enableTargetSpeakerExtraction,
                    onChanged: (v) {
                      widget.onTargetSpeakerExtractionChanged(v);
                      widget.onAutoSave(immediate: true);
                    },
                  ),
                  if (widget.enableTargetSpeakerExtraction) ...[
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '干扰人声抑制强度: ${widget.tseAttenuationDb.toInt()} dB',
                                style: theme.textTheme.titleSmall,
                              ),
                              Text(
                                '衰减电视音与路人人声的强度（推荐 18~24 dB）',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Expanded(
                          child: Slider(
                            value: widget.tseAttenuationDb,
                            min: 10.0,
                            max: 30.0,
                            divisions: 20,
                            label: '${widget.tseAttenuationDb.toInt()} dB',
                            onChanged: (v) {
                              widget.onTseAttenuationDbChanged(v);
                              widget.onAutoSave();
                            },
                          ),
                        ),
                      ],
                    ),
                  ],
                  const Divider(height: 20),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: hasOwner
                          ? theme.colorScheme.primaryContainer.withOpacity(0.3)
                          : theme.colorScheme.errorContainer.withOpacity(0.3),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              hasOwner
                                  ? Icons.check_circle
                                  : Icons.warning_amber_rounded,
                              size: 18,
                              color:
                                  hasOwner ? Colors.green : Colors.deepOrange,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '已录入主人声纹: $enrolledCount / 5 个样本',
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold, fontSize: 13),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '声纹模型: ${speakerService.modelLabel}',
                          style: TextStyle(
                            fontSize: 11,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        if (staleCount > 0) ...[
                          const SizedBox(height: 4),
                          Text(
                            '检测到 $staleCount 个旧模型声纹样本已失效（不参与比对），'
                            '请点“清空声纹”后重新录制。',
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.deepOrange,
                            ),
                          ),
                        ],
                        const SizedBox(height: 4),
                        Text(
                          hasOwner
                              ? '提示：可多次录入不同距离/语速的样本文本（推荐录制“小曼小曼，今天天气怎么样”），多样本融合能显著提升识别率。'
                              : '尚未录入声纹！请先点击下方“录制声纹样本”，朗读唤醒词及日常语句建档。',
                          style: TextStyle(
                            fontSize: 12,
                            color: hasOwner
                                ? theme.colorScheme.onSurfaceVariant
                                : Colors.deepOrange,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ElevatedButton.icon(
                        icon: _isEnrollingSpeaker
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.mic, size: 18),
                        label: Text(
                            _isEnrollingSpeaker ? '正在录入...' : '录制声纹样本'),
                        onPressed: _isEnrollingSpeaker
                            ? null
                            : _handleEnrollSpeaker,
                      ),
                      OutlinedButton.icon(
                        icon: _isTestingSpeaker
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.verified_user_outlined,
                                size: 18),
                        label: Text(
                            _isTestingSpeaker ? '比对中...' : '测试当前声音相似度'),
                        onPressed: (_isTestingSpeaker || !hasOwner)
                            ? null
                            : _handleTestSpeaker,
                      ),
                      if (storedTotal > 0)
                        TextButton.icon(
                          icon: const Icon(Icons.delete_outline,
                              size: 18, color: Colors.red),
                          label: const Text('清空声纹',
                              style: TextStyle(color: Colors.red)),
                          onPressed: _handleClearSpeaker,
                        ),
                    ],
                  ),
                  if (_speakerTestResult.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Builder(builder: (context) {
                      final sim = _speakerTestSimilarity;
                      final passed = _speakerTestPassed;
                      final accent =
                          passed ? Colors.green : Colors.deepOrangeAccent;
                      return Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: accent.withOpacity(0.08),
                          border: Border.all(color: accent.withOpacity(0.45)),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (sim != null) ...[
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.baseline,
                                textBaseline: TextBaseline.alphabetic,
                                children: [
                                  Text(
                                    '${(sim * 100).toStringAsFixed(1)}%',
                                    style: TextStyle(
                                      fontSize: 30,
                                      fontWeight: FontWeight.w800,
                                      color: accent,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    passed ? '✅ 判定为主人' : '❌ 非主人声纹',
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.bold,
                                      color: accent,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child: LinearProgressIndicator(
                                  value: sim.clamp(0.0, 1.0),
                                  minHeight: 10,
                                  backgroundColor:
                                      Colors.grey.withOpacity(0.25),
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                      accent),
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                '判定阈值 ${((_speakerTestThreshold ?? widget.speakerSimilarityThreshold) * 100).toStringAsFixed(0)}%'
                                ' · 有效语音 ${_speakerTestSpeechSeconds.toStringAsFixed(2)}s'
                                ' · 样本数 $_speakerTestEnrolledCount',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                              if (_speakerTestSamplePercents.isNotEmpty) ...[
                                const SizedBox(height: 4),
                                Text(
                                  '与各录音样本相似度: '
                                  '${_speakerTestSamplePercents.map((p) => '${p.toStringAsFixed(1)}%').join('  |  ')}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                              const SizedBox(height: 6),
                            ],
                            Text(
                              _speakerTestResult,
                              style: TextStyle(
                                fontSize: 13,
                                color: accent,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                  ],
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

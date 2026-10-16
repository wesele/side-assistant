import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../controllers/assistant_controller.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _testInputCtrl = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _testInputCtrl.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _sendSimulatedText(String text) {
    if (text.trim().isEmpty) return;
    context.read<AssistantController>().simulateUserInput(text.trim());
    _testInputCtrl.clear();
    _scrollToBottom();
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AssistantController>();
    final theme = Theme.of(context);
    final settings = controller.settings;

    // 自动滚动到底部
    _scrollToBottom();

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 12,
        title: const Text(
          '随身智能助理',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: FilledButton.tonalIcon(
              key: const Key('mic_toggle_btn'),
              style: FilledButton.styleFrom(
                backgroundColor: controller.isMicListening
                    ? Colors.green.shade100
                    : theme.colorScheme.surfaceContainerHighest,
                foregroundColor: controller.isMicListening
                    ? Colors.green.shade900
                    : theme.colorScheme.onSurfaceVariant,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              icon: Icon(
                controller.isMicListening ? Icons.mic : Icons.mic_off,
                size: 18,
                color: controller.isMicListening ? Colors.green.shade800 : null,
              ),
              label: Text(
                controller.isMicListening ? '话筒监听中' : '话筒已静音',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
              ),
              onPressed: () => controller.toggleMicListening(),
            ),
          ),
          const SizedBox(width: 6),
          IconButton(
            key: const Key('self_test_btn'),
            icon: const Icon(Icons.fact_check_outlined),
            tooltip: '运行全链路诊断测试',
            onPressed: () => _showSelfTestModal(context, controller),
          ),
          IconButton(
            key: const Key('reset_btn'),
            icon: const Icon(Icons.refresh),
            tooltip: '新起一个会话（重置上下文）',
            onPressed: () => controller.startNewSession(playVoice: true),
          ),
          IconButton(
            key: const Key('settings_btn'),
            icon: const Icon(Icons.settings),
            tooltip: '设置',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // 顶部动态状态挂件（合并单行状态与语音内容显示）
          _buildStatusPill(controller, theme),

          // 对话消息列表
          Expanded(
            child: controller.messages.isEmpty
                ? _buildEmptyState(theme, settings)
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(16),
                    itemCount: controller.messages.length,
                    itemBuilder: (context, index) {
                      final msg = controller.messages[index];
                      return _buildMessageBubble(msg, theme);
                    },
                  ),
          ),

          // 底部控制与测试输入条
          _buildBottomInputBar(controller, theme, settings),
        ],
      ),
    );
  }

  Widget _buildStatusPill(AssistantController controller, ThemeData theme) {
    Color bg;
    Color fg;
    IconData icon;
    String statusTitle;

    switch (controller.status) {
      case AssistantStatus.idle:
        bg = Colors.teal.shade50;
        fg = Colors.teal.shade800;
        icon = Icons.bedtime_outlined;
        statusTitle = '低功耗待机中';
        break;
      case AssistantStatus.listeningContent:
        bg = Colors.amber.shade100;
        fg = Colors.amber.shade900;
        icon = Icons.hearing;
        statusTitle = '正在倾听指令';
        break;
      case AssistantStatus.thinking:
        bg = Colors.indigo.shade50;
        fg = Colors.indigo.shade800;
        icon = Icons.psychology;
        statusTitle = '大模型思考中';
        break;
      case AssistantStatus.playing:
        bg = Colors.green.shade50;
        fg = Colors.green.shade800;
        icon = Icons.record_voice_over;
        statusTitle = '正在语音朗读';
        break;
    }

    final hasSpeech = controller.displayTranscript.isNotEmpty;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: fg.withOpacity(0.25)),
      ),
      child: Row(
        children: [
          Icon(icon, color: fg, size: 20),
          const SizedBox(width: 8),
          Text(
            statusTitle,
            style: TextStyle(fontWeight: FontWeight.bold, color: fg, fontSize: 13),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              '|',
              style: TextStyle(color: fg.withOpacity(0.3), fontSize: 12),
            ),
          ),
          Expanded(
            child: hasSpeech
                ? RichText(
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    text: TextSpan(
                      style: TextStyle(fontSize: 12, color: fg),
                      children: [
                        TextSpan(
                          text: controller.isWakeWordMatched ? '已命中: ' : '未匹配: ',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: controller.isWakeWordMatched
                                ? Colors.amber.shade900
                                : fg.withOpacity(0.7),
                          ),
                        ),
                        TextSpan(text: controller.displayTranscript),
                      ],
                    ),
                  )
                : Text(
                    controller.statusHint,
                    style: TextStyle(color: fg.withOpacity(0.85), fontSize: 12),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
          ),
          if (hasSpeech) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: controller.isWakeWordMatched
                    ? Colors.amber.shade200
                    : fg.withOpacity(0.12),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                controller.isWakeWordMatched ? '已激活' : '未触发',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: controller.isWakeWordMatched
                      ? Colors.amber.shade900
                      : fg.withOpacity(0.85),
                ),
              ),
            ),
          ],
          if (controller.status == AssistantStatus.playing) ...[
            const SizedBox(width: 6),
            InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => controller.simulateUserInput('停止'),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.stop, size: 16, color: Colors.red),
                    SizedBox(width: 2),
                    Text(
                      '打断',
                      style: TextStyle(fontSize: 11, color: Colors.red, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme, dynamic settings) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.mic_none, size: 64, color: theme.colorScheme.outline),
          const SizedBox(height: 16),
          Text(
            '随身助理已就绪',
            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              '你可以随时说出开始词「${settings.startWord}」唤醒，说完后以「${settings.endWord}」发送；\n或说「${settings.resetWord}」直接重置会话上下文。',
              textAlign: TextAlign.center,
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageBubble(dynamic msg, ThemeData theme) {
    final isUser = msg.role == 'user';
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        constraints: const BoxConstraints(maxWidth: 480),
        decoration: BoxDecoration(
          color: isUser
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isUser ? 16 : 4),
            bottomRight: Radius.circular(isUser ? 4 : 16),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isUser ? Icons.person : Icons.smart_toy,
                  size: 14,
                  color: isUser
                      ? theme.colorScheme.onPrimaryContainer
                      : theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Text(
                  isUser ? '你' : '助理',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: isUser
                        ? theme.colorScheme.onPrimaryContainer
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              msg.content.isEmpty ? '...' : msg.content,
              style: TextStyle(
                fontSize: 15,
                color: isUser
                    ? theme.colorScheme.onPrimaryContainer
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomInputBar(
    AssistantController controller,
    ThemeData theme,
    dynamic settings,
  ) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(top: BorderSide(color: theme.colorScheme.outlineVariant)),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              key: const Key('input_field'),
              controller: _testInputCtrl,
              decoration: InputDecoration(
                hintText: '输入模拟语音或指令（如“${settings.startWord} ... ${settings.endWord}”）',
                isDense: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(24)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              ),
              onSubmitted: _sendSimulatedText,
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filledTonal(
            key: const Key('mic_record_btn'),
            style: IconButton.styleFrom(
              backgroundColor: controller.isManualRecording
                  ? Colors.red.shade100
                  : (controller.isMicListening ? Colors.green.shade50 : null),
              foregroundColor: controller.isManualRecording
                  ? Colors.red.shade900
                  : (controller.isMicListening ? Colors.green.shade800 : null),
            ),
            icon: Icon(
              controller.isManualRecording ? Icons.stop : Icons.mic,
            ),
            tooltip: controller.isManualRecording ? '停止录音并直接发送' : '点按对讲录音（直接发送，免唤醒词）',
            onPressed: () async {
              if (controller.isManualRecording) {
                await controller.stopManualRecording();
              } else {
                await controller.startManualRecording();
              }
            },
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            key: const Key('send_btn'),
            icon: const Icon(Icons.send),
            tooltip: '发送模拟语音流',
            onPressed: () => _sendSimulatedText(_testInputCtrl.text),
          ),
        ],
      ),
    );
  }

  void _showSelfTestModal(BuildContext context, AssistantController controller) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (modalCtx) {
        return Consumer<AssistantController>(
          builder: (ctx, ctrl, _) {
            return Container(
              height: MediaQuery.of(ctx).size.height * 0.75,
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.fact_check, color: Theme.of(ctx).colorScheme.primary),
                          const SizedBox(width: 8),
                          const Text(
                            '运行态全链路自测诊断台',
                            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.of(modalCtx).pop(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '支持实时测试：NVIDIA 向量接口、DeepSeek 大模型、双层匹配与上下文重置。',
                    style: TextStyle(color: Theme.of(ctx).colorScheme.outline, fontSize: 13),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton.icon(
                    key: const Key('start_self_test_btn'),
                    style: ElevatedButton.styleFrom(
                      minimumSize: const Size.fromHeight(46),
                      backgroundColor: Theme.of(ctx).colorScheme.primary,
                      foregroundColor: Theme.of(ctx).colorScheme.onPrimary,
                    ),
                    icon: ctrl.isSelfTesting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.play_arrow),
                    label: Text(ctrl.isSelfTesting ? '正在执行自测试...' : '立即开始全链路自测试'),
                    onPressed: ctrl.isSelfTesting ? null : () => ctrl.runDiagnosticSelfTest(),
                  ),
                  const SizedBox(height: 16),
                  Expanded(
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.04),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.black12),
                      ),
                      child: ctrl.selfTestLogs.isEmpty
                          ? const Center(
                              child: Text('点击上方按钮开始测试，执行日志将在此实时显示'),
                            )
                          : ListView.builder(
                              itemCount: ctrl.selfTestLogs.length,
                              itemBuilder: (context, idx) {
                                final log = ctrl.selfTestLogs[idx];
                                Color color = Colors.black87;
                                if (log.contains('✅') || log.contains('🎉')) {
                                  color = Colors.green.shade800;
                                } else if (log.contains('❌')) {
                                  color = Colors.red.shade800;
                                } else if (log.contains('🚀')) {
                                  color = Colors.indigo.shade800;
                                }
                                return Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 4),
                                  child: Text(
                                    log,
                                    style: TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 13,
                                      fontWeight: FontWeight.w500,
                                      color: color,
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

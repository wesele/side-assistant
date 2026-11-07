import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../controllers/assistant_controller.dart';
import '../../core/models/audio_input_device_kind.dart';
import '../theme/app_theme.dart';
import '../widgets/chat_history_drawer.dart';
import '../widgets/chat_message_bubble.dart';
import '../widgets/mic_source_icon.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _testInputCtrl = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  int _lastMessageCount = 0;
  int _lastTailContentLength = 0;

  @override
  void dispose() {
    _testInputCtrl.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom({bool animate = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      final target = _scrollController.position.maxScrollExtent;
      if (animate) {
        _scrollController.animateTo(
          target,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      } else {
        _scrollController.jumpTo(target);
      }
    });
  }

  void _sendTextMessage(String text) {
    if (text.trim().isEmpty) return;
    context.read<AssistantController>().sendTextMessage(text.trim());
    _testInputCtrl.clear();
    _scrollToBottom();
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AssistantController>();
    final theme = Theme.of(context);
    final settings = controller.settings;
    final messages = controller.messages;
    final micKind = classifyAudioInputDevice(
      controller.activeAudioInputDeviceLabel,
      id: settings.audioInputDeviceId,
    );
    final msgCount = messages.length;
    final tailLen = msgCount > 0 ? messages.last.content.length : 0;

    if (msgCount != _lastMessageCount || tailLen != _lastTailContentLength) {
      final isCountChanged = msgCount != _lastMessageCount;
      _lastMessageCount = msgCount;
      _lastTailContentLength = tailLen;
      _scrollToBottom(animate: isCountChanged);
    }

    return Scaffold(
      drawer: const ChatHistoryDrawer(),
      appBar: AppBar(
        actions: [
          IconButton(
            key: const Key('camera_capture_btn'),
            tooltip:
                controller.isQuickCapturing ? '正在抓拍...' : '拍照并问 AI「这是什么，介绍一下」',
            icon: controller.isQuickCapturing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.photo_camera_outlined, size: 24),
            onPressed: controller.isQuickCapturing
                ? null
                : () {
                    HapticFeedback.lightImpact();

                    controller.captureAndAskAboutScene();
                  },
          ),
          IconButton(
            key: const Key('mic_toggle_btn'),
            tooltip: MicSourceToggleIcon.tooltip(
              controller.isMicListening,
              micKind,
              controller.activeAudioInputDeviceLabel,
            ),
            style: IconButton.styleFrom(
              foregroundColor: MicSourceToggleIcon.foregroundColor(
                micKind,
                controller.isMicListening,
                theme.colorScheme.onSurfaceVariant,
              ),
            ),
            icon: MicSourceToggleIcon(
              isListening: controller.isMicListening,
              kind: micKind,
            ),
            onPressed: () {
              HapticFeedback.lightImpact();

              controller.toggleMicListening();
            },
          ),
          IconButton(
            key: const Key('reset_btn'),
            icon: const Icon(Icons.edit_square, size: 22),
            tooltip: '新起一个会话（重置上下文）',
            onPressed: () {
              HapticFeedback.lightImpact();

              controller.startNewSession(playVoice: true);
            },
          ),
          IconButton(
            key: const Key('settings_btn'),
            icon: const Icon(Icons.settings_outlined, size: 24),
            tooltip: '设置',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              );
            },
          ),
          const SizedBox(width: 4),
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
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    itemCount: controller.messages.length,
                    itemBuilder: (context, index) {
                      final msg = controller.messages[index];

                      return ChatMessageBubble(msg: msg);
                    },
                  ),
          ),

          // 底部控制与测试输入条

          _buildBottomInputBar(controller, theme, settings),
        ],
      ),
    );
  }

  /// 状态胶囊里的音源徽标：让「内置 / 蓝牙 / 外接」不只靠图标角标，文字也可见。
  Widget _buildMicSourceChip(AssistantController controller, Color fg) {
    final kind = classifyAudioInputDevice(
      controller.activeAudioInputDeviceLabel,
      id: controller.settings.audioInputDeviceId,
    );
    if (kind == AudioInputDeviceKind.unknown) return const SizedBox.shrink();
    final color = MicSourceToggleIcon.foregroundColor(kind, true, fg);
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color.withOpacity(0.16),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          audioInputDeviceKindLabel(kind),
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
      ),
    );
  }

  Widget _buildStatusPill(AssistantController controller, ThemeData theme) {
    Color bg;

    Color fg;

    IconData icon;

    String statusTitle;

    final neutralBg = theme.colorScheme.surfaceContainerHighest;

    final neutralFg = theme.colorScheme.onSurfaceVariant;

    bg = neutralBg;

    fg = neutralFg;

    switch (controller.status) {
      case AssistantStatus.idle:
        icon = controller.isMicListening
            ? Icons.bedtime_outlined
            : Icons.mic_off_outlined;

        statusTitle = '低功耗待机中';

        break;

      case AssistantStatus.listeningContent:
        fg = AppTheme.accent;

        icon = Icons.hearing;

        statusTitle = '正在倾听指令';

        break;

      case AssistantStatus.thinking:
        fg = theme.colorScheme.onSurface;

        icon = Icons.psychology_outlined;

        statusTitle = '大模型思考中';

        break;

      case AssistantStatus.playing:
        fg = AppTheme.accent;

        icon = Icons.record_voice_over_outlined;

        statusTitle = '正在语音朗读';

        break;
    }

    final hasSpeech = controller.displayTranscript.isNotEmpty;

    return InkWell(
      borderRadius: BorderRadius.circular(24),
      onTap: !controller.isMicListening
          ? () => controller.toggleMicListening()
          : null,
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Row(
          children: [
            Icon(icon, color: fg, size: 20),
            const SizedBox(width: 8),
            Text(
              statusTitle,
              style: TextStyle(
                  fontWeight: FontWeight.bold, color: fg, fontSize: 13),
            ),
            _buildMicSourceChip(controller, fg),
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
                            text: controller.isWakeWordMatched
                                ? '已命中: '
                                : '未匹配: ',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: controller.isWakeWordMatched
                                  ? AppTheme.accent
                                  : fg.withOpacity(0.7),
                            ),
                          ),
                          TextSpan(text: controller.displayTranscript),
                        ],
                      ),
                    )
                  : Text(
                      controller.statusHint,
                      style:
                          TextStyle(color: fg.withOpacity(0.85), fontSize: 12),
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
                      ? AppTheme.accent.withOpacity(0.18)
                      : fg.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  controller.isWakeWordMatched ? '已激活' : '未触发',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: controller.isWakeWordMatched
                        ? AppTheme.accent
                        : fg.withOpacity(0.85),
                  ),
                ),
              ),
            ],
            if (controller.status == AssistantStatus.playing) ...[
              const SizedBox(width: 6),
              InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () {
                  HapticFeedback.lightImpact();

                  controller.simulateUserInput('停止');
                },
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.stop_circle_outlined,
                          size: 16, color: theme.colorScheme.error),
                      const SizedBox(width: 2),
                      Text(
                        '打断',
                        style: TextStyle(
                            fontSize: 11,
                            color: theme.colorScheme.error,
                            fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme, dynamic settings) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.graphic_eq, size: 48, color: theme.colorScheme.onSurface),
          const SizedBox(height: 16),
          Text(
            '随身助理已就绪',
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              '你可以随时说出开始词「${settings.startWords.join("、")}」唤醒，'
              '说完后以「${settings.endWords.join("、")}」发送；\n'
              '或说「${settings.resetWords.join("、")}」直接重置会话上下文。',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: theme.colorScheme.onSurfaceVariant, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomInputBar(
    AssistantController controller,
    ThemeData theme,
    dynamic settings,
  ) {
    final scheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      color: scheme.surface,
      child: SafeArea(
        top: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                key: const Key('input_field'),
                controller: _testInputCtrl,
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.send,
                decoration: InputDecoration(
                  hintText: '输入消息直接发送...',
                  isDense: true,
                  filled: true,
                  fillColor: scheme.surfaceContainerHighest,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(26),
                    borderSide: BorderSide.none,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(26),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(26),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
                ),
                onSubmitted: _sendTextMessage,
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              key: const Key('mic_record_btn'),
              style: IconButton.styleFrom(
                fixedSize: const Size(46, 46),
                backgroundColor: controller.isManualRecording
                    ? scheme.error
                    : scheme.surfaceContainerHighest,
                foregroundColor: controller.isManualRecording
                    ? scheme.onError
                    : (controller.isMicListening
                        ? AppTheme.accent
                        : scheme.onSurface),
              ),
              icon: Icon(
                controller.isManualRecording
                    ? Icons.stop_rounded
                    : Icons.mic_none_rounded,
              ),
              tooltip: controller.isManualRecording
                  ? '停止录音并直接发送'
                  : '点按对讲录音（直接发送，免唤醒词）',
              onPressed: () async {
                HapticFeedback.lightImpact();

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
              style: IconButton.styleFrom(
                fixedSize: const Size(46, 46),
                backgroundColor: scheme.primary,
                foregroundColor: scheme.onPrimary,
              ),
              icon: const Icon(Icons.arrow_upward_rounded),
              tooltip: '发送消息',
              onPressed: () {
                HapticFeedback.lightImpact();

                _sendTextMessage(_testInputCtrl.text);
              },
            ),
          ],
        ),
      ),
    );
  }
}

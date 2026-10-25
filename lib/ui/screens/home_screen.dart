import 'dart:convert';

import 'dart:io';

import 'package:flutter/material.dart';

import 'package:flutter/services.dart';

import 'package:flutter_markdown/flutter_markdown.dart';

import 'package:provider/provider.dart';

import '../../controllers/assistant_controller.dart';

import '../../services/system/system_file_launcher.dart';

import '../widgets/chat_history_drawer.dart';

import '../theme/app_theme.dart';

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
            tooltip: controller.isMicListening ? '话筒监听中（点击静音）' : '话筒已静音（点击开启）',
            style: IconButton.styleFrom(
              foregroundColor: controller.isMicListening
                  ? AppTheme.accent
                  : theme.colorScheme.onSurfaceVariant,
            ),
            icon: Icon(
              controller.isMicListening ? Icons.mic : Icons.mic_off_outlined,
              size: 24,
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

  Widget _buildMessageBubble(dynamic msg, ThemeData theme) {
    final isUser = msg.role == 'user';

    final textColor = theme.colorScheme.onSurface;

    final rawText =
        (msg.content as String).isEmpty ? '...' : msg.content as String;

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (msg.imagePath != null && (msg.imagePath as String).isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: GestureDetector(
              key: Key('message_image_${msg.id}'),
              onTap: () => _openMessageImage(msg.imagePath as String),
              child: Stack(
                alignment: Alignment.bottomRight,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: File(msg.imagePath as String).existsSync()
                        ? Image.file(
                            File(msg.imagePath as String),
                            width: 240,
                            height: 180,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) =>
                                _buildMissingImagePlaceholder(),
                          )
                        : _buildMissingImagePlaceholder(),
                  ),
                  Container(
                    margin: const EdgeInsets.all(6),
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Icon(
                      Icons.zoom_in,
                      size: 16,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
        if (isUser)
          SelectableText(
            rawText,
            style: TextStyle(fontSize: 16, height: 1.5, color: textColor),
          )
        else
          _buildAssistantMarkdown(rawText, theme),
      ],
    );

    // ChatGPT 风格：用户为右对齐淡青圆角气泡；助理无气泡、全宽 Markdown 文本与图片。

    if (isUser) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 8),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.8,
          ),
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(22),
          ),
          child: content,
        ),
      );
    }

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: content,
    );
  }

  Widget _buildAssistantMarkdown(String text, ThemeData theme) {
    final scheme = theme.colorScheme;

    final textColor = scheme.onSurface;

    final codeBg = scheme.surfaceContainerLow;

    return SelectionArea(
      child: MarkdownBody(
        data: text,
        selectable: false,
        softLineBreak: true,
        styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
          p: TextStyle(fontSize: 16, height: 1.55, color: textColor),
          h1: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w700,
            height: 1.35,
            color: textColor,
          ),
          h2: TextStyle(
            fontSize: 19,
            fontWeight: FontWeight.w700,
            height: 1.35,
            color: textColor,
          ),
          h3: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            height: 1.35,
            color: textColor,
          ),
          listBullet: TextStyle(fontSize: 16, height: 1.55, color: textColor),
          strong: TextStyle(fontWeight: FontWeight.w700, color: textColor),
          em: TextStyle(fontStyle: FontStyle.italic, color: textColor),
          a: const TextStyle(
            color: AppTheme.accent,
            decoration: TextDecoration.underline,
          ),
          code: TextStyle(
            fontFamily: 'monospace',
            fontSize: 14,
            color: textColor,
            backgroundColor: codeBg,
          ),
          codeblockPadding: const EdgeInsets.all(12),
          codeblockDecoration: BoxDecoration(
            color: codeBg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: scheme.outlineVariant),
          ),
          blockquotePadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          blockquoteDecoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: scheme.outline, width: 3),
            ),
          ),
          tableBorder: TableBorder.all(
            color: scheme.outlineVariant,
            width: 0.8,
            borderRadius: BorderRadius.circular(8),
          ),
          tableCellsPadding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          horizontalRuleDecoration: BoxDecoration(
            border: Border(
              top: BorderSide(color: scheme.outlineVariant, width: 1),
            ),
          ),
        ),
        onTapLink: (linkText, href, title) {
          final target = (href != null && href.trim().isNotEmpty)
              ? href.trim()
              : linkText.trim();
          if (target.isNotEmpty) {
            HapticFeedback.lightImpact();
            SystemFileLauncher.openUrlInBrowser(target);
          }
        },
        sizedImageBuilder: (config) {
          return _buildMarkdownImage(config.uri, alt: config.alt, theme: theme);
        },
      ),
    );
  }

  Widget _buildMarkdownImage(
    Uri uri, {
    String? alt,
    required ThemeData theme,
  }) {
    final raw = uri.toString();

    Widget imageWidget;

    if (uri.scheme == 'http' || uri.scheme == 'https') {
      imageWidget = Image.network(
        raw,
        fit: BoxFit.contain,
        loadingBuilder: (context, child, progress) {
          if (progress == null) return child;

          return Container(
            width: 240,
            height: 160,
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(16),
            ),
            alignment: Alignment.center,
            child: const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        },
        errorBuilder: (_, __, ___) =>
            _buildMissingImagePlaceholder(label: alt ?? '图片加载失败'),
      );
    } else if (uri.scheme == 'data') {
      final bytes = _decodeDataUriBytes(raw);

      imageWidget = bytes != null
          ? Image.memory(
              bytes,
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) =>
                  _buildMissingImagePlaceholder(label: alt ?? '图片解析失败'),
            )
          : _buildMissingImagePlaceholder(label: alt ?? '图片解析失败');
    } else {
      final filePath = uri.scheme == 'file' ? uri.toFilePath() : raw;

      final file = File(filePath);

      imageWidget = file.existsSync()
          ? Image.file(
              file,
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) =>
                  _buildMissingImagePlaceholder(label: alt ?? '图片加载失败'),
            )
          : _buildMissingImagePlaceholder(label: alt ?? '图片不存在');
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: GestureDetector(
        onTap: () => _openMessageImage(raw),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 320),
            child: imageWidget,
          ),
        ),
      ),
    );
  }

  Uint8List? _decodeDataUriBytes(String dataUri) {
    try {
      final comma = dataUri.indexOf(',');

      if (comma == -1) return null;

      return base64Decode(dataUri.substring(comma + 1));
    } catch (_) {
      return null;
    }
  }

  Widget _buildMissingImagePlaceholder({String label = '已捕获画面'}) {
    return Container(
      width: 240,
      height: 100,
      decoration: BoxDecoration(
        color: Colors.black12,
        borderRadius: BorderRadius.circular(16),
      ),
      alignment: Alignment.center,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.photo_camera_outlined, size: 28, color: Colors.grey),
          const SizedBox(height: 4),
          Text(
            label,
            style: const TextStyle(fontSize: 11, color: Colors.grey),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _buildFullscreenImageChild(String source) {
    final uri = Uri.tryParse(source);

    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
      return Image.network(
        source,
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => const Text(
          '无法加载网络图片',
          style: TextStyle(color: Colors.white70),
        ),
      );
    }

    if (uri != null && uri.scheme == 'data') {
      final bytes = _decodeDataUriBytes(source);

      if (bytes != null) {
        return Image.memory(
          bytes,
          fit: BoxFit.contain,
          errorBuilder: (_, __, ___) => const Text(
            '无法加载图片数据',
            style: TextStyle(color: Colors.white70),
          ),
        );
      }

      return const Text(
        '无法加载图片数据',
        style: TextStyle(color: Colors.white70),
      );
    }

    final filePath =
        (uri != null && uri.scheme == 'file') ? uri.toFilePath() : source;

    final file = File(filePath);

    if (file.existsSync()) {
      return Image.file(
        file,
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => const Text(
          '无法加载原图文件',
          style: TextStyle(color: Colors.white70),
        ),
      );
    }

    return const Text(
      '无法加载原图文件',
      style: TextStyle(color: Colors.white70),
    );
  }

  Future<void> _openMessageImage(String imagePath) async {
    final isRemoteOrData = imagePath.startsWith('http://') ||
        imagePath.startsWith('https://') ||
        imagePath.startsWith('data:');

    if (!isRemoteOrData) {
      final launched =
          await SystemFileLauncher.openImageWithSystemViewer(imagePath);

      if (launched || !mounted) return;
    }

    if (!mounted) return;

    await showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      builder: (dialogCtx) {
        return Dialog.fullscreen(
          key: const Key('fullscreen_image_viewer'),
          backgroundColor: Colors.black,
          child: Stack(
            children: [
              Positioned.fill(
                child: InteractiveViewer(
                  minScale: 0.5,
                  maxScale: 5.0,
                  child: Center(
                    child: _buildFullscreenImageChild(imagePath),
                  ),
                ),
              ),
              Positioned(
                top: 16,
                right: 16,
                child: SafeArea(
                  child: IconButton.filledTonal(
                    key: const Key('close_fullscreen_image_btn'),
                    icon: const Icon(Icons.close),
                    tooltip: '关闭预览',
                    onPressed: () => Navigator.of(dialogCtx).pop(),
                  ),
                ),
              ),
            ],
          ),
        );
      },
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

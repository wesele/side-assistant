import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import '../../core/platform/system_file_launcher.dart';
import '../theme/app_theme.dart';

/// 对话消息气泡组件 (ChatMessageBubble)
///
/// 封装单条消息渲染、Markdown 富文本排版、网络/本地/Data-URI 图片预览与全屏大图查看器。
class ChatMessageBubble extends StatelessWidget {
  final dynamic msg;

  const ChatMessageBubble({
    super.key,
    required this.msg,
  });

  @override
  Widget build(BuildContext context) {
    final isUser = msg.role == 'user';
    final theme = Theme.of(context);
    final textColor = theme.colorScheme.onSurface;
    final rawText = (msg.content as String).isEmpty ? '...' : msg.content as String;

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (msg.imagePath != null && (msg.imagePath as String).isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: GestureDetector(
              key: Key('message_image_${msg.id}'),
              onTap: () => _openMessageImage(context, msg.imagePath as String),
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
          _buildAssistantMarkdown(context, rawText, theme),
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

  Widget _buildAssistantMarkdown(BuildContext context, String text, ThemeData theme) {
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
          return _buildMarkdownImage(context, config.uri, alt: config.alt, theme: theme);
        },
      ),
    );
  }

  Widget _buildMarkdownImage(
    BuildContext context,
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
        onTap: () => _openMessageImage(context, raw),
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

  static Uint8List? _decodeDataUriBytes(String dataUri) {
    try {
      final comma = dataUri.indexOf(',');
      if (comma == -1) return null;
      return base64Decode(dataUri.substring(comma + 1));
    } catch (_) {
      return null;
    }
  }

  static Widget _buildMissingImagePlaceholder({String label = '已捕获画面'}) {
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

  static Widget _buildFullscreenImageChild(String source) {
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

  static Future<void> _openMessageImage(BuildContext context, String imagePath) async {
    final isRemoteOrData = imagePath.startsWith('http://') ||
        imagePath.startsWith('https://') ||
        imagePath.startsWith('data:');

    if (!isRemoteOrData) {
      final launched =
          await SystemFileLauncher.openImageWithSystemViewer(imagePath);
      if (launched || !context.mounted) return;
    }

    if (!context.mounted) return;

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
}

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../controllers/assistant_controller.dart';
import '../../core/models/chat_session.dart';

class ChatHistoryDrawer extends StatefulWidget {
  const ChatHistoryDrawer({super.key});

  @override
  State<ChatHistoryDrawer> createState() => _ChatHistoryDrawerState();
}

class _ChatHistoryDrawerState extends State<ChatHistoryDrawer> {
  final TextEditingController _searchCtrl = TextEditingController();
  String _searchQuery = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  /// 将会话按最近更新时间分为：今天、昨天、过去 7 天、更早
  static String _timeGroupLabel(DateTime updatedAt, DateTime now) {
    final todayStart = DateTime(now.year, now.month, now.day);
    final yesterdayStart = todayStart.subtract(const Duration(days: 1));
    final sevenDaysAgoStart = todayStart.subtract(const Duration(days: 7));

    if (!updatedAt.isBefore(todayStart)) {
      return '今天';
    } else if (!updatedAt.isBefore(yesterdayStart)) {
      return '昨天';
    } else if (!updatedAt.isBefore(sevenDaysAgoStart)) {
      return '过去 7 天';
    } else {
      return '更早';
    }
  }

  Future<void> _showRenameDialog(
    BuildContext context,
    AssistantController controller,
    ChatSession session,
  ) async {
    final textCtrl = TextEditingController(text: session.title);
    final newTitle = await showDialog<String>(
      context: context,
      builder: (dialogCtx) {
        return AlertDialog(
          title: const Text('重命名对话'),
          content: TextField(
            key: const Key('rename_session_input'),
            controller: textCtrl,
            autofocus: true,
            maxLength: 40,
            decoration: const InputDecoration(
              hintText: '请输入新的对话标题',
            ),
            onSubmitted: (val) => Navigator.of(dialogCtx).pop(val.trim()),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogCtx).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const Key('rename_session_confirm_btn'),
              onPressed: () =>
                  Navigator.of(dialogCtx).pop(textCtrl.text.trim()),
              child: const Text('保存'),
            ),
          ],
        );
      },
    );

    if (newTitle != null && newTitle.isNotEmpty) {
      await controller.renameSession(session.id, newTitle);
    }
  }

  Future<void> _showClearAllConfirmDialog(
    BuildContext context,
    AssistantController controller,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) {
        return AlertDialog(
          title: const Text('清空全部历史对话'),
          content: const Text('确定要删除所有历史对话及关联图片吗？此操作无法撤销。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogCtx).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const Key('clear_all_confirm_btn'),
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(dialogCtx).colorScheme.error,
                foregroundColor: Theme.of(dialogCtx).colorScheme.onError,
              ),
              onPressed: () => Navigator.of(dialogCtx).pop(true),
              child: const Text('清空'),
            ),
          ],
        );
      },
    );

    if (confirmed == true) {
      await controller.clearAllHistory();
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AssistantController>();
    final theme = Theme.of(context);
    final allSessions = controller.sessions;
    final filteredSessions = allSessions
        .where((s) => s.matchesQuery(_searchQuery))
        .toList(growable: false);

    final now = DateTime.now();
    const groupOrder = ['今天', '昨天', '过去 7 天', '更早'];
    final grouped = <String, List<ChatSession>>{
      for (final g in groupOrder) g: <ChatSession>[],
    };
    for (final s in filteredSessions) {
      final group = _timeGroupLabel(s.updatedAt, now);
      grouped[group]!.add(s);
    }

    return Drawer(
      key: const Key('chat_history_drawer'),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 顶部：搜索框
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
              child: TextField(
                key: const Key('drawer_search_field'),
                controller: _searchCtrl,
                decoration: InputDecoration(
                  hintText: '搜索历史对话...',
                  prefixIcon: const Icon(Icons.search, size: 20),
                  suffixIcon: _searchQuery.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, size: 18),
                          onPressed: () {
                            _searchCtrl.clear();
                            setState(() {
                              _searchQuery = '';
                            });
                          },
                        )
                      : null,
                  isDense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  border: OutlineInputBorder(
                    borderSide: BorderSide.none,
                    borderRadius: BorderRadius.circular(24),
                  ),
                ),
                onChanged: (value) {
                  setState(() {
                    _searchQuery = value;
                  });
                },
              ),
            ),

            // 中部：按时间分组的历史对话列表
            Expanded(
              child: filteredSessions.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          allSessions.isEmpty ? '暂无历史对话' : '未找到匹配的对话',
                          style: TextStyle(
                            color: theme.colorScheme.onSurfaceVariant,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 8),
                      children: [
                        for (final group in groupOrder)
                          if (grouped[group]!.isNotEmpty) ...[
                            Padding(
                              padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                              child: Text(
                                group,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                            for (final session in grouped[group]!)
                              _buildSessionTile(
                                context,
                                controller,
                                session,
                                theme,
                              ),
                          ],
                      ],
                    ),
            ),

            // 底部：导出全部历史为单个 HTML + 清空全部历史对话
            if (allSessions.isNotEmpty) ...[
              const Divider(height: 1),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextButton.icon(
                      key: const Key('drawer_export_html_btn'),
                      icon: const Icon(Icons.html_outlined, size: 18),
                      label: const Text('导出对话历史 (HTML)'),
                      style: TextButton.styleFrom(
                        alignment: Alignment.centerLeft,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                      ),
                      onPressed: () async {
                        final messenger = ScaffoldMessenger.maybeOf(context);
                        final navigator = Navigator.of(context);
                        try {
                          final savedPath =
                              await controller.exportAllHistoryToHtml();
                          if (navigator.mounted) {
                            navigator.pop();
                          }
                          messenger?.showSnackBar(
                            SnackBar(
                              content: Text('已导出对话历史 HTML：$savedPath'),
                              duration: const Duration(seconds: 4),
                            ),
                          );
                        } catch (e) {
                          messenger?.showSnackBar(
                            SnackBar(content: Text('导出 HTML 失败：$e')),
                          );
                        }
                      },
                    ),
                    TextButton.icon(
                      key: const Key('drawer_clear_all_btn'),
                      icon: Icon(
                        Icons.delete_sweep_outlined,
                        size: 18,
                        color: theme.colorScheme.error,
                      ),
                      label: Text(
                        '清空历史对话',
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                      style: TextButton.styleFrom(
                        alignment: Alignment.centerLeft,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                      ),
                      onPressed: () =>
                          _showClearAllConfirmDialog(context, controller),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSessionTile(
    BuildContext context,
    AssistantController controller,
    ChatSession session,
    ThemeData theme,
  ) {
    final isSelected = session.id == controller.currentSessionId;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 2),
      decoration: BoxDecoration(
        color: isSelected
            ? theme.colorScheme.secondaryContainer
            : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
      ),
      child: ListTile(
        key: Key('session_tile_${session.id}'),
        dense: true,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
        contentPadding: const EdgeInsets.only(left: 12, right: 4),
        leading: Icon(
          Icons.chat_bubble_outline,
          size: 18,
          color: isSelected
              ? theme.colorScheme.onSecondaryContainer
              : theme.colorScheme.onSurfaceVariant,
        ),
        title: Text(
          session.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 13,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            color: isSelected
                ? theme.colorScheme.onSecondaryContainer
                : theme.colorScheme.onSurface,
          ),
        ),
        onTap: () async {
          Navigator.of(context).pop();
          await controller.switchSession(session.id);
        },
        trailing: PopupMenuButton<String>(
          key: Key('session_menu_${session.id}'),
          icon: Icon(
            Icons.more_vert,
            size: 18,
            color: isSelected
                ? theme.colorScheme.onSecondaryContainer
                : theme.colorScheme.onSurfaceVariant,
          ),
          tooltip: '更多操作',
          onSelected: (action) async {
            if (action == 'rename') {
              await _showRenameDialog(context, controller, session);
            } else if (action == 'delete') {
              await controller.deleteSession(session.id);
            }
          },
          itemBuilder: (context) => [
            const PopupMenuItem<String>(
              value: 'rename',
              child: Row(
                children: [
                  Icon(Icons.edit_outlined, size: 18),
                  SizedBox(width: 8),
                  Text('重命名'),
                ],
              ),
            ),
            PopupMenuItem<String>(
              value: 'delete',
              child: Row(
                children: [
                  Icon(
                    Icons.delete_outline,
                    size: 18,
                    color: theme.colorScheme.error,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '删除',
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

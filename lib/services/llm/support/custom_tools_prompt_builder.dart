import '../../../core/models/app_settings.dart';
import '../tools/custom_tool_manager.dart';

/// 自定义工具与 OpenCode 系统提示词生成器 (CustomToolsPromptBuilder)
///
/// 动态读取已注册的持久化工具清单，并生成标准化工具生态提示词注入大模型对话上下文。
class CustomToolsPromptBuilder {
  CustomToolsPromptBuilder._();

  /// 构造注入系统提示词的 OpenCode 与持久化工具生态指导说明
  static String buildPromptSuffix(
    AppSettings settings, {
    CustomToolManager? manager,
  }) {
    if (!settings.enableOpenCode) {
      return '';
    }

    final toolMgr = manager ?? CustomToolManager.instance;
    final tools = toolMgr.listToolsSync();

    final buffer = StringBuffer();
    buffer.writeln('\n## 扩展工具与代码生成生态 (OpenCode)');
    buffer.writeln('你拥有调用持久化自定义工具以及利用 OpenCode 编写运行脚本解决任务的自主工具生态：');
    buffer.writeln();

    buffer.writeln('### 已注册的持久化自定义工具列表:');
    if (tools.isNotEmpty) {
      for (final tool in tools) {
        buffer.writeln(tool.toPromptLine());
      }
    } else {
      buffer.writeln('(当前暂无已注册的持久化工具)');
    }
    buffer.writeln();

    buffer.writeln('### 工具调用与创建准则:');
    buffer.writeln(
      '1. **优先复用已有工具**: 处理用户意图时，首先核对上方已注册工具列表。'
      '若已有匹配工具，直接调用 `call_custom_tool` 执行，避免重复编写脚本。',
    );
    buffer.writeln(
      '2. **智能区分生命周期 (invoke_opencode)**: 若无对应工具，调用 `invoke_opencode` 通过编写代码解决，必须合理选择 `persistence`：\n'
      '   - **`persistence: "persistent"` (持久化工具)**: 用户提出的需求属于未来可能复用的功能（例如设置定时闹钟、周期提醒、通用查询、智能硬件联动等）。'
      '必须提供规范的 `tool_name`（纯英文字母/数字/下划线）与 `tool_summary`，编写并在当前目录生成 `tool.json` 持久化保存至工具库；\n'
      '   - **`persistence: "temporary"` (一次性任务)**: 复杂的即时数学计算、临时文本格式转换、一次性数据分析或探索，使用临时目录执行，执行完毕后自动销毁。',
    );
    buffer.writeln(
      '3. **主动语音播报支持**: 持久化脚本（尤其是闹钟 alarm_clock、定时提醒等）在后台运行时，可向环境变量 `SIDE_ASSISTANT_SPEAK_URL` '
      '发送 HTTP POST 请求 (JSON 格式: `{"text": "提醒内容"}`) 主动触发助手的语音播报；'
      '若环境变量 `SIDE_ASSISTANT_ACCESS_PASSWORD` 非空，需在请求头带上 `x-access-password`。',
    );

    return buffer.toString();
  }
}

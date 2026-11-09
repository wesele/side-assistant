import '../../../core/constants/app_constants.dart';
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
    final isHermes = settings.codeAgentProvider.trim().toLowerCase() ==
        AppConstants.codeAgentProviderHermes;
    final agentName = CustomToolManager.resolveAgentDisplayName(settings);

    final buffer = StringBuffer();
    if (isHermes) {
      buffer.writeln('\n## 扩展工具与代码生成生态 (Hermes)');
    } else {
      buffer.writeln('\n## 扩展工具与代码生成生态 (OpenCode)');
    }
    buffer.writeln('你拥有调用持久化自定义工具以及利用 $agentName 编写运行脚本解决任务的自主工具生态：');
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
    buffer.writeln(
      '4. **拟人化交互与执行前先行回应 (极重要)**:\n'
      '   - **先行友好回应**: 在调用 `call_custom_tool` 或 `invoke_opencode` 之前，必须先用自然、亲切、口语化的先行回应向用户说明即将做什么，'
      '严禁静默或生硬地直接触发工具调用。例如：“好的浩哥，我这就调用 XXX 工具帮你处理，请稍等”或“没问题，我先帮你用 $agentName 编写一个 XXX 工具来处理，可能需要几十秒，请稍候”；\n'
      '   - **执行过程中的进度安抚**: 若在长时间的代码编写或工具执行过程中系统注入了中间进度提示，'
      '请用简短自然的人性化语言向用户汇报当前进展，安抚用户耐心等待。',
    );

    return buffer.toString();
  }
}

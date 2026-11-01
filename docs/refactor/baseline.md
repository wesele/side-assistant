# SideAssistant 重构基线与验证记录 (Baseline Report)

- **记录时间**: 2026-11-01
- **环境**: Flutter 3.24.x / Dart 3.5.3 (Windows 11)

## 1. 静态分析 (Static Analysis)
- 命令: `flutter analyze`
- 结果: `No issues found! (ran in 3.6s)`
- 缺陷数: **0**

## 2. 自动化测试 (Automated Test Suite)
- 命令: `flutter test --exclude-tags benchmark`
- 结果: `+480: All tests passed! (耗时约 62s)`
- 失败用例: **0**

## 3. 无头服务端内核编译 (Headless Kernel Compilation)
- 命令: `dart compile kernel bin/linux_server.dart`
- 结果: `Compiling bin/linux_server.dart to kernel file bin/linux_server.dill.` (Exit code: 0)
- 说明: `bin/linux_server.dart` 与业务链路零 Flutter UI / `dart:ui` 依赖泄漏。

## 4. 依赖现状指标 (Dependency Metrics Baseline)
- 循环依赖: **0 cycles** across `lib/` and `bin/`
- 上帝类 (>600行):
  - `lib/services/automation/web_console_html.dart`: 2640 行
  - `lib/core/engine/coordinators/dialogue_intent_coordinator.dart`: 1316 行
  - `lib/services/speech/voice_listening_service.dart`: 1039 行
  - `lib/services/speech/speaker_verification_service.dart`: 998 行
  - `lib/services/llm/llm_service.dart`: 898 行
  - `lib/services/speech/gemini_live_asr_service.dart`: 893 行
  - `lib/core/models/domain_configs.dart`: 804 行
  - `lib/ui/screens/home_screen.dart`: 776 行
  - `lib/services/nlp/trigger_matcher.dart`: 734 行
  - `lib/core/engine/coordinators/voice_pipeline_coordinator.dart`: 664 行
  - `lib/core/engine/assistant_engine.dart`: 678 行
- 跨层依赖违规数 (Core -> Services): 15 个具体服务依赖，待 Phase 1-2 消除。

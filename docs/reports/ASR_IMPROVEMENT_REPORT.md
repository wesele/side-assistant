# 语音识别改进交付报告

> 日期：2026-10-17  
> 目标：让语音识别在 Windows / Android 上**开箱即用**，不要求用户下载、配置任何模型或服务器。  
> 结论：只保留两个**已内置**的离线引擎；FireRed、streaming-zh、局域网 ASR、KWS 已全部移除。两遍解码保留，第二遍改用内置 SenseVoice。

---

## 1. 最终保留的能力

### 1.1 两个内置识别引擎

| 引擎 | 模型 | 特点 | 适用场景 |
|---|---|---|---|
| **SenseVoice**（默认） | `assets/models/sense-voice/model.int8.onnx` | 中文准确率高，VAD 分段后整段识别；首次加载约 1 秒，常驻内存约 200MB | 日常使用，推荐 |
| **Zipformer 流式** | `assets/models/streaming-zipformer/*` | 14M 小模型，逐字实时，内存小 | 低端机、追求最快响应 |

两个模型都已写进 `pubspec.yaml`，会随安装包一起分发。首次使用时从 Flutter 资产包释放到应用文档目录，之后直接复用。**不需要用户下载、解压、填路径。**

### 1.2 两遍解码（默认开启）

- 流式引擎先逐字出结果，保证“说完马上有反应”。
- 检测到端点后，把整段音频交给**内置 SenseVoice** 复检，再用复检结果覆盖草稿。
- 只在选择“流式”引擎时启用；选择 SenseVoice 时不会重复加载第二份模型。
- 流式引擎和复检引擎共用同一个 SenseVoice 实例，避免同时占用两份约 200MB 内存。
- 复检失败或模型未就绪时自动跳过，不影响主流程。

### 1.3 已移除的功能

| 功能 | 移除原因 |
|---|---|
| **FireRedASR2-CTC** | 需要额外下载约 500MB tar / 740MB 磁盘，低端 Android 容易 OOM |
| **streaming-zh 大流式模型** | 需要额外下载约 150MB，收益不足以抵消体积和启动时间 |
| **局域网 / 云端 ASR** | 需要用户自己部署 FunASR-Nano / Qwen3-ASR 服务，不符合“开箱即用” |
| **KWS 常开唤醒** | 同样需要单独下载约 40MB 关键词模型；按“零下载”原则一并移除 |

旧配置里如果还保存着 `firered`、`streaming_zh`、`lan`，`AppSettings.fromMap` 会自动回退到默认 SenseVoice，不会崩溃。

---

## 2. 识别流程修复

这些改动与模型无关，是本次体感提升的主要来源。

### 2.1 VAD 参数调优

文件：`lib/core/constants/app_constants.dart`、`lib/services/speech/asr_service.dart`

| 参数 | 旧值 | 新值 | 作用 |
|---|---|---|---|
| `threshold` | 0.50 | **0.40** | 减少远场/轻声被误判为静音 |
| `minSilenceDuration` | 0.35s | **0.50s** | 说话换气不再被切断 |
| `minSpeechDuration` | 0.20s | **0.25s** | 过滤极短噪声 |
| `maxSpeechDuration` | 10s | **30s** | 支持长句 |
| 段前预卷 | 无 | **300ms** | 补回句首轻辅音 |
| 段尾补静音 | 无 | **200ms** | 避免尾字被截断 |

### 2.2 35 秒音频环 + 精确预卷

文件：`lib/services/speech/voice_listening_service.dart`

- 持续维护最近 35 秒的连续音频环。
- VAD 输出一段语音时，按“段尾 - 尾静音”反推段首，从环里精确截取段前 300ms 补回去。
- 段尾再补 200ms 静音，保证“回答”“结束”等尾字完整。

### 2.3 结束词只允许句尾命中

文件：`lib/services/nlp/trigger_matcher.dart`

- 旧逻辑只要句子里出现“回答”就结束，导致“回答一下这个问题”被误判。
- 现在只接受**句尾**命中，最多容忍 3 个尾随字符（标点、语气词）。
- 同时保留近义收尾词兼容（请解答 / 回话 / 答复一下等）。

### 2.4 静音超时自动提交

文件：`lib/controllers/assistant_controller.dart`

- 旧逻辑：静音超时直接丢弃已识别内容。
- 新逻辑：如果已经识别到内容，自动提交，不再让用户重说。
- 只有完全没识别到内容时才回到待机。

### 2.5 同音词 / 领域词后处理

文件：`lib/services/speech/asr_post_processor.dart`、`assets/models/hr/lexicon.txt`

- 纯 Dart 实现，不依赖原生 `hr` 的 `replace.fst`。
- 修正“小曼 / 晓漫 / 小麦”“新起一个 / 新起一哥”等常见同音词。
- 内置少量领域词，避免把“侧边助手”识别成“侧边住手”。

### 2.6 引擎选择与自动回退

文件：`lib/controllers/assistant_controller.dart`

- 默认 SenseVoice；如果 SenseVoice 加载失败，自动回退到流式小模型。
- 选择流式时，如果流式加载失败，自动回退到 SenseVoice。
- 设置页保存后，如果话筒正在监听，会自动重启并切换到新引擎。
- 初始化期间切换设置或销毁控制器时，旧初始化任务不会再“复活”并抢回引擎。

### 2.7 流式热词

文件：`lib/services/speech/voice_listening_service.dart`

- 流式解码使用 `modified_beam_search`，把开始词、结束词、重置词、“侧边助手”等作为热词传入。
- 只有 `modified_beam_search` 支持热词；`greedy_search` 会静默丢弃，已在代码里显式判断。

---

## 3. 设置页

文件：`lib/ui/screens/settings_screen.dart`

- 识别模型下拉只剩两项：
  - 高精度离线 SenseVoice（内置，推荐）
  - 低延迟流式 Zipformer（内置小模型）
- 移除了模型目录、局域网 Base URL / API Key / 模型名 / 语言、KWS 开关。
- 保留：
  - 两遍解码开关（流式 + 内置 SenseVoice 复检）
  - 静音超时自动提交开关
  - 高级 VAD 滑杆（阈值、尾静音、最短/最长语音、预卷、尾垫）
- 页面底部明确提示：**两个模型都已内置，不需要下载或配置路径。**

---

## 4. 验证结果

### 4.1 静态检查

```text
flutter analyze --no-pub
No issues found!
```

### 4.2 自动化测试

```text
flutter test
All tests passed!
```

共 **143 项**测试通过，覆盖：

- SenseVoice / 流式引擎选择与回退
- 流式端到端识别（`streaming_zipformer_verification_test.dart`）
- VAD + SenseVoice 端到端（`vad_verification_test.dart`）
- 结束词句尾约束、近义收尾词
- 静音超时自动提交
- 两遍解码最终文本合并
- 设置序列化与旧配置升级
- 同音词后处理、CER 工具
- 唤醒、回声拒识、TTS 打断等既有逻辑

### 4.3 冒烟测试说明

仓库自带的 `assets/models/sense-voice/test_wavs/zh.wav` 参考文本是“开放时间早上九点至下午五点”。

- SenseVoice 能识别出完整的时间结构，但这条示例音频仍把“开放”识别成“派饭”，说明模型本身并非零错误；后处理词典目前只覆盖唤醒词/结束词，不强行纠正这类普通词。
- 14M 流式小模型会把“开放时间”识别成“差放时间”，错误明显更多，因此默认不选它。
- 这些只是单条链路冒烟，不代表整体 CER；真实选型请用 `tool/asr_benchmark_data/` 建 30–100 条自己的测试集，再跑 `tool/cer.dart`。

---

## 5. 关键文件

| 文件 | 作用 |
|---|---|
| `lib/services/speech/asr_service.dart` | SenseVoice / 流式两个引擎、VAD 工厂、资产模型路径解析、并发安全初始化 |
| `lib/services/speech/voice_listening_service.dart` | 麦克风采集、VAD、35 秒音频环、预卷/尾垫、两遍解码 |
| `lib/services/speech/asr_post_processor.dart` | 同音词 / 领域词后处理 |
| `lib/services/nlp/trigger_matcher.dart` | 结束词句尾约束、开始词粗筛 |
| `lib/controllers/assistant_controller.dart` | 引擎选择/回退、两遍解码合并、超时自动提交、初始化防竞态 |
| `lib/ui/screens/settings_screen.dart` | 精简后的识别引擎与 VAD 设置 UI |
| `lib/core/models/app_settings.dart` | 新配置字段、序列化、旧引擎值回退 |
| `lib/core/constants/app_constants.dart` | 引擎常量与 VAD 默认参数 |
| `assets/models/sense-voice/` | 内置 SenseVoice 模型 |
| `assets/models/streaming-zipformer/` | 内置 14M 流式模型 |
| `assets/models/silero_vad.onnx` | 内置 VAD 模型 |
| `assets/models/hr/lexicon.txt` | 后处理词典 |
| `tool/cer.dart` | CER 计算工具 |
| `tool/asr_benchmark_data/` | CER 测试集目录与示例 manifest |
| `test/asr_cer_benchmark_test.dart` | CER 基准测试入口 |
| `test/asr_engine_selection_test.dart` | 引擎选择/回退测试 |
| `test/streaming_zipformer_verification_test.dart` | 流式端到端冒烟测试 |
| `test/vad_verification_test.dart` | VAD + SenseVoice 端到端测试 |

---

## 6. 已删除的文件 / 功能

- `FireRedAsrService`
- `RemoteOpenAiAsrService` / `CloudWhisperAsrService`
- `KwsWakeService`
- `preferLargeModel` 及 streaming-zh 大模型加载逻辑
- `assets/models/kws/`
- `assets/models/streaming-zipformer-zh-2025/`
- `tool/download_models.ps1`
- `test/kws_wake_service_test.dart`
- `test/kws_detection_test.dart`
- `test/streaming_zh_model_test.dart`
- 设置页的局域网 ASR、模型目录、KWS 开关
- `AppSettings` 的 `asrLanBaseUrl` / `asrLanApiKey` / `asrLanModel` / `asrLanLanguage` / `asrModelDir` / `enableKwsWake`

---

## 7. 后续可选优化（都不需要用户下载）

1. **用真实测试集跑 CER**：录 30–100 条自己的语音，放到 `tool/asr_benchmark_data/`，分别跑 `sensevoice` 和 `streaming`，用数据决定默认引擎。
2. **LLM 上下文纠错**：把识别文本和最近对话一起交给大模型做轻量纠错，尤其适合人名、地名、专业词。
3. **标点 / ITN**：SenseVoice 已开启 `useInverseTextNormalization`，可以继续补中文标点模型。
4. **ROVER 融合**：用 SenseVoice 和流式两路结果做对齐/投票，进一步降低 CER，但会增加延迟。
5. **如果以后确实需要 KWS**：可以做成“首次启用时自动下载并解压”，而不是让用户手动找模型；本次按“零下载”原则先移除。

---

## 8. 一句话总结

现在安装包里自带 **SenseVoice + 14M 流式**两个模型，默认走 SenseVoice；VAD、预卷、结束词、超时、后处理都已修好，两遍解码用内置 SenseVoice 复检。用户**不需要下载任何东西**，也不需要配置服务器或模型路径。

---

## 9. 追加：Gemini 3.5 Transcribe Live（可选云端引擎）

### 9.1 接入方式

- 模型：`models/gemini-3.5-transcribe-live`（仅支持 `bidiGenerateContent` WebSocket 实时流）。
- 实现：`lib/services/speech/gemini_live_asr_service.dart`。
- 复用现有链路：Silero VAD 分段、300ms 预卷、200ms 尾垫、唤醒词/结束词、超时自动提交全部不变；Gemini 只替换“把一段音频转成文字”这一步。
- 连接策略：应用启动时建立一条长连接，多段语音复用；空闲被服务端关闭或识别超时后自动重连。
- 发送节奏：按约 10 倍实时速度上传（100ms 音频 / 10ms 间隔）。实测一次性灌入过快时，Gemini 只会返回 interim、不返回 `generationComplete`。
- 长录音：按 `voiceActivity` 的 `ACTIVITY_END` 偏移判断真正收尾；中间换气产生的多段结果会累积合并，不会只返回第一段。
- 失败回退：连接失败时 `AssistantController` 自动回退到内置 SenseVoice，不影响应用继续使用。

### 9.2 设置页

- 识别模型下拉新增：`Gemini 3.5 Transcribe Live（云端，需联网）`。
- 新增 `Gemini API Key`、`Gemini 模型` 两个输入框，以及“测试连接”按钮。
- Key 默认填入本次提供的 Key，可随时替换；音频会发送到 Google，需要联网并消耗 API 配额。

### 9.3 实测结果

仓库自带真实样例 `assets/models/sense-voice/test_wavs/zh.wav`（参考文本“开放时间早上九点至下午五点”）：

| 引擎 | 识别结果 | 结论 |
|---|---|---|
| Gemini 3.5 Transcribe Live | `开放时间早上9点至下午5点。` | 完全正确 |
| SenseVoice | `派饭时间早上9点至下午5点。` | “开放”误识别为“派饭” |

另外用 Windows 中文 TTS 生成了 15 条常见指令做对比（16kHz 单声道）：

| 引擎 | 平均 CER | 整句准确率 | 典型耗时 |
|---|---|---|---|
| SenseVoice | **3.33%** | **93.33%** | 55–111ms |
| Gemini 3.5 Transcribe Live | 4.55% | 86.67% | 约 0.6–1.2s（1.4–3.5s 音频） |

说明：

- CER 会把“百分之五十 vs 50%”“三点 vs 3点”这类 ITN 差异也算成错误，两种引擎都受影响。
- Gemini 在这批 TTS 上的真实错误主要是漏掉“今天”；“新起一个”曾被听成“新奇一个”，已加入后处理词典后修正。
- Gemini 的标点、数字规范化和自然断句更好；SenseVoice 在本地、低延迟、隐私和成本上明显更优。
- 结论：**Gemini 适合作为对比/备选，不建议替换默认的 SenseVoice**。默认引擎保持不变。

### 9.4 如何自行测试

1. 打开“助手设置 → 语音识别引擎”，选择 `Gemini 3.5 Transcribe Live（云端，需联网）`。
2. 展开“Gemini 3.5 Transcribe Live 配置”，确认 Key，点“测试连接”。
3. 保存后开启话筒，按平时习惯说“晓漫……回答”。
4. 对比日志中的 `[GeminiLiveAsrService] 识别完成 ...` 与 SenseVoice 的结果。
5. 如需批量跑 CER：

```powershell
$env:ASR_BENCH_DIR="tool/asr_benchmark_data"
$env:ASR_BENCH_ENGINE="gemini_live"   # sensevoice | streaming | gemini_live
$env:GEMINI_API_KEY="..."             # 可选，留空用内置默认 Key
flutter test --tags benchmark test/asr_cer_benchmark_test.dart
```

联网冒烟测试（默认跳过）：

```powershell
$env:GEMINI_LIVE_SMOKE="1"
flutter test test/gemini_live_smoke_test.dart
```

### 9.5 追加：偶尔识别成西语/韩文，是集成问题还是模型行为

结论：**主要是模型行为，但集成层确实漏传了官方支持的语言提示。**

#### 模型侧（正常行为）

- `gemini-3.5-transcribe-live` 是自动语种检测的转写模型（官方：85+ 语种、支持句中混说）。它按“实际听到的音频”决定输出语种，因此环境里的电视、音乐、旁人说话会被原样转写；短句、口音、底噪也可能让它判错。
- `inputAudioTranscription.languageCodes` 只是**偏置**，不是硬约束：实测韩语、英语音频即使传 `cmn-Hans-CN`，仍按原语种输出。
- v1beta 的 `inputTranscription` 响应里目前**不带** `languageCode` 字段（探针实测为空），所以无法用服务端返回的语种标签做过滤。

#### 集成侧（原实现的两个问题）

1. setup 里发的是空的 `inputAudioTranscription`，语言提示根本没传。之前“languageCodes 被忽略”的结论来自字段位置放错：放到 setup 顶层或 `generationConfig.speechConfig` 都会被**静默忽略**，必须嵌在 `inputAudioTranscription.languageCodes`（BCP-47）里。
2. 非中文结果只在结果侧静默丢弃，用户侧表现为“这句没反应”。

#### 已改

- `GeminiLiveAsrService.buildSetupMessage()` 固定发送 `languageCodes: ['cmn-Hans-CN']`（常量 `AppConstants.geminiAsrLanguageCode`，传空字符串可关闭）。
- 实测同一段粤语音频：不传提示会原样输出粤语，传 `cmn-Hans-CN` 会稳定转成普通话；中文样例识别结果不变（`开放时间早上9点至下午5点。`），长连接复用也正常。
- 仍保留 `isChineseLike()` 兜底：语言提示挡不住韩语/英语，结果侧过滤不能删。

#### 排查工具

```powershell
dart run tool/probes/gemini_lang_probe.dart                      # zh/ko 样例 × empty/hint-zh/hint-ko
dart run tool/probes/gemini_lang_probe.dart --wavs=yue.wav,en.wav --configs=empty,hint-zh
dart run tool/probes/gemini_lang_probe.dart --synth              # 静音 / 底噪 / 短句 / 低音量
```

探针结论补充：静音、-40dB/-30dB 白噪、1 秒短句都不会让模型“幻觉”出外语（直接无输出），所以看到西语/韩文更像是真的收到了外语声音，或模型对含噪中文判错；音频管线本身没有发坏数据（录音 16k/单声道/PCM16 与 `audio/pcm;rate=16000` 一致）。

> 注意：`build/` 里的 kernel 早于源码时，改动不会生效——改完必须重新 `flutter run` / `flutter build windows`。

---

## 10. Gemini 集成的时延拆解（是否“最佳实践”）

测量工具：`dart run tool/probes/gemini_timing_probe.dart`（5.59s 中文样例，按不同上传节奏重复）。

### 10.1 现状拆解

| 阶段 | 耗时 | 说明 |
|---|---|---|
| VAD 尾静音 | 0.40s | 说完到开始上传 |
| 上传 | ~0.88s | 100ms 音频 / 10ms 间隔；Windows 定时器粒度 15.6ms，实际约 6.4 倍实时 |
| 模型收尾 | ~0.65s | `audioStreamEnd` → 最终文本 |
| 收尾宽限 | 0.25s → **0（已去掉）** | 实测最终文本与 `generationComplete` 同批到达 |
| **说完到出字** | **~1.9s → ~1.53s** | 冒烟测试实测 1805ms → 1527ms |

### 10.2 上传节奏对照（audioStreamEnd 之后到最终文本）

| 节奏 | 上传耗时 | 最终文本延迟 |
|---|---|---|
| 6.4x（现状） | 0.88s | +618ms |
| 20x | 0.44s | +1055ms |
| 40x / 80x | 0.22s / 0.11s | 收不到最终文本 / `generationComplete` |
| 1x（边说边传） | 6.10s | **+204ms** |

从“首字节到最终文本”始终约 1.5s，这是模型解码速度决定的（RTF≈0.27），不是上传慢。**继续压上传节奏没有收益**；唯一有效的提速是边说边传，让解码在用户说话时就完成。

### 10.3 与最佳实践的差距（按影响排序）

1. **存储转发 → 边说边传（最大项）**：现在等 VAD 切完段才整段上传，说完后要再等约 1.5s。改成“VAD 判定说话期间就按 1x 推送音频”后，实测 `audioStreamEnd` → 最终文本只要 204ms。需要给 `AsrService` 增加流式接口（begin/append/end），由 `VoiceListeningService` 在说话期间转发；VAD、唤醒词、结束词逻辑不变，送出的音频内容也不变（不会多花钱、不会多听背景音）。**已实施，见 §11**。
2. **250ms 收尾宽限**：已去掉（最终文本先于 `generationComplete` 到达，无需再等）。
3. **`goAway` 未处理**：转写模型单会话上限约 10 分钟，服务端会先发 `goAway`。现在已解析并标记重连，空闲时主动收连接，避免下一段写进正在关闭的 socket。
4. **`customVocabulary` 未启用**：官方支持（最多 1000 词），把“晓漫 / 回答 / 新起一个”喂进去可减少“新起一个→新奇一个”这类错误，且不增加时延。目前靠后处理词典。
5. **其他细节已符合文档**：16k/单声道/PCM16、`audio/pcm;rate=16000`、`audioStreamEnd`、`responseModalities: ['TEXT']`、`inputAudioTranscription`、连接复用、超时兜底、失败回退。

> 补充：`turnComplete` 在转写模型上不会出现（多次实测均为 false），代码里的 `_turnCompleteReceived` 分支实际是死代码，保留无害。

## 11. 边说边传：把“说完到出字”从 1.5s 压到约 0.2s

### 11.1 改了什么

原来的路径是**存储转发**：VAD 判定说完（0.4s 尾静音）→ 切出一整段 → 整段按 6.4x 上传（0.88s）→ 模型解码（0.65s）≈ 1.9s。

现在改成**边说边传**：VAD 一旦判定“正在说话”，就按 1x 把麦克风音频实时推给 Gemini，模型在用户说话的同时解码；VAD 判定说完时，只剩最后约 0.2s 待解码。

接口（`lib/services/speech/asr_service.dart`）：

| 方法 | 作用 |
|---|---|
| `bool get supportsLiveStreaming` | 只有 `GeminiLiveAsrService` 返回 true；SenseVoice / Zipformer 仍走原来的分段路径 |
| `beginLiveUtterance(backfill, isStandbyWakeCheck:)` | VAD 置位时调用，`backfill` = 预卷 + 开口后到 VAD 置位之间已说出的音频（避免句首被削） |
| `appendLiveAudio(samples)` | 说话期间逐块追加 |
| `Future<String?> endLiveUtterance()` | 说话结束：发 `audioStreamEnd` 等最终文本。`null` = 没接住（调用方回退整段识别），`''` = 识别到了但被过滤 |

调用方在 `lib/services/speech/voice_listening_service.dart`：`_pumpLiveAudio`（判定开始/结束）、`_drainVadSegments(transcribe: false)`（VAD 段只留作回退）、`_finishLiveUtterance`（收尾 + 失败回退）。

保持不变的部分：唤醒词/结束词判定、待机态不回调中间结果、静音冷却窗、`_isTranscribing` 保护、SenseVoice 两遍解码。

### 11.2 关键设计

- **连接复用 + turn 串行**：用 `_turnIdle` 让上一段彻底收尾后才开新 turn，避免两段共用一条连接时 completer/定时器互相覆盖；连续两段实测均正确。
- **边说边传阶段不认服务端的收尾信号**：新增 `_audioEnded` 标记，只有发过 `audioStreamEnd` 之后 `generationComplete` 才算整句结束。否则用户说话中途服务端内部 VAD 的一段结束会把整句切成两半。
- **积压音频按 10x 补发**：连接刚建立时（或断线重连）积压的音频不能一次性灌进去（实测那样服务端收不到尾），按 10ms/100ms 节奏补发；这段时间用户通常还在说话，不影响“说完到出字”。
- **失败自动回退**：`endLiveUtterance()` 返回 `null`（连接失败/超时/静默 4s 兜底）时，用 VAD 弹出的整段音频走原来的 `transcribeSamples`，行为与改造前一致。
- **不再有未处理的异步错误**：`beginLiveUtterance` 是 fire-and-forget，`initialize()` / 启动 turn / `WebSocket.connect` 都挂了异常兜底，避免测试或后台被未处理异常打断。

### 11.3 实测（5.59s 中文样例）

| 指标 | 改造前 | 改造后 |
|---|---|---|
| 最后一块语音 → 出字（整链路，含 VAD 尾静音 0.4s） | ~1.9s | **0.18–0.29s**（VAD 尾静音另计） |
| `audioStreamEnd` → 最终文本 | +618ms | **~250ms** |
| 说话期间的中间结果条数 | 0（要等说完） | 7–9 条（结束词可提前命中） |

“整链路”口径：`test/voice_listening_live_test.dart` 用真实 Silero VAD + 真实 Gemini 服务，按 64ms 一块喂 `zh.wav`，测“最后一块语音送入 → `onTextRecognized`”。多次运行：181ms / 176ms / 287ms / 198ms。

因为说话期间就有中间结果，命中结束词的那条路径（`onPartialText` → `processPartialTranscript`）现在能**在用户说完之前**就提交大模型，实际感知还会更快。

### 11.4 验证方式

```powershell
dart analyze lib\services\speech\
$env:GEMINI_LIVE_SMOKE='1'
flutter test test\gemini_live_streaming_test.dart      # 直接调用 begin/append/end
flutter test test\voice_listening_live_test.dart       # 全链路（VAD → 边说边传 → 回调）
flutter test test\gemini_live_smoke_test.dart          # 分段模式回归
flutter test test\gemini_language_filter_test.dart     # 语言过滤 + setup 消息
```

未设置 `GEMINI_LIVE_SMOKE=1` 时这三个联网测试自动跳过。全量 `flutter test`：**159 通过 / 0 失败**。

> 联网测试里有一条已知噪音：`dart:io` 偶尔会把 `SocketException: Reading from a
> closed socket` 直接抛进 zone（不经过 `await`），`flutter_test` 会把它判成测试失败。
> 它与被测逻辑无关，`test/live_test_support.dart` 里用 `runZonedGuarded` 只兜这一条，
> 其它异常照常失败。

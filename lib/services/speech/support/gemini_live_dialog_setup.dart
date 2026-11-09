import 'dart:convert';
import 'dart:typed_data';

import '../../../core/constants/app_constants.dart';
import '../../../core/models/app_settings.dart';
import '../../../core/models/chat_message.dart';
import '../../llm/support/custom_tools_prompt_builder.dart';
import '../../llm/tools/custom_tool_manager.dart';
import 'gemini_live_capabilities.dart';

/// Gemini 3.8 Live 全双工会话协议消息构造器（无状态纯函数，便于脱离网络单测）
class GeminiLiveDialogSetup {
  const GeminiLiveDialogSetup._();

  static String apiKey(AppSettings settings) => settings.geminiApiKey.trim();

  static String model(AppSettings settings) {
    final raw = settings.geminiLiveModel.trim();
    final name = raw.isEmpty ? AppConstants.defaultGeminiLiveModel : raw;
    return name.startsWith('models/') ? name : 'models/$name';
  }

  static String voiceName(AppSettings settings) {
    final raw = settings.geminiLiveVoice.trim();
    if (AppConstants.geminiLiveVoices.contains(raw)) {
      return raw;
    }
    return AppConstants.defaultGeminiLiveVoice;
  }

  /// 构建全双工语音对话的系统提示词（注入日期、地理位置、LightRAG 与拍照规范）
  static String buildSystemInstruction(
    AppSettings settings, {
    String? currentAddress,
    DateTime? nowOverride,
    CustomToolManager? customToolManager,
  }) {
    final now = nowOverride ?? DateTime.now();
    final dateStr =
        '${now.year}年${now.month.toString().padLeft(2, '0')}月${now.day.toString().padLeft(2, '0')}日';
    final base = settings.systemPrompt.trim().isNotEmpty
        ? settings.systemPrompt.trim()
        : AppConstants.defaultSystemPrompt;

    final loc = (currentAddress != null && currentAddress.trim().isNotEmpty)
        ? currentAddress.trim()
        : settings.locationAddress.trim();
    final locSuffix = loc.isNotEmpty ? '\n（当前地理位置：$loc）' : '';

    final lightRagActive =
        settings.enableLightRag && settings.lightRagBaseUrl.trim().isNotEmpty;
    final lightRagSuffix = lightRagActive
        ? '\n（身份说明：与你对话的人是你的主人浩哥。你可以调用 lightrag_query 工具查询主人的个人信息及历史对话记录。）'
        : '';

    const visionRule = '\n（视觉拍照规范：当且仅当主人在当前最新指令中明确要求“拍照”、“拍一下”、“看看面前是什么”'
        '或需要观察新的现场画面时，才调用 capture_photo 工具；若只是针对已拍照片追问，严禁重复调用 capture_photo。）';

    const toolCallRule =
        '\n（工具交互与先行回应规范：在调用任何工具（如 capture_photo、lightrag_query、call_custom_tool、invoke_opencode 等）之前，'
        '必须先用自然、亲切、拟人的口吻向主人说明即将执行的操作（例如“好的浩哥，我这就拍照看一下”、“我帮你在知识库查一下”、“我这就调用工具处理”），'
        '严禁一声不吭静默调用。）';

    const intentRule = '\n（交谈意图判定与背景语音记录规范：请根据主人的语音内容判断主人是否有与你交谈的意图。'
        '若主人在呼唤你、向你提问或延续对话，请直接用语音自然回答；'
        '若判定主人并非在对你说话（例如与身边其他人交谈、接打电话、自言自语、背景旁白等无交谈意图），'
        '严禁发出任何语音回答，必须立即调用 record_background_speech 工具，并将探测到的主人原话填入 text 参数中。）';

    final customToolsSuffix = CustomToolsPromptBuilder.buildPromptSuffix(
      settings,
      manager: customToolManager,
    );

    return '$base$lightRagSuffix$visionRule$toolCallRule$intentRule$customToolsSuffix\n（当前现实日期：$dateStr）$locSuffix';
  }

  /// 构建 Gemini Live 原生工具声明列表（Google Search + LightRAG + 相机拍照 + OpenCode 自定义工具）
  static List<Map<String, dynamic>> buildTools(
    AppSettings settings, {
    bool allowCapturePhoto = true,
    bool nonBlocking = false,
  }) {
    final tools = <Map<String, dynamic>>[];

    if (settings.enableWebSearch) {
      tools.add(<String, dynamic>{'googleSearch': <String, dynamic>{}});
    }

    final functionDeclarations = <Map<String, dynamic>>[
      <String, dynamic>{
        'name': 'record_background_speech',
        'description':
            '当判定主人并非在对你说话（如与旁人交谈、打电话、自言自语、背景旁白等无交谈意图）时调用。调用时严禁输出任何语音，将探测到的语音文本传入 text。',
        'parameters': <String, dynamic>{
          'type': 'OBJECT',
          'properties': <String, dynamic>{
            'text': <String, dynamic>{
              'type': 'STRING',
              'description': '探测到的背景语音/旁白文本',
            },
            'reason': <String, dynamic>{
              'type': 'STRING',
              'description': '判定为无交谈意图的简短原因',
            },
          },
          'required': <String>['text'],
        },
      },
    ];

    if (settings.enableLightRag && settings.lightRagBaseUrl.trim().isNotEmpty) {
      functionDeclarations.add(<String, dynamic>{
        'name': 'lightrag_query',
        'description':
            '查询主人（浩哥）的个人知识库与长期记忆（包含身份背景、家庭偏好、历史重要信息等）。当问题涉及主人个人相关情况时优先调用。',
        'parameters': <String, dynamic>{
          'type': 'OBJECT',
          'properties': <String, dynamic>{
            'query': <String, dynamic>{
              'type': 'STRING',
              'description': '检索的关键词或自然语言问题',
            },
            'mode': <String, dynamic>{
              'type': 'STRING',
              'description': '检索模式：可选 mix、hybrid、local、global，默认 mix',
            },
          },
          'required': <String>['query'],
        },
      });
    }

    if (allowCapturePhoto) {
      functionDeclarations.add(<String, dynamic>{
        'name': 'capture_photo',
        'description': '调用随身摄像头拍摄一张当前眼前的实时照片。仅当主人明确要求拍照或识别眼前新物体/文字时调用。',
        'parameters': <String, dynamic>{
          'type': 'OBJECT',
          'properties': <String, dynamic>{
            'reason': <String, dynamic>{
              'type': 'STRING',
              'description': '触发拍照的原因简述',
            },
          },
        },
      });
    }

    if (settings.enableOpenCode) {
      functionDeclarations.add(<String, dynamic>{
        'name': 'call_custom_tool',
        'description':
            '调用已注册的持久化自定义工具（如定时闹钟、周期提醒、本地系统脚本等）。调用前请确保该工具存在于已注册工具列表中。调用前请先用自然亲切的语气向用户说明即将调用该工具做什么，然后再发起调用。',
        'parameters': <String, dynamic>{
          'type': 'OBJECT',
          'properties': <String, dynamic>{
            'tool_name': <String, dynamic>{
              'type': 'STRING',
              'description': '要调用的自定义工具唯一英文名称（必须与已注册工具列表中的名称一致）',
            },
            'arguments': <String, dynamic>{
              'type': 'STRING',
              'description':
                  '传递给该工具的 JSON 格式参数字符串，例如 {"action":"set","time":"08:00"}',
            },
          },
          'required': <String>['tool_name'],
        },
      });
      functionDeclarations.add(<String, dynamic>{
        'name': 'invoke_opencode',
        'description':
            '利用 OpenCode 自动化编写并执行代码。支持 persistent (创建持久化工具保存至工具库) 和 temporary (一次性就地执行复杂任务并自动销毁)。由于编写与运行代码耗时较长，调用前必须先用自然拟人的语气告知用户你打算创建或执行什么工具/任务并请用户稍候，切勿一声不吭直接静默调用。',
        'parameters': <String, dynamic>{
          'type': 'OBJECT',
          'properties': <String, dynamic>{
            'task_description': <String, dynamic>{
              'type': 'STRING',
              'description': '详细的任务描述与需求说明，包含输入输出规格与业务逻辑',
            },
            'persistence': <String, dynamic>{
              'type': 'STRING',
              'description':
                  '工具生命周期类型："persistent" 为持久化可复用工具；"temporary" 为一次性就地执行任务',
            },
            'tool_name': <String, dynamic>{
              'type': 'STRING',
              'description': '持久化工具的英文唯一标识（如 alarm_clock, pomodoro_timer）',
            },
            'tool_summary': <String, dynamic>{
              'type': 'STRING',
              'description': '持久化工具的简明中文功能描述，用于注册到系统提示词',
            },
            'parameters_hint': <String, dynamic>{
              'type': 'STRING',
              'description': '参数提示说明（例如 "time: 触发时间 HH:mm, message: 提醒内容"）',
            },
            'initial_arguments': <String, dynamic>{
              'type': 'STRING',
              'description': '首次创建并执行该工具时传入的具体参数 JSON 字符串',
            },
          },
          'required': <String>['task_description', 'persistence'],
        },
      });
    }

    if (nonBlocking) {
      for (final decl in functionDeclarations) {
        decl['behavior'] = 'NON_BLOCKING';
      }
    }

    if (functionDeclarations.isNotEmpty) {
      tools.add(<String, dynamic>{
        'functionDeclarations': functionDeclarations,
      });
    }

    return tools;
  }

  /// 构建 BidiGenerateContent 首帧 `setup` 消息（遵循 Gemini 3.8 Live 官方最佳实践）
  static Map<String, dynamic> buildSetupMessage({
    required AppSettings settings,
    String? modelOverride,
    String? voiceOverride,
    String? systemInstructionOverride,
    String? sessionResumptionHandle,
    bool allowCapturePhoto = true,
    CustomToolManager? customToolManager,
    bool advanced = false,
    String thinkingLevel = 'medium',
    bool includeThoughts = false,
    bool isPreview = false,
  }) {
    final resolvedModel =
        modelOverride != null && modelOverride.trim().isNotEmpty
            ? (modelOverride.trim().startsWith('models/')
                ? modelOverride.trim()
                : 'models/${modelOverride.trim()}')
            : model(settings);
    final resolvedVoice =
        voiceOverride != null && voiceOverride.trim().isNotEmpty
            ? voiceOverride.trim()
            : voiceName(settings);
    final sysText = systemInstructionOverride ??
        buildSystemInstruction(
          settings,
          customToolManager: customToolManager,
        );
    final tools = buildTools(
      settings,
      allowCapturePhoto: allowCapturePhoto,
      nonBlocking: advanced,
    );

    final effectiveThinkingLevel = (isPreview && advanced)
        ? 'low'
        : GeminiLiveCapabilities.normalizeThinkingLevel(thinkingLevel);
    final effectiveIncludeThoughts =
        (isPreview && advanced) ? false : includeThoughts;

    return <String, dynamic>{
      'setup': <String, dynamic>{
        'model': resolvedModel,
        'generationConfig': <String, dynamic>{
          'responseModalities': <String>['AUDIO'],
          'speechConfig': <String, dynamic>{
            'voiceConfig': <String, dynamic>{
              'prebuiltVoiceConfig': <String, dynamic>{
                'voiceName': resolvedVoice,
              },
            },
          },
          if (advanced)
            'thinkingConfig': <String, dynamic>{
              'thinkingLevel': effectiveThinkingLevel,
              'includeThoughts': effectiveIncludeThoughts,
            },
        },
        'systemInstruction': <String, dynamic>{
          'parts': <Map<String, dynamic>>[
            <String, dynamic>{'text': sysText},
          ],
        },
        // 语言提示必须放在 inputAudioTranscription.languageCodes；
        // 留空会让短句（"谁/什么"）被自动检测成西语等错误语种。
        'inputAudioTranscription': <String, dynamic>{
          'languageCodes': <String>[AppConstants.geminiAsrLanguageCode],
        },
        'outputAudioTranscription': <String, dynamic>{},
        'realtimeInputConfig': <String, dynamic>{
          'automaticActivityDetection': <String, dynamic>{
            'disabled': false,
            'startOfSpeechSensitivity': 'START_SENSITIVITY_HIGH',
            'endOfSpeechSensitivity': 'END_SENSITIVITY_LOW',
            'prefixPaddingMs': 300,
            'silenceDurationMs': 700,
          },
        },
        'contextWindowCompression': <String, dynamic>{
          'slidingWindow': <String, dynamic>{},
        },
        'sessionResumption': <String, dynamic>{
          if (sessionResumptionHandle != null &&
              sessionResumptionHandle.isNotEmpty)
            'handle': sessionResumptionHandle,
        },
        if (tools.isNotEmpty) 'tools': tools,
      },
    };
  }

  /// 构建原生音色试听 Setup 载荷（遵循试听收敛策略：若为 advanced，强制 thinkingLevel 为 low 且 includeThoughts 为 false）
  static Map<String, dynamic> buildPreviewSetupMessage({
    required AppSettings settings,
    String? modelOverride,
    String? voiceOverride,
    String? systemInstructionOverride,
    String? sessionResumptionHandle,
    bool allowCapturePhoto = false,
    CustomToolManager? customToolManager,
    bool advanced = false,
    String thinkingLevel = 'medium',
    bool includeThoughts = false,
  }) {
    return buildSetupMessage(
      settings: settings,
      modelOverride: modelOverride,
      voiceOverride: voiceOverride,
      systemInstructionOverride: systemInstructionOverride,
      sessionResumptionHandle: sessionResumptionHandle,
      allowCapturePhoto: allowCapturePhoto,
      customToolManager: customToolManager,
      advanced: advanced,
      thinkingLevel: thinkingLevel,
      includeThoughts: includeThoughts,
      isPreview: true,
    );
  }

  /// 构造实时 JPEG 图像帧上推消息 (`realtimeInput.video`)
  static String encodeRealtimeImageMessage(Uint8List jpegBytes) {
    return jsonEncode(<String, dynamic>{
      'realtimeInput': <String, dynamic>{
        'video': <String, dynamic>{
          'mimeType': 'image/jpeg',
          'data': base64Encode(jpegBytes),
        },
      },
    });
  }

  /// 构造用户文本直接输入消息 (`clientContent`)
  static Map<String, dynamic> buildClientTextMessage(
    String text, {
    bool turnComplete = true,
    Uint8List? imageBytes,
    String imageMimeType = 'image/jpeg',
  }) {
    return <String, dynamic>{
      'clientContent': <String, dynamic>{
        'turns': <Map<String, dynamic>>[
          <String, dynamic>{
            'role': 'user',
            'parts': <Map<String, dynamic>>[
              if (imageBytes != null && imageBytes.isNotEmpty)
                <String, dynamic>{
                  'inlineData': <String, dynamic>{
                    'mimeType': imageMimeType,
                    'data': base64Encode(imageBytes),
                  },
                },
              <String, dynamic>{'text': text},
            ],
          },
        ],
        'turnComplete': turnComplete,
      },
    };
  }

  /// 构造历史会话上下文注入消息 (`clientContent`, `turnComplete: false`)
  static Map<String, dynamic>? buildHistorySeedMessage(
    List<ChatMessage> history, {
    int maxMessages = 20,
  }) {
    final valid = history
        .where(
          (m) =>
              (m.role == 'user' || m.role == 'assistant') &&
              m.content.trim().isNotEmpty,
        )
        .toList();
    if (valid.isEmpty) return null;

    final slice = valid.length > maxMessages
        ? valid.sublist(valid.length - maxMessages)
        : valid;

    final turns = <Map<String, dynamic>>[
      for (final msg in slice)
        <String, dynamic>{
          'role': msg.role == 'assistant' ? 'model' : 'user',
          'parts': <Map<String, dynamic>>[
            <String, dynamic>{
              'text': msg.isUnintended
                  ? '[背景信息（无交谈意图）] ${msg.content.trim()}'
                  : msg.content.trim(),
            },
          ],
        },
    ];

    return <String, dynamic>{
      'clientContent': <String, dynamic>{
        'turns': turns,
        'turnComplete': false,
      },
    };
  }

  /// 构造单条工具调用执行结果载荷
  static Map<String, dynamic> buildFunctionResponse(
    String id,
    String name,
    String result, {
    String? scheduling,
  }) =>
      <String, dynamic>{
        'id': id,
        'name': name,
        'response': <String, dynamic>{'result': result},
        if (scheduling != null) 'scheduling': scheduling,
      };

  /// 工具调用响应调度策略：
  /// - record_background_speech: 'SILENT'（服务端静默记录无需回复）
  /// - 其余工具: 'WHEN_IDLE'（等待空闲时回复）
  static String schedulingFor(String toolName) =>
      toolName == 'record_background_speech' ? 'SILENT' : 'WHEN_IDLE';

  /// 构造工具执行结果响应 (`toolResponse.functionResponses`)
  static Map<String, dynamic> buildToolResponseMessage(
    List<Map<String, dynamic>> functionResponses,
  ) {
    return <String, dynamic>{
      'toolResponse': <String, dynamic>{
        'functionResponses': functionResponses,
      },
    };
  }

  /// 构建原生音色试听临时设置
  static AppSettings buildPreviewSettings(
    AppSettings settings, {
    required String voice,
    String? apiKey,
    String? model,
    bool? advanced,
  }) {
    return settings.copyWithMap({
      'geminiApiKey': apiKey?.trim().isNotEmpty == true
          ? apiKey!.trim()
          : settings.geminiApiKey,
      'geminiLiveModel': model?.trim().isNotEmpty == true
          ? model!.trim()
          : settings.geminiLiveModel,
      'geminiLiveVoice': voice,
      'enableTtsPlayback': true,
      'enableWebSearch': false,
      'enableLightRag': false,
      'enableOpenCode': false,
    });
  }

  /// 检查热更新配置是否需要重建 Live 会话连接
  static bool requiresReconnect(AppSettings old, AppSettings current) {
    return old.geminiApiKey != current.geminiApiKey ||
        old.geminiLiveModel != current.geminiLiveModel ||
        old.geminiLiveVoice != current.geminiLiveVoice ||
        old.systemPrompt != current.systemPrompt ||
        old.enableWebSearch != current.enableWebSearch ||
        old.enableLightRag != current.enableLightRag ||
        old.lightRagBaseUrl != current.lightRagBaseUrl ||
        old.enableOpenCode != current.enableOpenCode ||
        old.codeAgentProvider != current.codeAgentProvider ||
        old.openCodeCommand != current.openCodeCommand ||
        old.hermesCommand != current.hermesCommand;
  }
}

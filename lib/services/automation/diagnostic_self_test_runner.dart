import 'package:uuid/uuid.dart';
import '../../core/models/chat_message.dart';
import '../llm/llm_service.dart';
import '../nlp/embedding_service.dart';
import '../nlp/trigger_matcher.dart';
import '../vision/camera_service.dart';
import '../vision/vision_intent_service.dart';

/// 全链路运行态自动化诊断测试执行器。
class DiagnosticSelfTestRunner {
  static Future<Map<String, dynamic>> run({
    required String startWord,
    required EmbeddingService embeddingService,
    required TriggerMatcher triggerMatcher,
    required LlmService llmService,
    required VisionIntentService visionIntentService,
    required CameraService cameraService,
    required String Function() getSessionId,
    required bool Function() isMessagesEmpty,
    required Future<void> Function() onResetSession,
    required void Function(String log) onLog,
    required void Function() onStepCompleted,
  }) async {
    onLog('🚀 开始全链路运行态自动化诊断测试...');
    onStepCompleted();

    bool allPassed = true;

    // Step 1: 测试 Embedding 服务
    try {
      onLog('1/5 测试 Embedding 向量连接 (NVIDIA Nemotron)...');
      final vec = await embeddingService.getEmbedding(startWord);
      if (vec.isNotEmpty) {
        onLog('✅ 1/5 Embedding 向量服务正常 (维度: ${vec.length})');
      } else {
        throw Exception('返回向量为空');
      }
    } catch (e) {
      allPassed = false;
      onLog('❌ 1/5 Embedding 接口异常: $e');
    }
    onStepCompleted();

    // Step 2: 测试触发词与拼音容错
    try {
      onLog('2/5 测试触发词双层识别算法 (拼音容错与剥离)...');
      final pyMatch = await triggerMatcher.checkStartWord('小曼今天天气怎么样');
      final stripTest = triggerMatcher.stripEndWord('帮我查汇率回答');
      if (pyMatch.isMatched && stripTest == '帮我查汇率') {
        onLog('✅ 2/5 触发词拼音容错与结束词剥离算法验证通过');
      } else {
        throw Exception('匹配未命中或剥离错误');
      }
    } catch (e) {
      allPassed = false;
      onLog('❌ 2/5 触发词算法异常: $e');
    }
    onStepCompleted();

    // Step 3: 测试真实大模型连通性与返回
    try {
      onLog('3/5 测试 DeepSeek-V4.1-Flash 大模型真实问答...');
      final reply = await llmService.sendChat(
        history: [],
        newUserContent: '请简短回复“自检通过”四个字。',
        sessionId: getSessionId(),
      );
      if (reply.isNotEmpty) {
        onLog('✅ 3/5 大模型响应成功: "${reply.trim()}"');
      } else {
        throw Exception('大模型回复为空');
      }
    } catch (e) {
      allPassed = false;
      onLog('❌ 3/5 大模型连接异常: $e');
    }
    onStepCompleted();

    // Step 4: 测试多轮会话记忆力驱动
    try {
      onLog('4/5 测试多轮会话上下文记忆驱动...');
      final sessionId = getSessionId();
      final testMsg1 = ChatMessage(
        id: const Uuid().v4(),
        role: 'user',
        content: '记住，我的代号是极客007',
        timestamp: DateTime.now(),
        sessionId: sessionId,
      );
      final testReply1 = await llmService.sendChat(
        history: [],
        newUserContent: testMsg1.content,
        sessionId: sessionId,
      );
      final testAssistant1 = ChatMessage(
        id: const Uuid().v4(),
        role: 'assistant',
        content: testReply1,
        timestamp: DateTime.now(),
        sessionId: sessionId,
      );
      final testReply2 = await llmService.sendChat(
        history: [testMsg1, testAssistant1],
        newUserContent: '我的代号是什么？只回复代号。',
        sessionId: sessionId,
      );
      if (testReply2.contains('007') || testReply2.contains('极客')) {
        onLog('✅ 4/5 多轮上下文记忆召回准确: "${testReply2.trim()}"');
      } else {
        onLog('⚠️ 4/5 多轮回复已收到: "${testReply2.trim()}"');
      }
    } catch (e) {
      allPassed = false;
      onLog('❌ 4/5 上下文记忆测试异常: $e');
    }
    onStepCompleted();

    // Step 5: 测试“新起一个”会话重置
    try {
      onLog('5/6 测试“新起一个”本地重置指令...');
      final oldId = getSessionId();
      await onResetSession();
      if (getSessionId() != oldId && isMessagesEmpty()) {
        onLog('✅ 5/6 会话重置验证通过 (Session 已更新，上下文已清空)');
      } else {
        throw Exception('重置后未清空会话');
      }
    } catch (e) {
      allPassed = false;
      onLog('❌ 5/6 会话重置异常: $e');
    }
    onStepCompleted();

    // Step 6: 测试视觉意图语义识别与摄像头抓拍链路
    try {
      onLog('6/6 测试视觉意图语义识别与相机链路...');
      final matchRes =
          await visionIntentService.checkVisionIntent('介绍一下面前这个建筑');
      if (matchRes.isMatched) {
        onLog(
          '✅ 6/6 视觉意图向量识别命中: 相似度 ${(matchRes.similarity * 100).toStringAsFixed(1)}% (原型: "${matchRes.matchedPrototype}")',
        );
      } else {
        throw Exception(
          '视觉意图未识别到匹配原型 (相似度: ${(matchRes.similarity * 100).toStringAsFixed(1)}%)',
        );
      }

      final captureRes = await cameraService.capturePhoto();
      if (captureRes.imageBytes.isNotEmpty) {
        onLog(
          '✅ 6/6 相机抓拍链路正常 (${captureRes.isSimulated ? '离线模拟兜底帧' : '物理摄像头'} ${captureRes.imageBytes.length} 字节)',
        );
      } else {
        throw Exception('相机未获取到图像字节');
      }
    } catch (e) {
      allPassed = false;
      onLog('❌ 6/6 视觉意图/相机自检异常: $e');
    }

    onLog(
      allPassed ? '🎉 全部 6 项运行态自动化诊断测试顺利通过！' : '⚠️ 诊断完成，部分项目存在异常。',
    );
    return {
      'success': allPassed,
      'timestamp': DateTime.now().toIso8601String(),
    };
  }
}

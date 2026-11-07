import 'dart:convert';
import 'dart:typed_data';

import 'gemini_live_transcript_accumulator.dart' show GeminiLiveTranscriptText;

/// Gemini Live 服务端下发的单次工具调用请求
class GeminiLiveToolCall {
  final String id;
  final String name;
  final Map<String, dynamic> args;

  const GeminiLiveToolCall({
    required this.id,
    required this.name,
    required this.args,
  });
}

/// Gemini 3.8 Live 服务端双向流协议解析器与状态累积器
///
/// 纯逻辑状态机，不直接持有 WebSocket 或音频硬件句柄，便于 100% 脱离网络单元测试。
class GeminiLiveDialogProtocol {
  final int Function() activeConnectionId;
  final void Function()? onSetupComplete;
  final void Function(String message)? onServerError;
  final void Function(Map<dynamic, dynamic> info)? onGoAway;
  final void Function(String newHandle)? onSessionResumptionUpdate;
  final void Function()? onInterrupted;
  final void Function(Uint8List pcmBytes, int sampleRate)? onAudioChunk;
  final void Function(String text, {required bool isFinal})? onInputTranscript;
  final void Function(String delta, String fullText, {required bool isFinal})?
      onOutputTranscript;
  final void Function()? onModelTurnStarted;
  final void Function(String finalInput, String finalOutput)? onTurnComplete;
  final void Function(List<GeminiLiveToolCall> calls)? onToolCalls;

  String _inputBuffer = '';
  String _inputInterim = '';
  String _outputBuffer = '';
  String _fallbackModelTextBuffer = '';
  bool _inModelTurn = false;
  bool _wasInterrupted = false;
  String _lastInterruptedInput = '';

  GeminiLiveDialogProtocol({
    required this.activeConnectionId,
    this.onSetupComplete,
    this.onServerError,
    this.onGoAway,
    this.onSessionResumptionUpdate,
    this.onInterrupted,
    this.onAudioChunk,
    this.onInputTranscript,
    this.onOutputTranscript,
    this.onModelTurnStarted,
    this.onTurnComplete,
    this.onToolCalls,
  });

  String get currentInputText {
    final combined =
        _inputInterim.isNotEmpty ? '$_inputBuffer$_inputInterim' : _inputBuffer;
    return GeminiLiveTranscriptText.normalizeChineseSpacing(combined.trim());
  }

  String get currentOutputText {
    final raw =
        _outputBuffer.isNotEmpty ? _outputBuffer : _fallbackModelTextBuffer;
    return GeminiLiveTranscriptText.normalizeChineseSpacing(raw.trim());
  }

  void resetTurnState() {
    _inputBuffer = '';
    _inputInterim = '';
    _outputBuffer = '';
    _fallbackModelTextBuffer = '';
    _inModelTurn = false;
    _wasInterrupted = false;
    _lastInterruptedInput = '';
  }

  /// 处理一帧服务端 WebSocket 消息（支持 String 与 UTF-8 List<int>）
  void handleRawFrame(dynamic raw, int connectionId) {
    if (connectionId != activeConnectionId()) return;
    final map = decodeFrame(raw);
    if (map == null) return;

    if (map.containsKey('setupComplete')) {
      onSetupComplete?.call();
      return;
    }

    final error = map['error'];
    if (error != null) {
      final msg = error is Map
          ? (error['message']?.toString() ?? error.toString())
          : error.toString();
      onServerError?.call(msg);
      return;
    }

    final resumption = map['sessionResumptionUpdate'];
    if (resumption is Map) {
      final handle = resumption['newHandle']?.toString() ?? '';
      if (handle.isNotEmpty) {
        onSessionResumptionUpdate?.call(handle);
      }
    }

    final goAway = map['goAway'];
    if (goAway is Map) {
      onGoAway?.call(goAway);
    }

    final toolCall = map['toolCall'];
    if (toolCall is Map) {
      final rawCalls = toolCall['functionCalls'];
      if (rawCalls is List && rawCalls.isNotEmpty) {
        final calls = <GeminiLiveToolCall>[];
        for (var i = 0; i < rawCalls.length; i++) {
          final item = rawCalls[i];
          if (item is! Map) continue;
          final name = item['name']?.toString() ?? '';
          if (name.isEmpty) continue;
          final id = item['id']?.toString() ?? 'call_$i';
          final rawArgs = item['args'];
          final args = rawArgs is Map
              ? Map<String, dynamic>.from(rawArgs)
              : <String, dynamic>{};
          calls.add(GeminiLiveToolCall(id: id, name: name, args: args));
        }
        if (calls.isNotEmpty) {
          onToolCalls?.call(calls);
        }
      }
    }

    final serverContent = map['serverContent'];
    if (serverContent is! Map) return;

    // 1. 优先处理打断信号：用户开口打断时毫秒级清空播放缓冲
    if (serverContent['interrupted'] == true) {
      final prevInput = currentInputText;
      if (prevInput.isNotEmpty) {
        _lastInterruptedInput = prevInput;
      }
      _inModelTurn = false;
      _inputBuffer = '';
      _inputInterim = '';
      _outputBuffer = '';
      _fallbackModelTextBuffer = '';
      _wasInterrupted = serverContent['turnComplete'] != true;
      onInterrupted?.call();
      return;
    }

    // 2. 处理用户输入实时转写 (inputTranscription / interimInputTranscription)
    final interimIn = serverContent['interimInputTranscription'];
    if (interimIn is Map && interimIn['text'] is String) {
      _inputInterim = interimIn['text'] as String;
      final clean = currentInputText;
      if (clean.isNotEmpty) {
        if (_wasInterrupted &&
            !_inModelTurn &&
            _lastInterruptedInput.isNotEmpty &&
            clean == _lastInterruptedInput) {
          _inputBuffer = '';
          _inputInterim = '';
        } else {
          if (_lastInterruptedInput.isNotEmpty &&
              clean != _lastInterruptedInput) {
            _lastInterruptedInput = '';
          }
          onInputTranscript?.call(clean, isFinal: false);
        }
      }
    }

    final finalIn = serverContent['inputTranscription'];
    if (finalIn is Map && finalIn['text'] is String) {
      final piece = finalIn['text'] as String;
      if (piece.isNotEmpty) {
        // 如果之前只有 interim 没有累计 final，或服务端按增量分片吐出 inputTranscription
        if (_inputBuffer.isEmpty) {
          _inputBuffer = piece;
        } else if (piece.startsWith(_inputBuffer)) {
          _inputBuffer = piece;
        } else if (!_inputBuffer.endsWith(piece)) {
          _inputBuffer += piece;
        }
        _inputInterim = '';
        final clean = currentInputText;
        if (clean.isNotEmpty) {
          if (_wasInterrupted &&
              !_inModelTurn &&
              _lastInterruptedInput.isNotEmpty &&
              clean == _lastInterruptedInput) {
            _inputBuffer = '';
            _inputInterim = '';
          } else {
            if (_lastInterruptedInput.isNotEmpty &&
                clean != _lastInterruptedInput) {
              _lastInterruptedInput = '';
            }
            onInputTranscript?.call(clean, isFinal: false);
          }
        }
      }
    }

    // 3. 处理助手输出音频流 (modelTurn.parts[].inlineData) 与备选文本
    final modelTurn = serverContent['modelTurn'];
    if (modelTurn is Map) {
      final parts = modelTurn['parts'];
      if (parts is List) {
        for (final part in parts) {
          if (part is! Map) continue;
          if (part['thought'] == true) continue;

          final inlineData = part['inlineData'];
          if (inlineData is Map) {
            final mime = inlineData['mimeType']?.toString() ?? 'audio/pcm';
            final b64 = inlineData['data']?.toString() ?? '';
            if (mime.startsWith('audio/pcm') && b64.isNotEmpty) {
              if (!_inModelTurn) {
                _inModelTurn = true;
                _wasInterrupted = false;
                _lastInterruptedInput = '';
                onModelTurnStarted?.call();
              }
              try {
                final bytes = base64Decode(b64);
                if (bytes.isNotEmpty) {
                  final sampleRate = parseSampleRate(mime);
                  onAudioChunk?.call(bytes, sampleRate);
                }
              } catch (_) {}
            }
          }

          final textPart = part['text'];
          if (textPart is String && textPart.isNotEmpty) {
            if (!_inModelTurn) {
              _inModelTurn = true;
              _wasInterrupted = false;
              _lastInterruptedInput = '';
              onModelTurnStarted?.call();
            }
            _fallbackModelTextBuffer += textPart;
            if (_outputBuffer.isEmpty) {
              onOutputTranscript?.call(
                textPart,
                currentOutputText,
                isFinal: false,
              );
            }
          }
        }
      }
    }

    // 4. 处理助手语音输出实时转写 (outputTranscription)
    final outTrans = serverContent['outputTranscription'];
    if (outTrans is Map && outTrans['text'] is String) {
      final delta = outTrans['text'] as String;
      if (delta.isNotEmpty) {
        if (!_inModelTurn) {
          _inModelTurn = true;
          _wasInterrupted = false;
          _lastInterruptedInput = '';
          onModelTurnStarted?.call();
        }
        _outputBuffer += delta;
        onOutputTranscript?.call(
          delta,
          currentOutputText,
          isFinal: false,
        );
      }
    }

    // 5. 处理单轮结束信号 (turnComplete)
    if (serverContent['turnComplete'] == true) {
      if (_wasInterrupted && !_inModelTurn) {
        _wasInterrupted = false;
        _lastInterruptedInput = '';
        return;
      }
      final finalInText = currentInputText;
      final finalOutText = currentOutputText;
      if (finalInText.isNotEmpty) {
        onInputTranscript?.call(finalInText, isFinal: true);
      }
      if (finalOutText.isNotEmpty) {
        onOutputTranscript?.call('', finalOutText, isFinal: true);
      }
      resetTurnState();
      onTurnComplete?.call(finalInText, finalOutText);
    }
  }

  /// 从 mimeType（如 `audio/pcm;rate=24000`）提取采样率，默认 24000
  static int parseSampleRate(String mimeType) {
    final match = RegExp(r'rate\s*=\s*(\d+)').firstMatch(mimeType);
    if (match != null) {
      final parsed = int.tryParse(match.group(1)!);
      if (parsed != null && parsed > 0) return parsed;
    }
    return 24000;
  }

  static Map<String, dynamic>? decodeFrame(dynamic raw) {
    String? text;
    if (raw is String) {
      text = raw;
    } else if (raw is List<int>) {
      try {
        text = utf8.decode(raw);
      } catch (_) {
        return null;
      }
    }
    if (text == null || text.isEmpty) return null;
    try {
      final decoded = jsonDecode(text);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }
}

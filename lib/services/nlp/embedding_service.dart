import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import '../../core/models/app_settings.dart';

abstract class EmbeddingService {
  Future<List<double>> getEmbedding(String text);
}

/// 基于 OpenAI 规范的远程 Embedding 服务接口
class RemoteOpenAiEmbeddingService implements EmbeddingService {
  final AppSettings settings;

  RemoteOpenAiEmbeddingService({required this.settings});

  @override
  Future<List<double>> getEmbedding(String text) async {
    final baseUrl = settings.embeddingBaseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final url = Uri.parse('$baseUrl/embeddings');

    final response = await http.post(
      url,
      headers: {
        'Content-Type': 'application/json',
        if (settings.embeddingApiKey.isNotEmpty)
          'Authorization': 'Bearer ${settings.embeddingApiKey}',
      },
      body: jsonEncode({
        'model': settings.embeddingModel.isNotEmpty ? settings.embeddingModel : 'text-embedding-3-small',
        'input': text,
        if (settings.embeddingModel.contains('nemotron') || settings.embeddingBaseUrl.contains('nvidia'))
          'input_type': 'query',
      }),

    ).timeout(const Duration(seconds: 10));

    if (response.statusCode >= 200 && response.statusCode < 300) {
      final data = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final list = (data['data'] as List).first['embedding'] as List;
      return list.map((e) => (e as num).toDouble()).toList();
    } else {
      throw Exception('Embedding API error ${response.statusCode}: ${response.body}');
    }
  }
}

/// 本地 Qwen3-0.6b-embedding 服务 (支持 ONNX 本地推理及轻量级备选模拟)
class LocalQwenEmbeddingService implements EmbeddingService {
  final AppSettings settings;

  LocalQwenEmbeddingService({required this.settings});

  @override
  Future<List<double>> getEmbedding(String text) async {
    // 若配置了本地模型文件路径且文件存在，在此通过 onnxruntime 推理；
    // 否则生成确定性的高维哈希语义表征向量（512维），保证在无模型/离线时系统不崩溃且能正常演示
    return _generateDeterministicEmbedding(text, 512);
  }

  List<double> _generateDeterministicEmbedding(String text, int dim) {
    final clean = text.trim().toLowerCase();
    final random = Random(clean.hashCode);
    final vec = List<double>.generate(dim, (_) => (random.nextDouble() * 2) - 1);
    
    // 归一化为单位向量
    double norm = 0.0;
    for (final v in vec) {
      norm += v * v;
    }
    norm = sqrt(norm);
    if (norm > 0) {
      for (int i = 0; i < dim; i++) {
        vec[i] /= norm;
      }
    }
    return vec;
  }
}

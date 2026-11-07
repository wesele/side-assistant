import '../../core/models/audio_input_device_kind.dart';

/// 声纹模板的「声学域分组」存储器。
///
/// 为什么需要分组：CAM++ 是 16k 宽带模型，蓝牙 HFP/CVSD 是 8k 窄带。
/// 把两个域的 embedding 混进同一个质心，会同时压低本人得分、抬高异人得分，
/// 表现为「换蓝牙后声纹 0 次通过」。分组后，比对只使用当前音源对应域的模板，
/// 切换音源时旧域模板保留（切回内置麦可直接复用），不再需要手动清空声纹库。
///
/// 本类是纯 Dart 数据结构，不依赖模型与平台，便于单测覆盖。
class SpeakerDomainBook {
  SpeakerDomainBook(this.embeddings, this.domains)
      : assert(embeddings.length == domains.length);

  /// 从持久化数据构造。旧版本没有 domain 标签，缺失项一律按宽带兼容。
  factory SpeakerDomainBook.fromStored(
    List<List<double>> embeddings,
    List<String> storedDomains,
  ) {
    final aligned = List<String>.generate(
      embeddings.length,
      (i) => i < storedDomains.length &&
              storedDomains[i] == speakerDomainNarrowband
          ? speakerDomainNarrowband
          : speakerDomainWideband,
      growable: true,
    );
    return SpeakerDomainBook(
      List<List<double>>.from(embeddings),
      aligned,
    );
  }

  final List<List<double>> embeddings;
  final List<String> domains;

  int get length => embeddings.length;
  bool get isEmpty => embeddings.isEmpty;

  void removeAt(int index) {
    embeddings.removeAt(index);
    domains.removeAt(index);
  }

  void add(List<double> vector, String domain) {
    embeddings.add(vector);
    domains.add(domain);
  }

  /// 清空指定域的样本（同域内模板污染时重建基准用，不影响其它域）。
  int clearDomain(String domain) {
    var removed = 0;
    for (var i = domains.length - 1; i >= 0; i--) {
      if (domains[i] == domain) {
        removeAt(i);
        removed++;
      }
    }
    return removed;
  }

  /// 当前域的模板列表；若该域尚无模板则回退到全部，避免旧库升级后直接失灵。
  ({List<List<double>> templates, bool usedFallback}) templatesFor(
    String domain,
  ) {
    final same = <List<double>>[];
    for (var i = 0; i < embeddings.length; i++) {
      if (domains[i] == domain) same.add(embeddings[i]);
    }
    if (same.isNotEmpty) {
      return (templates: same, usedFallback: false);
    }
    return (
      templates: List<List<double>>.from(embeddings),
      usedFallback: embeddings.isNotEmpty,
    );
  }

  /// 按「每域上限 + 全局上限」裁剪，始终淘汰最旧的样本。
  void trim({int maxPerDomain = 5, int maxTotal = 10}) {
    final kept = <String, int>{};
    for (var i = embeddings.length - 1; i >= 0; i--) {
      final d = domains[i];
      final count = (kept[d] ?? 0) + 1;
      kept[d] = count;
      if (count > maxPerDomain) removeAt(i);
    }
    while (embeddings.length > maxTotal) {
      removeAt(0);
    }
  }
}

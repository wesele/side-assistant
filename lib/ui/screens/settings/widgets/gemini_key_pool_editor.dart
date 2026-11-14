import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/models/gemini_api_key_entry.dart';
import '../../../../core/models/gemini_live_key_pool.dart';

/// Gemini Live 多 API Key 池配置与实时 60s TPM 用量监控编辑器。
class GeminiKeyPoolEditor extends StatefulWidget {
  final List<GeminiApiKeyEntry> entries;
  final TextEditingController legacyApiKeyCtrl;
  final ValueChanged<List<GeminiApiKeyEntry>>? onChanged;
  final void Function({bool immediate}) onAutoSave;
  final GeminiLiveKeyPool? keyPool;

  const GeminiKeyPoolEditor({
    super.key,
    required this.entries,
    required this.legacyApiKeyCtrl,
    required this.onAutoSave,
    this.onChanged,
    this.keyPool,
  });

  @override
  State<GeminiKeyPoolEditor> createState() => _GeminiKeyPoolEditorState();
}

class _KeyRowControllers {
  final String id;
  final TextEditingController labelCtrl;
  final TextEditingController apiKeyCtrl;
  final TextEditingController tpmCtrl;
  bool obscure = true;

  _KeyRowControllers({
    required this.id,
    required String label,
    required String apiKey,
    required int tpmLimit,
  })  : labelCtrl = TextEditingController(text: label),
        apiKeyCtrl = TextEditingController(text: apiKey),
        tpmCtrl = TextEditingController(text: '$tpmLimit');

  void dispose() {
    labelCtrl.dispose();
    apiKeyCtrl.dispose();
    tpmCtrl.dispose();
  }
}

class _GeminiKeyPoolEditorState extends State<GeminiKeyPoolEditor> {
  final List<_KeyRowControllers> _rows = [];
  Timer? _statusTicker;
  bool _internalUpdate = false;

  GeminiLiveKeyPool get _pool => widget.keyPool ?? GeminiLiveKeyPool.instance;

  @override
  void initState() {
    super.initState();
    _syncRowsFromProps();
    _pool.addListener(_onPoolUpdated);
    widget.legacyApiKeyCtrl.addListener(_onLegacyCtrlChanged);
    _syncStatusTicker();
  }

  @override
  void didUpdateWidget(GeminiKeyPoolEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.keyPool != widget.keyPool) {
      (oldWidget.keyPool ?? GeminiLiveKeyPool.instance)
          .removeListener(_onPoolUpdated);
      _pool.addListener(_onPoolUpdated);
    }
    if (oldWidget.legacyApiKeyCtrl != widget.legacyApiKeyCtrl) {
      oldWidget.legacyApiKeyCtrl.removeListener(_onLegacyCtrlChanged);
      widget.legacyApiKeyCtrl.addListener(_onLegacyCtrlChanged);
    }
    if (!_internalUpdate &&
        !GeminiApiKeyEntry.listEquals(oldWidget.entries, widget.entries)) {
      _syncRowsFromProps();
    }
    _syncStatusTicker();
  }

  @override
  void dispose() {
    _statusTicker?.cancel();
    _pool.removeListener(_onPoolUpdated);
    widget.legacyApiKeyCtrl.removeListener(_onLegacyCtrlChanged);
    for (final row in _rows) {
      row.dispose();
    }
    super.dispose();
  }

  void _onPoolUpdated() {
    if (!mounted) return;
    _syncStatusTicker();
    setState(() {});
  }

  void _onLegacyCtrlChanged() {
    if (_internalUpdate) return;
    final legacy = widget.legacyApiKeyCtrl.text.trim();
    if (_rows.length == 1 && _rows.first.apiKeyCtrl.text.trim() != legacy) {
      _rows.first.apiKeyCtrl.text = legacy;
      if (mounted) setState(() {});
    }
  }

  void _syncRowsFromProps() {
    for (final r in _rows) {
      r.dispose();
    }
    _rows.clear();

    if (widget.entries.isNotEmpty) {
      for (final e in widget.entries) {
        _rows.add(_KeyRowControllers(
          id: e.id,
          label: e.label,
          apiKey: e.apiKey,
          tpmLimit: e.tpmLimit,
        ));
      }
    } else {
      final legacy = widget.legacyApiKeyCtrl.text.trim();
      _rows.add(_KeyRowControllers(
        id: legacy.isNotEmpty ? 'legacy-1' : 'key-1',
        label: legacy.isNotEmpty ? '默认 Key' : 'Key 1',
        apiKey: legacy,
        tpmLimit: AppConstants.defaultGeminiLiveTpmLimit,
      ));
    }
  }

  void _syncStatusTicker() {
    final anyActive = _rows.any((r) {
      final k = r.apiKeyCtrl.text.trim();
      if (k.isEmpty) return false;
      final st = _pool.getKeyStatus(k);
      return st.coolingDown || st.tpm > 0;
    });
    if (anyActive && _statusTicker == null) {
      _statusTicker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        _syncStatusTicker();
        setState(() {});
      });
    } else if (!anyActive && _statusTicker != null) {
      _statusTicker?.cancel();
      _statusTicker = null;
    }
  }

  List<GeminiApiKeyEntry> _buildNormalizedEntries() {
    final raw = <GeminiApiKeyEntry>[];
    for (var i = 0; i < _rows.length; i++) {
      final r = _rows[i];
      final key = r.apiKeyCtrl.text.trim();
      if (key.isEmpty) continue;
      final tpm = int.tryParse(r.tpmCtrl.text.trim()) ??
          AppConstants.defaultGeminiLiveTpmLimit;
      raw.add(GeminiApiKeyEntry(
        id: r.id,
        label: r.labelCtrl.text.trim().isEmpty
            ? 'Key ${raw.length + 1}'
            : r.labelCtrl.text.trim(),
        apiKey: key,
        tpmLimit: tpm >= 1000 ? tpm : 1000,
      ));
    }
    return GeminiApiKeyEntry.normalizeList(raw);
  }

  void _emitChanges({bool immediateSave = false}) {
    final entries = _buildNormalizedEntries();
    final primaryKey = entries.isNotEmpty ? entries.first.apiKey : '';
    _internalUpdate = true;
    try {
      if (widget.legacyApiKeyCtrl.text.trim() != primaryKey) {
        widget.legacyApiKeyCtrl.text = primaryKey;
      }
      widget.onChanged?.call(entries);
    } finally {
      _internalUpdate = false;
    }
    widget.onAutoSave(immediate: immediateSave);
    if (mounted) setState(() {});
  }

  void _addRow() {
    final idx = _rows.length + 1;
    setState(() {
      _rows.add(_KeyRowControllers(
        id: 'key-${DateTime.now().millisecondsSinceEpoch}-$idx',
        label: 'Key $idx',
        apiKey: '',
        tpmLimit: AppConstants.defaultGeminiLiveTpmLimit,
      ));
    });
  }

  void _removeRow(int index) {
    if (_rows.length <= 1) {
      _rows.first.labelCtrl.text = 'Key 1';
      _rows.first.apiKeyCtrl.clear();
      _rows.first.tpmCtrl.text = '${AppConstants.defaultGeminiLiveTpmLimit}';
    } else {
      final removed = _rows.removeAt(index);
      removed.dispose();
    }
    _emitChanges(immediateSave: true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Gemini API Key 池（按 60s TPM 轮询 · ≥80% 自动切换）',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            TextButton.icon(
              key: const Key('add_gemini_key_button'),
              onPressed: _addRow,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('添加 Key'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        for (var i = 0; i < _rows.length; i++) _buildKeyCard(theme, i),
      ],
    );
  }

  Widget _buildKeyCard(ThemeData theme, int index) {
    final row = _rows[index];
    final keyStr = row.apiKeyCtrl.text.trim();
    final rawTpm = int.tryParse(row.tpmCtrl.text.trim()) ??
        AppConstants.defaultGeminiLiveTpmLimit;
    final configuredTpm = rawTpm >= 1000 ? rawTpm : 1000;
    final status = keyStr.isEmpty
        ? null
        : _pool.getKeyStatus(
            GeminiApiKeyEntry(
              id: row.id,
              label: row.labelCtrl.text.trim(),
              apiKey: keyStr,
              tpmLimit: configuredTpm,
            ),
          );

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      color: theme.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: row.labelCtrl,
                    decoration: const InputDecoration(
                      labelText: '项目名称/备注',
                      isDense: true,
                    ),
                    onChanged: (_) => _emitChanges(),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 110,
                  child: TextField(
                    controller: row.tpmCtrl,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                      labelText: 'TPM 上限',
                      isDense: true,
                    ),
                    onChanged: (_) => _emitChanges(),
                  ),
                ),
                IconButton(
                  tooltip: _rows.length <= 1 ? '清空此 Key' : '删除此 Key',
                  icon: Icon(
                    Icons.delete_outline,
                    size: 20,
                    color: theme.colorScheme.error,
                  ),
                  onPressed: () => _removeRow(index),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: row.apiKeyCtrl,
              obscureText: row.obscure,
              decoration: InputDecoration(
                labelText: 'Gemini API Key #${index + 1}',
                hintText: 'AIza...',
                isDense: true,
                suffixIcon: IconButton(
                  icon: Icon(
                    row.obscure ? Icons.visibility : Icons.visibility_off,
                    size: 18,
                  ),
                  onPressed: () => setState(() => row.obscure = !row.obscure),
                ),
              ),
              onChanged: (_) => _emitChanges(),
            ),
            if (status != null) ...[
              const SizedBox(height: 8),
              _buildMeter(theme, status),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildMeter(ThemeData theme, GeminiLiveKeyStatus status) {
    final pct = (status.ratio * 100).round().clamp(0, 100);
    final Color barColor;
    final String badge;
    if (status.coolingDown) {
      barColor = theme.colorScheme.error;
      final sec = (status.cooldownRemainingMs / 1000).ceil();
      badge = '429 冷却中 ${sec}s';
    } else if (status.overThreshold) {
      barColor = Colors.orange.shade700;
      badge = '≥80% 待切换';
    } else {
      barColor = theme.colorScheme.primary;
      badge = '可用';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '60s TPM: ${status.tpm} / ${status.limit} ($pct%)',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            Text(
              badge,
              style: theme.textTheme.labelSmall?.copyWith(
                color: barColor,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: status.ratio.clamp(0.0, 1.0),
            minHeight: 5,
            color: barColor,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
          ),
        ),
      ],
    );
  }
}

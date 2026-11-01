import 'package:flutter/material.dart';
import '../../../../controllers/assistant_controller.dart';
import '../../../../core/constants/app_constants.dart';
import '../../../../core/models/device_options.dart';
import 'settings_shared.dart';

class CameraVisionSection extends StatefulWidget {
  final AssistantController controller;
  final bool enableVisionIntent;
  final ValueChanged<bool> onEnableVisionIntentChanged;

  final String captureSource;
  final ValueChanged<String> onCaptureSourceChanged;

  final String cameraLensDirection;
  final ValueChanged<String> onCameraLensDirectionChanged;

  final int cameraResolutionWidth;
  final int cameraResolutionHeight;
  final void Function(int width, int height) onCameraResolutionChanged;

  final int cameraSendShortEdge;
  final ValueChanged<int> onCameraSendShortEdgeChanged;

  final String nanoWlanInterface;
  final ValueChanged<String> onNanoWlanInterfaceChanged;

  final TextEditingController nanoBleAddressCtrl;
  final List<String> availableWlanInterfaces;

  final int cameraKeepAliveMinutes;
  final ValueChanged<int> onCameraKeepAliveMinutesChanged;

  final bool isAndroid;
  final bool? cameraPermissionGranted;
  final VoidCallback onGrantCameraPermission;

  final void Function({bool immediate}) onAutoSave;

  const CameraVisionSection({
    super.key,
    required this.controller,
    required this.enableVisionIntent,
    required this.onEnableVisionIntentChanged,
    required this.captureSource,
    required this.onCaptureSourceChanged,
    required this.cameraLensDirection,
    required this.onCameraLensDirectionChanged,
    required this.cameraResolutionWidth,
    required this.cameraResolutionHeight,
    required this.onCameraResolutionChanged,
    required this.cameraSendShortEdge,
    required this.onCameraSendShortEdgeChanged,
    required this.nanoWlanInterface,
    required this.onNanoWlanInterfaceChanged,
    required this.nanoBleAddressCtrl,
    required this.availableWlanInterfaces,
    required this.cameraKeepAliveMinutes,
    required this.onCameraKeepAliveMinutesChanged,
    required this.isAndroid,
    required this.cameraPermissionGranted,
    required this.onGrantCameraPermission,
    required this.onAutoSave,
  });

  @override
  State<CameraVisionSection> createState() => _CameraVisionSectionState();
}

class _CameraVisionSectionState extends State<CameraVisionSection> {
  bool _isTestingNano = false;
  String _nanoTestResult = '';

  List<CameraResolution> _supportedCameraResolutions = [];
  bool _isLoadingCameraResolutions = false;

  @override
  void initState() {
    super.initState();
    if (widget.isAndroid && widget.captureSource == AppConstants.captureSourceLocal) {
      _loadSupportedCameraResolutions();
    }
  }

  Future<void> _loadSupportedCameraResolutions() async {
    if (!widget.isAndroid) return;
    if (mounted) {
      setState(() => _isLoadingCameraResolutions = true);
    }
    final list = await widget.controller.getAvailableCameraResolutions(
      lensDirection: widget.cameraLensDirection,
    );
    if (!mounted) return;
    setState(() {
      _supportedCameraResolutions = list;
      _isLoadingCameraResolutions = false;
      if (list.isNotEmpty &&
          widget.cameraResolutionWidth > 0 &&
          !list.any((r) =>
              r.width == widget.cameraResolutionWidth &&
              r.height == widget.cameraResolutionHeight)) {
        widget.onCameraResolutionChanged(0, 0);
      }
    });
  }

  Widget _buildCameraResolutionSelector() {
    final selectedKey = widget.cameraResolutionWidth > 0
        ? '${widget.cameraResolutionWidth}x${widget.cameraResolutionHeight}'
        : 'auto';

    final items = <DropdownMenuItem<String>>[
      const DropdownMenuItem(
        value: 'auto',
        child: Text('自动（1600×1200 就近选档）'),
      ),
      ..._supportedCameraResolutions.map(
        (r) => DropdownMenuItem<String>(
          value: r.key,
          child: Text(r.label),
        ),
      ),
    ];

    if (!items.any((item) => item.value == selectedKey)) {
      items.add(
        DropdownMenuItem<String>(
          value: selectedKey,
          child: Text(
              '${widget.cameraResolutionWidth} × ${widget.cameraResolutionHeight}（当前配置）'),
        ),
      );
    }

    return buildLabeledField(
      '拍照分辨率',
      DropdownButtonFormField<String>(
        value: selectedKey,
        isExpanded: true,
        decoration: InputDecoration(
          suffixIcon: _isLoadingCameraResolutions
              ? const Padding(
                  padding: EdgeInsets.all(14),
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : null,
        ),
        items: items,
        onChanged: _isLoadingCameraResolutions
            ? null
            : (v) {
                if (v == null) return;
                if (v == 'auto') {
                  widget.onCameraResolutionChanged(0, 0);
                  widget.onAutoSave(immediate: true);
                  return;
                }
                final res = CameraResolution.fromKey(v);
                if (res == null) return;
                widget.onCameraResolutionChanged(res.width, res.height);
                widget.onAutoSave(immediate: true);
              },
      ),
    );
  }

  Widget _buildSendCompressionSelector() {
    return buildLabeledField(
      '发送前压缩',
      DropdownButtonFormField<int>(
        value: widget.cameraSendShortEdge,
        isExpanded: true,
        decoration: const InputDecoration(),
        items: const [
          DropdownMenuItem(
            value: 480,
            child: Text('480p'),
          ),
          DropdownMenuItem(
            value: 720,
            child: Text('720p'),
          ),
          DropdownMenuItem(
            value: 1080,
            child: Text('1080p'),
          ),
        ],
        onChanged: (v) {
          if (v != null) {
            widget.onCameraSendShortEdgeChanged(v);
            widget.onAutoSave(immediate: true);
          }
        },
      ),
    );
  }

  Widget _buildCameraPermissionBanner(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withOpacity(0.5),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.error.withOpacity(0.4)),
      ),
      child: Row(
        children: [
          Icon(Icons.no_photography_outlined,
              size: 20, color: theme.colorScheme.error),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '未授予相机权限',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 13,
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
          ),
          TextButton(
            onPressed: widget.onGrantCameraPermission,
            child: const Text('开启权限'),
          ),
        ],
      ),
    );
  }

  Future<void> _testNanoConnection() async {
    setState(() {
      _isTestingNano = true;
      _nanoTestResult = '正在启动 Nano 链路检测...';
    });
    try {
      final result = await widget.controller.testNanoLink(
        settings: widget.controller.settings,
        bleAddressOverride: widget.nanoBleAddressCtrl.text,
        wlanInterface: widget.nanoWlanInterface,
        onProgress: (status) {
          if (mounted) setState(() => _nanoTestResult = status);
        },
        onBleAddressFound: (addr) {
          widget.nanoBleAddressCtrl.text = addr;
        },
      );
      if (mounted) {
        setState(() => _nanoTestResult = result.message);
      }
    } finally {
      if (mounted) {
        setState(() => _isTestingNano = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        buildSectionHeader(
            context, '摄像头与大模型视觉拍照（工具调用）', Icons.camera_alt_outlined),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('启用大模型相机拍照能力'),
                  subtitle: const Text('大模型可自主调用 capture_photo 工具拍摄现场画面并结合视觉理解回答'),
                  value: widget.enableVisionIntent,
                  onChanged: (v) {
                    widget.onEnableVisionIntentChanged(v);
                    widget.onAutoSave(immediate: true);
                  },
                ),
                if (widget.enableVisionIntent) ...[
                  if (widget.isAndroid &&
                      widget.cameraPermissionGranted == false &&
                      widget.captureSource == AppConstants.captureSourceLocal) ...[
                    _buildCameraPermissionBanner(theme),
                  ],
                  const Divider(height: 24),
                  const SizedBox(height: 12),
                  buildLabeledField(
                    '拍照源',
                    DropdownButtonFormField<String>(
                      isExpanded: true,
                      value: widget.captureSource,
                      decoration: const InputDecoration(),
                      items: const [
                        DropdownMenuItem(
                          value: AppConstants.captureSourceLocal,
                          child: Text('本地摄像头'),
                        ),
                        DropdownMenuItem(
                          value: AppConstants.captureSourceNano,
                          child: Text('DJI Osmo Nano'),
                        ),
                      ],
                      onChanged: (v) {
                        if (v != null) {
                          widget.onCaptureSourceChanged(v);
                          widget.onAutoSave(immediate: true);
                        }
                      },
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (widget.captureSource == AppConstants.captureSourceLocal) ...[
                    buildLabeledField(
                      '摄像头朝向',
                      DropdownButtonFormField<String>(
                        isExpanded: true,
                        value: widget.cameraLensDirection,
                        decoration: const InputDecoration(),
                        items: const [
                          DropdownMenuItem(
                            value: 'back',
                            child: Text('后置摄像头'),
                          ),
                          DropdownMenuItem(
                            value: 'front',
                            child: Text('前置摄像头'),
                          ),
                        ],
                        onChanged: (v) {
                          if (v == null || v == widget.cameraLensDirection) return;
                          widget.onCameraLensDirectionChanged(v);
                          widget.onCameraResolutionChanged(0, 0);
                          widget.onAutoSave(immediate: true);
                          _loadSupportedCameraResolutions();
                        },
                      ),
                    ),
                    if (widget.isAndroid) ...[
                      const SizedBox(height: 12),
                      _buildCameraResolutionSelector(),
                      const SizedBox(height: 12),
                      _buildSendCompressionSelector(),
                    ],
                  ] else ...[
                    buildLabeledField(
                      'Nano 专用无线网卡',
                      DropdownButtonFormField<String>(
                        isExpanded: true,
                        value: widget.availableWlanInterfaces
                                    .contains(widget.nanoWlanInterface) ||
                                widget.nanoWlanInterface == 'auto'
                            ? widget.nanoWlanInterface
                            : 'auto',
                        decoration: const InputDecoration(),
                        items: [
                          const DropdownMenuItem(
                            value: 'auto',
                            child: Text('自动选择'),
                          ),
                          ...widget.availableWlanInterfaces
                              .map((iface) => DropdownMenuItem(
                                    value: iface,
                                    child: Text(iface),
                                  )),
                        ],
                        onChanged: (v) {
                          if (v != null) {
                            widget.onNanoWlanInterfaceChanged(v);
                            widget.onAutoSave(immediate: true);
                          }
                        },
                      ),
                    ),
                    const SizedBox(height: 12),
                    buildLabeledField(
                      'Nano 蓝牙 MAC 地址 (可选)',
                      TextField(
                        controller: widget.nanoBleAddressCtrl,
                        decoration: const InputDecoration(),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        OutlinedButton.icon(
                          icon: _isTestingNano
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2),
                                )
                              : const Icon(Icons.wifi_tethering),
                          label:
                              Text(_isTestingNano ? '正在测试...' : '测试 Nano 连接'),
                          onPressed:
                              _isTestingNano ? null : _testNanoConnection,
                        ),
                        if (_nanoTestResult.isNotEmpty) ...[
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              _nanoTestResult,
                              style: TextStyle(
                                fontSize: 12,
                                color: _nanoTestResult.startsWith('✅')
                                    ? Colors.green.shade800
                                    : (_nanoTestResult.startsWith('❌')
                                        ? Colors.red.shade800
                                        : Colors.blue.shade800),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Text(
                        widget.cameraKeepAliveMinutes == 0
                            ? '空闲关闭: 0 分钟'
                            : '空闲关闭: ${widget.cameraKeepAliveMinutes} 分钟',
                      ),
                      Expanded(
                        child: Slider(
                          value: widget.cameraKeepAliveMinutes
                              .toDouble()
                              .clamp(0.0, 10.0),
                          min: 0,
                          max: 10,
                          divisions: 10,
                          label: '${widget.cameraKeepAliveMinutes} 分钟',
                          onChanged: (v) {
                            widget.onCameraKeepAliveMinutesChanged(v.round());
                            widget.onAutoSave();
                          },
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

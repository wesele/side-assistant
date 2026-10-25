# ASR CER 基准数据

这个目录用于放你自己的中文测试集。仓库不内置音频，避免体积膨胀。

## 1. 录音要求

- 16kHz、单声道、16-bit PCM WAV
- 每条 1–10 秒，尽量覆盖：安静/嘈杂、近场/远场、普通话/口音、短指令/长句
- 建议至少 30 条，才能看出稳定差异

## 2. manifest.json

```json
[
  {"wav": "001.wav", "ref": "今天天气怎么样", "wake": false},
  {"wav": "002.wav", "ref": "晓漫", "wake": true},
  {"wav": "003.wav", "ref": "帮我查一下明天的汇率", "wake": false}
]
```

- `ref`：人工标注的标准文本（不要带标点也可以，CER 会忽略标点）
- `wake`：可选，true 表示这条是唤醒词样本，会额外统计唤醒命中率

## 3. 运行

```powershell
$env:ASR_BENCH_DIR="tool/asr_benchmark_data"
$env:ASR_BENCH_ENGINE="sensevoice"   # sensevoice | streaming
flutter test --tags benchmark test/asr_cer_benchmark_test.dart
```

如果要设置通过阈值：

```powershell
$env:ASR_BENCH_MAX_CER="0.15"   # 平均 CER 超过 15% 就失败
```

## 4. 建议对比顺序

1. `sensevoice`（基线，默认）
2. `streaming`（内置小流式模型）

两个模型都已内置，不需要下载；用同一批音频各跑一遍即可。

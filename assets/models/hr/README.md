# HR / 同音词替换

本目录用于存放 ASR 后处理用的同音词与领域词表。

- `lexicon.txt`：纯 Dart 后处理规则，所有引擎通用，格式见文件头。
- 如果你使用 sherpa-onnx 原生 `hr`（HomophoneReplacer），还需要一个
  `replace.fst`。该文件需要用 `sherpa-onnx-cli` 从 `lexicon.txt` 生成，
  本项目默认不依赖它；`AsrPostProcessor` 已经覆盖了同样的场景。

修改 `lexicon.txt` 后无需重新编译，重启应用即可生效（桌面端直接读取工程目录，
移动端会从资产包读取）。

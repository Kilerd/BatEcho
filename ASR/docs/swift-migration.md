# BatEcho 原生 Swift / MLX 迁移

> 本文的 84 条迁移对照证据保留更名之前的原始路径和哈希。更名后的正式签名兼容修复及 7 条文件集成验证见 [macOS 打包与签名](../../docs/macos-release.md)。

## 结论

可以完整移除应用的 Python 运行时。当前 BatEcho 使用 Swift 实现模型下载、音频处理、FireRed 推理、热词解码、Silero VAD 和拼音纠错，已接入原有 Fn 录音和上屏流程。MLX Swift 底层使用 MLX C++ / Metal；“原生 Swift”指产品代码和模型推理入口，无需嵌入 Python 解释器。

独立原型及对照实验仍保留在 `ASR/`，不进入 `.app`。青简模型只是研究对照，当前应用使用保守的拼音上下文规则，未声称完成青简 Rust 模型的 Swift 移植。

## 实现选择

| 部分 | 实现 |
|---|---|
| 麦克风、文件读取、重采样 | AVAudioEngine / AVAudioFile / AVAudioConverter，转单声道 16 kHz |
| FireRedASR2-AED | MLX Swift 0.31.6，GPU，原有 FP32 safetensors |
| 模型网络 | `mlx-audio-swift` 的 FireRed/Silero 源码子集，固定 revision 并保留 MIT 许可 |
| VAD | Silero v6 MLX，CPU，512 样本一帧；连续 5 帧概率 ≥ 0.5 才识别 |
| 热词 | Swift Aho-Corasick 图及 beam search，热词分数在 top-k 前加入 |
| 英文编码 | Swift SentencePiece BPE，读取原有 `train_bpe1000.model` |
| 拼音纠错 | pypinyin 0.55.0 静态字音与词语数据，Swift 最长词匹配与保守候选选择 |
| 下载 | URLSession 下载到磁盘，固定版本、文件大小和 SHA-256 校验，原子替换 |
| 生命周期 | 后台串行队列拥有 MLX 对象；保留热模型，取消与超时在阶段边界和解码步检查 |

仅通过 `import MLX` 无法直接运行任意 Python 模型。本次有现成 FireRed/Silero Swift 网络实现可复用，仍需适配特征提取、词表、束搜索、模型资源和应用生命周期。只纳入所需源码，使应用依赖保持在 MLX Swift 范围；后续上游修复需要审查并同步到这些文件。

## 固定版本与资源

- MLX Swift：`0.31.6` / `0bb916c67f4b9e5c682cbe02a42c701c93ab5021`，完整依赖图见根目录 `Package.resolved`。
- Swift 模型源码：[`Blaizzy/mlx-audio-swift`](https://github.com/Blaizzy/mlx-audio-swift/tree/3e978558404df4ad1bbb0a5634a03df2b0f9dfa5)，revision `3e978558404df4ad1bbb0a5634a03df2b0f9dfa5`。
- FireRed：[`mlx-community/FireRedASR2-AED-mlx`](https://huggingface.co/mlx-community/FireRedASR2-AED-mlx/tree/f3212eacfa49b851130b97c63653c8e06ee09bdb)，权重 4,565,783,672 字节，继续复用此前下载。
- Silero：[`mlx-community/silero-vad-v6`](https://huggingface.co/mlx-community/silero-vad-v6/tree/2ebf4a5e10726a2e78ddd4d70eedfb6f1c33eb06)，revision `2ebf4a5e10726a2e78ddd4d70eedfb6f1c33eb06`，16 kHz 权重 1,237,860 字节。
- 拼音：41,923 个字音项及 47,111 个词语项，约 2.1 MB JSON；来源与许可随应用打包。可通过 `scripts/export_swift_fixtures.py` 使用原型环境重新导出。

应用模型目录沿用 `~/Library/Application Support/voicer/asr/models/`；新增 `silero-v6/`，原 `firered/` 无需转换。原 Python 环境和 ONNX 文件不自动删除。`native-runtime.json` 记录原生资产版本；个人 `lexicon.json` 始终保留。

## 保持及有意调整的行为

- 同一套 FireRed 权重、beam=3、softmax smoothing=1.25、length penalty=0.6；最多 512 个输出 token，缺少 EOS 时明确报错。
- 特征提取按已测试的 `mlx-audio 0.5.4` Python 配方实现。上游 Swift 的 mel 滤波器、第一采样点预加重和数值下限存在差异，不能直接替换后宣称等价。
- AVFoundation 输出浮点波形始终按 32768 缩放，避免压缩音频略超 ±1 时误判幅值；已验证的 PCM 对照没有此差异。重采样由 AVFoundation 完成，未承诺与 SciPy 逐采样相同。
- VAD 只门控整段，不截取语音端点；状态每段重置，静音不调用 FireRed。MLX 版 Silero 与原 ONNX 来源版本不同，回归覆盖门控行为，未宣称所有概率逐位一致。
- 热词默认关闭、分数 4；拼音纠错默认开启。热词每句只奖励一次，英文需词边界，未完成前缀退分，声学置信度不包含热词奖励。
- 拼音纠错保持同长度、同音、原文上下文锚点和无歧义条件；候选集合超过上限时直接保留原文，避免裁掉平分候选后误判唯一答案。
- `.app` 不再携带 Python 脚本、虚拟环境、ONNX Runtime。Metal 内核放在标准资源 bundle 中并参与应用签名。本机 Release 应用包约 45.94 MiB，模型单独存储。
- MLX 错误转换为 Swift 请求错误并释放无效模型状态。取消为协作式，已提交的 GPU 计算完成后才能返回；不会把迟到结果交给下一次录音。

## 验证

本机 Mac mini M4 / 32 GB，Swift 6.3.3：

- **15 项 XCTest 通过**：录音文件生命周期、48 kHz 双声道转换、特征数值、SentencePiece 中英文编码、拼音多音字/歧义/重叠、热词退款与英文边界、模型配置校验、取消、超时及 MLX 错误恢复。拼音对照涵盖实验输出中的 32 条不同文本。
- 特征对照：冻结 Python 输入与特征，最大绝对误差阈值 `1e-4`；CPU 测试可在没有 GPU 的 CI 中运行，GPU 实际推理由下述文件回归覆盖。
- 原始识别对照：42 条原有音频 × 热词关闭/开启，共 **84/84** 文本一致；详见 [`results/swift-parity.json`](../results/swift-parity.json)。该文件同时记录完整流水线的耗时和最终源码/二进制哈希。模型热加载后，关闭热词 P50/P95 为 0.747/1.192 秒，开启热词为 0.792/1.209 秒（包括文件读取、VAD 与识别，排除首条冷加载和静音；不能与历史仅 ASR 的耗时直接比较）。
- 打包验证：将应用复制到仓库外，`PATH=/usr/bin:/bin`，7 条真实模型文件用例通过，包括中文人名、英文热词、公开中文录音、静音与 48 kHz 双声道 CAF；详见 [`results/voicer-swift-integration.json`](../results/voicer-swift-integration.json)。
- 安装验证：复用已有 FireRed、从零下载 Silero、校验所有资产、再次准备不重下、个人词库字节保持不变；详见 [`results/swift-setup.json`](../results/swift-setup.json)。

复现：

```bash
make test
make build

# 以下 Python 只用于开发对照，不属于应用运行依赖。
python3 ASR/scripts/check_swift_parity.py --output /tmp/swift-parity-new.json
python3 ASR/scripts/check_native_setup.py --output /tmp/swift-setup-new.json
# 此脚本需原型环境中的 numpy/soundfile/scipy，以生成 CAF 测试输入。
"$HOME/Library/Application Support/voicer/asr/.venv/bin/python" \
  ASR/scripts/check_batecho.py --output /tmp/swift-package-new.json
```

这些输入主要是 TTS 合成语音，加一条公开中文录音和静音；结果证明迁移一致性，不代表真实用户口述准确率。语种混排能力沿用 FireRed，无需先按语种切段。英文仍为小写，标点与口语整理需要后续处理。

**尚未验收：真实 Fn 麦克风录音，以及向前台应用注入文字。** 前轮桌面自动化遇到 Orca 辅助功能读取阻塞，文件入口验证不等同于桌面端到端验收。PR 保持草稿，未合并。

## 产品上的收益与限制

主要收益是安装、分发和生命周期管理：用户只下载模型，没有解释器与依赖环境，取消无需重启 Python 子进程。Swift 与 Python 使用同一 MLX 核心，因此语言迁移不等于模型加速，FP32 权重仍约 4.6 GB。后续若需要明显降低内存或延迟，应独立评估量化和解码优化，并重复中英混排及热词准确性回归。

可选 LLM Refinement 仍通过 Swift 调用用户配置的 API；开启后文本会发送至该服务。本次没有新增本地语言模型，也没有改变 Fn 的整句识别交互。

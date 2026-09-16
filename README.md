# BatEcho

<img src="Resources/BatEcho.png" alt="BatEcho — a smiling bat on an orange background" width="160">

macOS 语音输入工具：按住 **Fn** 说话，松开后将文字输入当前应用。

默认使用本地 **Qwen3-ASR-0.6B（8-bit）**，支持中文和中英混排，并通过模型原生的上下文提示接入个人热词。应用的录音、ASR、VAD、分词、拼音纠错和模型下载均由 **Swift** 实现，推理通过 **MLX Swift / Metal** 运行。无需安装 Python、uv 或 ONNX Runtime。菜单中也可切换 Apple Speech Recognition。

## 准备与运行

运行需要 Apple Silicon 和 macOS 14 或更新版本。首次准备下载约 **1 GB** Qwen 模型与分词文件，以及约 1.2 MB 的 Silero MLX 权重。升级自 FireRed 的用户需要重新点一次 **Prepare Local Model…**；个人词库保留，Silero 权重复用。

从源码构建需要完整 Xcode，Swift 6.3 工具链和 Metal Toolchain。锁定的 MLX Swift 为 `0.31.6`。首次安装编译工具后运行：

```bash
# 仅开发机需要，若 Xcode 尚未安装 Metal 编译工具
xcodebuild -downloadComponent MetalToolchain

make setup-asr
make run
```

也可 `make build` 后打开 `build/BatEcho.app`，在 **Speech Settings… → Prepare Local Model…** 下载模型。模型下载使用 URLSession，固定 revision 和 SHA-256 校验；下载失败可重试，完整文件会复用。首次使用需允许麦克风和辅助功能权限。

```bash
make install
open build/BatEcho.app --args --speech-settings
```

模型和词库保存在 `~/Library/Application Support/voicer/asr/`。BatEcho 沿用原来的 Bundle ID `com.kilerd.voicer` 和数据目录；原本选择本地识别的设置自动使用 Qwen，选择 Apple 的设置保持不变。重新构建或移动 `.app` 会复用已完整下载的 Qwen 文件，也不会覆盖用户词库。开发时可用 `BATECHO_ASR_RUNTIME` 指定另一目录，旧的 `VOICER_ASR_RUNTIME` 仍然兼容，新变量优先。原来的 FireRed 权重、Python 环境和 ONNX 文件不会自动删除，应用不再使用它们。

## 签名与发布

`make build` 生成开发应用；`make release` 使用 Developer ID 签名、公证并验证 ZIP 安装包。GitHub Actions 的 **macOS Release** 支持手动构建和版本 tag 发布，PR 流水线提供开发构建下载。配置说明见 [macOS 打包与签名](docs/macos-release.md)。

图标原图保存在 `Resources/BatEcho.png`，`make icon` 用 macOS 系统工具重新生成各尺寸的 `.icns`。

## 词库、热词和拼音纠错

**Speech Settings…** 提供：

- **Use vocabulary as recognition hints**：通过 Qwen 的原生 context 提供热词，默认开启，可随时关闭。旧版 FireRed 的强度分数不再适用。
- **Correct Chinese homophones**：根据拼音和上下文修正中文词，默认开启。
- **Edit Vocabulary…**：编辑个人词库，保存后下一句生效。

词库文件 `~/Library/Application Support/voicer/asr/lexicon.json` 示例：

```json
[
  {"text": "璟珩", "pinyin": ["jing", "heng"], "contexts": ["同事", "负责"]},
  {"text": "Kubernetes", "pinyin": []}
]
```

热词每次最多 64 个，完整提示合计最多 512 个 Qwen token，每个词最多 128 个字符。词表去重后通过 Qwen2 byte-level BPE 编码，放入系统上下文；关闭开关时不传入词表。使用相关的人名、产品名和专业术语，过多无关词可能引起误识别。超限会提示缩减词表，不会悄悄截断。`pinyin: []` 可以作为热词，但不参与后置拼音替换。

拼音纠错使用随应用打包的固定字音与词语数据，在 Swift 中做最长词匹配，保留多音字读音。只有同长度、拼音一致、有原文上下文支持且没有歧义的候选可以替换；候选过多时保留原文。它是文字识别后的纠错，并不提供声学拼音概率。

## 识别流程

```text
按住 Fn → AVAudioEngine 连续录音与波形
        → 按停顿/时长分段 → 单声道 16 kHz → Silero VAD
        → Qwen3-ASR + 可选热词 context → 逐段预览与重叠拼接
松开 Fn → 完成最后一段 → 拼音与词库纠错 → 可选 LLM 纠错 → 当前应用
```

模型在后台串行队列中预加载并复用。录音支持超过 30 秒，内部按停顿或最多 25 秒切段；没有停顿时保留一秒重叠，用于边界拼接。录音期间可以预览已完成分段，松开后完成剩余识别并一次性输入。预览为逐段识别，不是逐字流式解码。

取消和超时在推理阶段之间及每个解码步检查，已提交的 GPU 计算完成后退出；取消的结果不会上屏。临时 CAF 在完成、失败或取消后删除，不保存录音历史。

ASR、VAD 和拼音纠错均在本机运行。**开启 LLM Refinement 后，识别文本会发送至该设置中的 API 服务。** Qwen 输出的英文大小写和标点会保留。

## 验证与开发

```bash
# 原生音频、词库、热词、特征数值、取消和模型复用测试
make test

# 同一条原生识别链路，无需麦克风或辅助功能权限
build/BatEcho.app/Contents/MacOS/BatEcho \
  --transcribe-file /path/to/audio.wav --hotwords

# 原始识别结果，关闭热词和后置纠错
build/BatEcho.app/Contents/MacOS/BatEcho \
  --transcribe-file /path/to/audio.wav --no-hotwords --no-correction
```

重复传入 `--transcribe-file` 可识别多条文件并复用模型；JSON 的 `engine: "swift-mlx"` 和 `model_load_count` 用于验证。文件读取及重采样通过 AVFoundation，支持 WAV、CAF 等系统支持的音频格式。SwiftPM 命令行不能完整编译 Metal 内核，因此 `make build` / `make test` 使用 Xcode 构建。

早期 FireRed 原生迁移的历史结果见 [Swift 迁移验证](ASR/docs/swift-migration.md)。当前 Qwen 的特征、分词和上下文模板对照包含在原生测试中。

| 目录 | 用途 |
|---|---|
| `Sources/BatEcho/` | Swift 应用、录音、设置、模型下载、上屏 |
| `Sources/BatEcho/NativeASR/` | Swift Qwen、Silero、BPE 分词、热词和纠错；旧模型回归代码 |
| `Sources/BatEcho/ASRResources/` | 静态拼音数据、默认词库、第三方许可 |
| `Tests/BatEchoTests/` | 原生测试和冻结 Python 对照数值 |
| `ASR/` | 原型、模型对比和历史实验，开发用，不打包到应用 |

Qwen 的编码器/解码器、Silero 及旧模型回归代码取自 `mlx-audio-swift` 的所需源码子集，固定上游 revision。修改说明及许可见 [第三方说明](Sources/BatEcho/ASRResources/ThirdPartyNotices.txt)。青简重排仍是 `ASR/experiments/qingjian-scorer/` 中的独立实验，未接入应用默认流程；其许可见对应 README。

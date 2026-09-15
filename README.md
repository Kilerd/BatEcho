# BatEcho

<img src="Resources/BatEcho.png" alt="BatEcho — a smiling bat on an orange background" width="160">

macOS 语音输入工具：按住 **Fn** 说话，松开后将文字输入当前应用。

默认使用本地 **FireRedASR2-AED**，支持中文和中英混排。应用的录音、ASR、VAD、热词解码、拼音纠错和模型下载均由 **Swift** 实现，推理通过 **MLX Swift / Metal** 运行。无需安装 Python、uv 或 ONNX Runtime。菜单中也可切换 Apple Speech Recognition。

## 准备与运行

运行需要 Apple Silicon 和 macOS 14 或更新版本。首次准备下载约 4.6 GB 模型；已有 Python 原型的 FireRed 权重可以直接复用，补充约 1.2 MB 的 Silero MLX 权重即可。

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

模型和词库保存在 `~/Library/Application Support/voicer/asr/`。BatEcho 沿用原来的 Bundle ID `com.kilerd.voicer` 和数据目录，已有设置、模型和个人词库继续使用。重新构建或移动 `.app` 不会重新下载模型，也不会覆盖用户词库。开发时可用 `BATECHO_ASR_RUNTIME` 指定另一目录，旧的 `VOICER_ASR_RUNTIME` 仍然兼容，新变量优先。原型留下的 `.venv`、ONNX 文件可以自行清理，应用已不使用它们。

## 签名与发布

`make build` 生成本地开发应用；`make release` 使用 Developer ID 签名、公证并验证 ZIP 安装包。GitHub Actions 的 **macOS Release** 支持手动演练和版本 tag 发布，PR 流水线提供开发构建下载。证书、Keychain profile、runner 配置及完整步骤见 [macOS 打包与签名](docs/macos-release.md)。

图标原图保存在 `Resources/BatEcho.png`，`make icon` 用 macOS 系统工具重新生成各尺寸的 `.icns`。

## 词库、热词和拼音纠错

**Speech Settings…** 提供：

- **Use vocabulary during recognition**：启用解码阶段热词，默认关闭；从 Normal / 4 分开始。
- **Correct Chinese homophones**：根据拼音和上下文修正中文词，默认开启。
- **Edit Vocabulary…**：编辑个人词库，保存后下一句生效。

词库文件 `~/Library/Application Support/voicer/asr/lexicon.json` 示例：

```json
[
  {"text": "璟珩", "pinyin": ["jing", "heng"], "contexts": ["同事", "负责"]},
  {"text": "Kubernetes", "pinyin": []}
]
```

热词每次最多 64 个、合计 512 个模型 token，每个词最多 128 个字符。英文用模型自己的 SentencePiece BPE 编码，每个词一句内最多加分一次，未完成前缀退回加分，英文需要完整词边界。`pinyin: []` 不参与后置拼音替换。

拼音纠错使用随应用打包的固定字音与词语数据，在 Swift 中做最长词匹配，保留多音字读音。只有同长度、拼音一致、有原文上下文支持且没有歧义的候选可以替换；候选过多时保留原文。它是文字识别后的纠错，并不提供声学拼音概率。

## 识别流程

```text
按住 Fn → AVAudioEngine 录音与波形
松开 Fn → 单声道 16 kHz → Silero VAD → FireRed + 可选热词
        → 拼音与词库纠错 → 可选 LLM 纠错 → 当前应用
```

模型在后台串行队列中预加载并复用；录音期间显示波形，松开后显示 Transcribing。每次最多录音 30 秒，超过录音或解码上限会报错。FireRed 识别整句，当前没有实时部分识别结果。

取消和超时在推理阶段之间及每个解码步检查，已提交的 GPU 计算完成后退出；取消的结果不会上屏。临时 CAF 在完成、失败或取消后删除，不保存录音历史。

ASR、VAD 和拼音纠错均在本机运行。**开启 LLM Refinement 后，识别文本会发送至该设置中的 API 服务。** FireRed 当前英文输出小写，标点补全尚未接入。

## 验证与开发

```bash
# 原生音频、词库、热词、特征数值、取消和模型复用测试
make test

# 同一条原生识别链路，无需麦克风或辅助功能权限
build/BatEcho.app/Contents/MacOS/BatEcho \
  --transcribe-file /path/to/audio.wav --hotwords

# 原始识别结果，关闭后置纠错
build/BatEcho.app/Contents/MacOS/BatEcho \
  --transcribe-file /path/to/audio.wav --hotwords --no-correction
```

重复传入 `--transcribe-file` 可识别多条文件并复用模型；JSON 的 `engine: "swift-mlx"` 和 `model_load_count` 用于验证。文件读取及重采样通过 AVFoundation，支持 WAV、CAF 等系统支持的音频格式。SwiftPM 命令行不能完整编译 Metal 内核，因此 `make build` / `make test` 使用 Xcode 构建。

迁移结果和限制见 [Swift 迁移验证](ASR/docs/swift-migration.md)。

| 目录 | 用途 |
|---|---|
| `Sources/BatEcho/` | Swift 应用、录音、设置、模型下载、上屏 |
| `Sources/BatEcho/NativeASR/` | Swift FireRed、Silero、SentencePiece、热词和纠错 |
| `Sources/BatEcho/ASRResources/` | 静态拼音数据、默认词库、第三方许可 |
| `Tests/BatEchoTests/` | 原生测试和冻结 Python 对照数值 |
| `ASR/` | 原型、模型对比和历史实验，开发用，不打包到应用 |

FireRed、Silero 和 SentencePiece 取自 `mlx-audio-swift` 的所需源码子集，固定上游 revision，避免引入整套无关的音频和语言模型。修改说明及许可见 [第三方说明](Sources/BatEcho/ASRResources/ThirdPartyNotices.txt)。青简重排仍是 `ASR/experiments/qingjian-scorer/` 中的独立实验，未接入应用默认流程；其许可见对应 README。

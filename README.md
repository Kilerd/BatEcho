# voicer

macOS 语音输入工具：按住 **Fn** 说话，松开后将文字输入当前应用。

默认使用本地 **FireRedASR2-AED**，支持中文和中英混排。菜单中可切换回 Apple Speech Recognition。原有悬浮波形、剪贴板恢复、输入法切换及可选 LLM 纠错保留。

## 准备与运行

本地 FireRed 需要 Apple Silicon、macOS 14 或更新版本、Xcode Command Line Tools 和 [uv](https://github.com/astral-sh/uv)。首次准备会下载 Python 3.12、依赖和约 4.6 GB 的模型权重。

```bash
make setup-asr
make run
```

也可先 `make build`，打开 `build/voicer.app`，在 **Speech Settings… → Prepare Local Model…** 准备模型。首次使用需按 macOS 提示允许麦克风和辅助功能权限；本地 FireRed 不需要 Apple 的语音识别权限。

```bash
# 安装应用
make install

# 直接打开语音设置
open build/voicer.app --args --speech-settings
```

模型与 Python 环境保存在 `~/Library/Application Support/voicer/asr/`；应用内只打包 Python 源码、配置和下载脚本。重新构建或移动 `.app` 不会重新下载模型，也不会覆盖用户词库。开发时可用 `VOICER_ASR_RUNTIME` 指定另一份运行时。

## 词库、热词和拼音纠错

**Speech Settings…** 提供：

- **Use vocabulary during recognition**：启用解码阶段热词，默认关闭；推荐从 Normal / 4 分开始。
- **Correct Chinese homophones**：根据拼音和上下文修正中文词，默认开启。
- **Edit Vocabulary…**：编辑个人词库。保存后下一句生效，无需重启模型。

词库位于 `~/Library/Application Support/voicer/asr/lexicon.json`，例如：

```json
[
  {"text": "璟珩", "pinyin": ["jing", "heng"], "contexts": ["同事", "负责"]},
  {"text": "Kubernetes", "pinyin": []}
]
```

热词每次最多 64 个、合计 512 个模型 token。英文使用模型自己的 SentencePiece 编码；`pinyin: []` 的词不参与后置拼音替换。中文后置纠错只接受同长度、拼音一致、有上下文支持且没有歧义的候选。每个热词在一句里最多获得一次解码奖励，未完成的前缀会退回加分。

## 识别流程

```text
按住 Fn → 麦克风录音与波形
松开 Fn → 本地常驻进程 → Silero VAD → FireRed（可加热词）
        → 拼音与词库纠错 → 可选 LLM 纠错 → 当前应用
```

FireRed 在松开 Fn 后识别整句，录音期间显示波形，等待时显示 Transcribing。它不是实时流式识别。每次最多录音 30 秒；超过录音或解码输出上限会明确报错，不会将截断文本上屏。

Python 通过应用私有的 stdin/stdout 管道通信，不开放 HTTP 端口。模型在应用启动后预加载，连续识别复用同一进程。崩溃、超时和取消均会释放当前请求，下一次可重新启动。临时 CAF 录音在完成、失败或取消后删除；不保存录音历史。

ASR、VAD 和拼音纠错在本机运行。**如果开启原有 LLM Refinement，识别文本会发送至该设置中的 API 服务。** FireRed 当前输出英文小写，标点补全尚未接入；现有 LLM 纠错也不保证补全标点。

## 验证与开发

```bash
# Swift 录音文件与进程通信测试，以及完整 Python 测试
make test

# 用打包应用走同一条 Swift → Python → FireRed 链路
build/voicer.app/Contents/MacOS/voicer \
  --transcribe-file /path/to/audio.wav --hotwords

# 单独看原始热词解码效果
build/voicer.app/Contents/MacOS/voicer \
  --transcribe-file /path/to/audio.wav --hotwords --no-correction
```

重复传入 `--transcribe-file` 可在同一进程识别多条文件；输出 JSON 中 `model_load_count` 可检查模型复用。文件入口支持 CAF/WAV 等 libsndfile 格式，转换为单声道 16 kHz 后识别。

CI 检查 Swift 构建、录音文件处理、进程协议及 CPU 可运行的 Python 逻辑；真实 MLX 推理和模型解码测试需在 Apple Silicon 本机运行。

本轮实际结果与验收边界见 [voicer 集成验证](ASR/docs/voicer-integration.md)。

| 目录 | 用途 |
|---|---|
| `Sources/voicer/` | 原生菜单栏应用、录音、常驻进程连接、设置和上屏 |
| `ASR/asr_lab/` | FireRed、热词解码、VAD、拼音纠错与 JSON-lines worker |
| `ASR/scripts/prepare_runtime.py` | 独立环境与固定 revision 模型准备 |
| `Tests/voicerTests/`、`ASR/tests/` | 应用边界及识别逻辑测试 |
| `ASR/docs/`、`ASR/results/` | 从 my-asr 迁入的研究记录和冻结实验输出 |
| `ASR/experiments/qingjian-scorer/` | 独立青简重排实验，未接入应用默认流程 |

原型选型与小样本结果见 [FireRed 热词实验](ASR/docs/firered-integration.md)。ASR 目录保留 Qwen/Fun 和青简的独立对照工具；应用中的本地引擎使用 FireRed 与保守拼音规则。麦克风录音和模型权重不进入 Git，也不进入应用包。

FireRed 束搜索适配保留 [MLX Audio MIT 许可](ASR/third_party/mlx-audio-LICENSE)；青简实验的许可和使用范围见其 [README](ASR/experiments/qingjian-scorer/README.md)。

> 此目录保留 Python 原型和历史选型实验。BatEcho 应用已迁到原生 Swift / MLX，运行不依赖此目录；当前用法见仓库根 README 和 docs/swift-migration.md。

# 中文语音输入本地实验

此目录从 my-asr 迁入 voicer，保存识别引擎、独立实验工具和迁入前的研究证据。输入法的安装、设置与使用见 [BatEcho README](../README.md)。`results/` 中旧实验的代码哈希对应迁入前版本，不代表后续集成代码的校验结果。

默认使用 **FireRedASR2-AED**，保留 Qwen3-ASR 和 Fun-ASR-Nano 对照。已在 M4 / 32 GB / macOS 26.3 实测，支持后置拼音词库纠错和实验性的 FireRed 热词解码。

- [FireRed 切换与热词实验](docs/firered-integration.md)
- [本地实验结果与选型结论](docs/local-pilot-results.md)
- [中英文混排方案与语言参数对照](docs/mixed-language-design.md)
- [前期可行性调研](docs/pinyin-stt-feasibility.md)
- [逐条输出、指标和候选审计](results/evaluation.json)

当前流程：音频文件 → Silero 语音检测 → ASR → 拼音与个人词库候选 → 上下文选择或青简重排 → JSON。推理在本机完成。

## 直接试用

完成下方独立实验环境准备后，在本 `ASR/` 目录执行：

```bash
.venv/bin/python -m asr_lab.transcribe data/audio/tingting-term03.wav
```

已验证输出：

```json
{
  "model": "firered",
  "raw_text": "这个项目由同事景恒负责",
  "text": "这个项目由同事璟珩负责"
}
```

默认使用 FireRed、Silero 语音门控和保守的拼音上下文纠错。替换音频路径即可试自己的短句；文件由 libsndfile 读取，支持 WAV 等格式，会转为单声道 16 kHz。

FireRed 默认关闭实验性的热词解码，需要时显式开启：

```bash
.venv/bin/python -m asr_lab.transcribe data/audio/tingting-term01.wav --hotwords --hotword-score 4
```

这会将词库按模型的中文字符 / 英文 SentencePiece 编码，直接参与束搜索加权；每个完整词在一句里最多奖励一次、奖励 4 分，未完成前缀会退回加分，已命中的词也不再获得前缀奖励。它不是给 AED 模型发送自然语言提示。权重尚未用独立真人数据校准。

```bash
# 对照：Qwen 仍默认启用提示式热词
.venv/bin/python -m asr_lab.transcribe data/audio/tingting-term03.wav --model qwen

# 对照：Fun 不加原生热词
.venv/bin/python -m asr_lab.transcribe data/audio/tingting-term03.wav --model fun --no-hotwords

# 实际使用青简的神经模型，作为实验对照
.venv/bin/python -m asr_lab.transcribe data/audio/tingting-term01.wav --model fun --no-hotwords --correction qingjian

# 查看 ASR 原文，关闭后置纠错
.venv/bin/python -m asr_lab.transcribe data/audio/tingting-term03.wav --correction none

# 静音应返回空文本，不加载 ASR 模型
.venv/bin/python -m asr_lab.transcribe data/audio/silence.wav
```

参数：`--lexicon path.json` 自定义词库；`--hotwords` / `--no-hotwords` 控制 ASR 热词；`--hotword-score N` 设置 FireRed 完整词奖励；`--correction none|context|qingjian` 选择后处理；`--output path.json` 保存到新文件。

编辑 [data/lexicon.json](data/lexicon.json)，或建立单独的词库：

```json
[
  {
    "text": "祁砚",
    "pinyin": ["qi", "yan"],
    "contexts": ["同事", "联系", "发给"]
  }
]
```

`context` 策略只接受：与候选同长度、无声调拼音完全一致、原始识别文本出现任一上下文词，且最佳替换没有歧义。英文词的 `pinyin` 设为 `[]`，用于启用后的 ASR 热词，不参与后置拼音替换。近音候选只在实验重排中参与选择。

FireRed 每次最多接受 64 个热词、合计 512 个模型 token；应先筛选与当前输入相关的词。无法在当前模型字表中编码的热词会明确报错。它输出的英文为小写，标点、英文标准大小写和口语整理仍需后续格式化；JSON 中 `asr_confidence` 是未经校准的整句平均 token 分数，不是词级时间戳或整句正确率。

这是短句实验入口：测试音频约 2–5 秒，每次解码上限 128 token；长录音尚未验证，可能截断。麦克风录制、常驻服务、实时端点判断、上屏、口语整理尚未实现。CLI 每次都会加载模型，不能用整条命令耗时代替报告中的热启动推理耗时。

## 从头准备环境

需要 Apple Silicon、Python 3.12、uv；生成测试音频还需 macOS `say` 的 Tingting / Eddy 中文音色与 ffmpeg。青简实验需 Rust 工具链及 Xcode Command Line Tools。

```bash
uv sync --locked --python 3.12
.venv/bin/python scripts/download_models.py --model firered
.venv/bin/python scripts/download_aux.py
cargo build --release --locked --manifest-path experiments/qingjian-scorer/Cargo.toml
.venv/bin/python scripts/prepare_audio.py
```

模型和音频保存在忽略的 `.cache/`、`data/audio/`，不上传录音。首次准备会访问 Hugging Face、GitHub 和 Qwen 的公开音频地址。FireRed 的当前 float32 权重约 4.57 GB，另有约 56 MB 青简模型及 VAD。Qwen/Fun 可用 `scripts/download_models.py --model all` 一并下载，两者另占约 3.25 GB。`--extra fun` 仍兼容，但 MLX Audio 现在已是默认依赖。

模型 revision / SHA-256 位于 `data/*model*.json`。青简的 `data` release 可被上游更新；下载器校验本次锁定的 SHA-256，内容改变时会报错，需要保留原模型才能精确复现。macOS 音色版本变化也可能改变合成音频；本轮 WAV 的哈希在 `data/audio-manifest.json`。

## 复现实验

下列命令使用新输出名，保留已有的实测证据。各模型顺序运行，避免互相争用计算资源。

```bash
.venv/bin/python -m asr_lab.benchmark --model firered --hotword-score 4 --output results/firered-rerun.jsonl
.venv/bin/python -m asr_lab.benchmark --model qwen --output results/qwen-rerun.jsonl
.venv/bin/python -m asr_lab.benchmark --model fun --output results/fun-rerun.jsonl
.venv/bin/python -m asr_lab.evaluate results/firered-rerun.jsonl results/qwen-rerun.jsonl results/fun-rerun.jsonl --with-qingjian --output results/evaluation-rerun.json
.venv/bin/python -m unittest discover -s tests -v
.venv/bin/python scripts/check_vad.py --output results/vad-rerun.json
```

`benchmark` 故意绕过 VAD，用于暴露静音幻觉；实际 `transcribe` 入口始终先运行 VAD。`evaluate` 只读 ASR 输出，复用同一候选集比较策略，不重新识别，也不会把参考答案传给纠错器。

## 代码位置与复用边界

| 位置 | 用途 |
|---|---|
| `asr_lab/backends.py` | 三套 MLX 模型适配及 FireRed 默认配置 |
| `asr_lab/firered.py` | FireRed 固定位置编码兼容处理，严格校验学习权重 |
| `asr_lab/hotwords.py`、`firered_bias.py` | 中英热词编码、上下文自动机和解码加权 |
| `asr_lab/correction.py` | 拼音候选、词库、上下文规则、青简调用 |
| `asr_lab/vad.py` | Silero 整段语音检测 |
| `asr_lab/transcribe.py` | 本地文件入口 |
| `asr_lab/benchmark.py`、`evaluate.py` | 识别实验和五种后处理对照 |
| `experiments/qingjian-scorer/` | 链接真实 qingjian-neural 的 Rust 适配器 |

本次接入的是青简的 **CharScorer 与公开权重**，候选由本项目的词库匹配器生成。青简完整的拼音词图、Viterbi 搜索和用户统计没有接入。其代码和权重标注 GPL-3.0-or-later，适配器同样标注此许可；这是可评估的本地研究依赖。

FireRed 束搜索适配保留 MLX Audio 的 MIT 许可，见 [third_party/mlx-audio-LICENSE](third_party/mlx-audio-LICENSE)。

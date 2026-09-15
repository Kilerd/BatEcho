# FireRedASR2-AED 切换与热词解码

日期：2026-09-15。用户选定 FireRedASR2-AED 后，已将其设为本地默认 ASR，并为其增加实验性的中英热词解码。

## 使用

```bash
# 默认 FireRed + VAD + 后置拼音上下文纠错
.venv/bin/python -m asr_lab.transcribe data/audio/tingting-term03.wav

# 开启热词，词表来自 data/lexicon.json
.venv/bin/python -m asr_lab.transcribe data/audio/tingting-term01.wav --hotwords --hotword-score 4

# 关闭后置纠错，单独观察热词解码效果
.venv/bin/python -m asr_lab.transcribe data/audio/tingting-mixed02.wav --hotwords --correction none
```

热词解码默认关闭；`--hotwords` 显式开启，`--hotword-score` 为完整词的奖励分，默认 4。用户词库通过 `--lexicon path.json` 更换。Qwen / Fun 仍可用 `--model qwen|fun` 运行，并保留原提示式热词行为。

## 为什么需要改解码器

[上游 FireRedASR2-AED](https://github.com/FireRedTeam/FireRedASR2S) 是 Conformer 编码器与 Transformer 解码器组成的 AED 模型。所用 [MLX Audio 实现](https://github.com/Blaizzy/mlx-audio/tree/main/mlx_audio/stt/models/fireredasr2) 的 `generate` 提供束搜索参数，未实现 Qwen / Fun 式自然语言热词提示。直接传入 `hotwords=` 会落入 `**kwargs`，不能据此认为热词生效。

本项目在模型预测下一 token 时加入上下文词的分数，使正确词有机会在候选剪枝前进入搜索。它发生在音频解码中；后置拼音替换是另一层，仍保留。

本地热词实现不修改声学模型权重，不需要重新训练。已有的 Aho-Corasick 上下文加权思路可参考 [sherpa 的算法说明](https://k2-fsa.github.io/sherpa/onnx/hotwords/index.html)。该文档现成接口只支持其 transducer 模型；这里自行适配 FireRed 的 AED 束搜索，没有声称 sherpa 原生支持本模型的热词。

## 实现细节

1. **使用模型自己的 token。** 按 [FireRed 官方 tokenizer](https://github.com/FireRedTeam/FireRedASR2S/blob/4e7d9aaf4482a47cec1724807026b9b151926eb5/fireredasr2s/fireredasr2/tokenizer/aed_tokenizer.py) 的规则，中文逐字，英文先转大写再做 SentencePiece；最终显示仍由原解码器输出小写。
2. **构建带失败转移的词图。** 共享前缀，允许前一个匹配失败后继续匹配它的有效后缀。
3. **在 top-k 剪枝前加分。** 仅在最终结果上改字，无法找回已被解码器丢弃的路径。
4. **前缀加分可退回。** 一个热词没匹配完整时，临时分数会在失配、句尾或长度上限处退回。完整词的总奖励与中文字符 / 英文 BPE 数量无关。
5. **每个热词每句最多奖励一次。** 各搜索分支分别维护“已奖励词集合”；命中后连前缀奖励也关闭。真实重复仍可由 ASR 自身分数生成，但不能靠反复输出热词累积奖励。
6. **英文等待词边界。** 英文词要等空格、新词、中文或 EOS 等边界确认，不能把 `APIS` 中的 `API` 作为完整命中获奖。
7. **置信分不含热词加分。** 输出的是原模型 token 分数的平均值，未经准确率校准，不能当作整句正确的概率。

可以将最终分数理解为：模型序列分数 + 已完整命中的不同热词奖励，再应用原解码器的长度惩罚。搜索过程额外使用可退回的前缀分数。AED 序列分数已经包含语言先验，不是独立的纯声学概率。

当前词表的实际编码保存在 [firered-hotword-tokenization.json](../results/firered-hotword-tokenization.json)。例如：

```text
青简       → 青 / 简
Kubernetes → ▁K / U / BER / N / ET / ES
```

实现最多接受 64 个词、合计 512 个模型 token；更大的外部词库应先检索当前相关词。不能编码的字会报错，不会悄悄变成 `<unk>`。

## 本地对照结果

同一份 12 词词库、相同解码参数，比较关闭热词与开启 4 分热词。最终版本每组运行 42 条：40 条由 macOS Tingting / Eddy 合成，另有 1 条公开中文录音与 1 条纯静音。中文字符错误率（CER）只统计其中 34 条合成中文句、436 个参考字符，忽略大小写、空白和标点；混排与数字格式单独观察。合成音频的实际读音没有人工逐条核对，这不是独立的真人验收集。

| 方案 | 中文 CER ↓ | 中文术语命中 | 英文术语命中 | 12 条负例错误 |
|---|---:|---:|---:|---:|
| FireRed 原始输出 | 3.90% | 10/18 | 4/6 | 0 |
| FireRed + 热词 4 分 | 2.98% | 13/18 | 5/6 | 0 |
| FireRed + 后置拼音上下文纠错 | 2.06% | 15/18 | 4/6 | 0 |
| FireRed + 热词 + 后置拼音上下文纠错 | 2.06% | 15/18 | 5/6 | 0 |

英文命中按词的完整拼写、忽略大小写统计，共 4 条混排句中的 6 次目标词出现。它不代表英文词错误率或格式化质量。12 条负例包括“婚礼请柬”等不应被词库替换的文本；最终热词版本的输出与无热词版本逐字一致，静音也返回空文本。

直接在 ASR 原文中发生的四处变化：

| 样本 | 无热词 | 热词 4 分 |
|---|---|---|
| Tingting / 青简 | 轻剪 | 青简 |
| Eddy / 青简 | 清简 | 青简 |
| Tingting / 幂等性 | 密等性 | 幂等性 |
| Tingting / Kubernetes | qbonets | kubernetes |

**本轮热词与后置拼音纠错的中文收益有重叠。** 两者合用仍是 15/18，没有超过单独后置纠错；额外收益是模型原始输出更准确，以及找回了一处后置拼音层无法处理的英文词。Eddy 的 Cloudflare 仍被识别成“俄罗斯那边”，另外三处中文人名 / 术语仍未找回，因此不能依靠词表强制保证正确输出。

青简重排也保留了对照：热词后接青简（含词库先验）为 13/18，低于现有保守上下文规则的 15/18。现有数据不支持用青简直接取代默认选择规则，完整结果见 [evaluation-firered-current.json](../results/evaluation-firered-current.json)。

### 速度与内存

本机 M4 / 32 GB，模型加载和预热后，统计 42 次完整短句推理：

| 解码 | P50 | P95 | MLX 分配内存峰值 |
|---|---:|---:|---:|
| 无热词 | 1.051 秒 | 1.687 秒 | 4.613 GiB |
| 热词 4 分 | 1.042 秒 | 1.822 秒 | 4.614 GiB |

两组在不同进程顺序运行，不能把 P50 的微小差异理解为热词加速。时间包含特征提取和解码，不含录音、端点等待、文件读取或首次加载；内存是 MLX 统计，并非进程总内存。相较此前 Qwen / Fun 约 0.3–0.4 秒的短句 P50，当前 F32 FireRed 更慢。Typeless 类产品应常驻模型，并另外测量用户停说到上屏的总延迟。

证据：[无热词逐条输出](../results/firered.jsonl)、[最终热词逐条输出](../results/firered-hotwords-once-4.jsonl)、[运行参数与代码哈希](../results/firered-hotwords-once-4.meta.json)。

## 已发现并修复的重复奖励问题

初版按每次出现发放奖励。设为 8 分时，`tingting-term08` 反复输出“词法分析”，纯静音反复输出“金丝雀”，直到 128 token 上限。原始失败保存在 [firered-hotwords-8.jsonl](../results/firered-hotwords-8.jsonl)。该实现已由每词每句一次的版本替代。

限制完整词奖励的同时，必须关闭已命中词的前缀加分；否则搜索仍可能偏向重复前缀。VAD 保持在正式入口之前，解码约束不能替代非语音过滤。

修复后在真实 FireRed 权重上重跑了两个触发样本：8 分时分别正常输出“编译器首先进行词法分析”和空文本，没有复现循环；另一个人名样本能输出“祁砚”。0 分热词解码在一条混排和一条公开录音上，与原始解码输出一致。这是有针对性的回归，未将 8 分认定为最优配置，见 [回归输出](../results/firered-hotword-regressions.json)。最终 4 分配置已完整重跑全部 42 条。

22 项单元测试通过，覆盖重复奖励、英文词边界、前缀退分、搜索等价性、严格加载与原有纠错逻辑。实际 CLI 也验证了默认人名纠错、关闭后置纠错时热词直接生效，以及开启热词后静音仍先被 VAD 拦截。音频、输出、代码哈希与逐词英文命中审计见 [验证记录](../results/firered-verification.json)。

## 部署与兼容处理

- 模型：`mlx-community/FireRedASR2-AED-mlx`，revision `f3212eacfa49b851130b97c63653c8e06ee09bdb`。
- 运行时：`mlx-audio==0.5.4`、`mlx==0.32.2`；MLX Audio 已加入默认依赖，`uv sync --locked --python 3.12` 即可准备。
- 权重：float32，单文件 4,565,783,672 bytes；本轮没有量化或声称与官方 PyTorch 数值等价。
- 下载：`.venv/bin/python scripts/download_models.py --model firered`；`--model all` 可同时准备旧模型。
- 当前 beam size 为 3，输出上限 128 token，适用于本轮约 2–5 秒短句。

该转换包缺少两张固定正弦位置编码表。`asr_lab/firered.py` 仅使用构造器重新生成这两项，其余学习权重继续 `strict=True` 校验。单元测试确认缺少学习权重或混入未知权重仍会失败；没有修改 `.venv` 中的上游库，也没有跳过权重检查。

上游系统支持词级时间戳，但当前 MLX 适配只返回整句置信分，本项目没有虚构词级结果。英文大小写、标点、口语整理仍需后处理；当前拼音纠错不改英文拼写。

## 复现

```bash
.venv/bin/python -m asr_lab.benchmark --model firered --hotword-score 4 --output results/firered-current-rerun.jsonl
.venv/bin/python -m asr_lab.evaluate results/firered-current-rerun.jsonl --with-qingjian --output results/evaluation-firered-current-rerun.json
.venv/bin/python -m unittest discover -s tests -v
```

默认 benchmark 在同一进程交替比较无热词 / 有热词。用 `--mode baseline` 或 `--mode hotwords` 可只运行一组。正式 CLI 始终先做 VAD；benchmark 为观察静音行为故意绕过 VAD。

代码位于 [hotwords.py](../asr_lab/hotwords.py)、[firered_bias.py](../asr_lab/firered_bias.py)、[backends.py](../asr_lab/backends.py)。束搜索沿用 MLX Audio 的 MIT 许可与必要署名，见 [许可证](../third_party/mlx-audio-LICENSE)。

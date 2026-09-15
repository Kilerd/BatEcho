# qingjian 神经重排适配器

本地实验用 JSON Lines 进程接口，调用真实 `qingjian_neural::CharScorer`。源代码固定在 Cargo.toml 的 git revision，权重 SHA-256 见 `../../data/qingjian-model.json`。

```bash
cargo build --release --locked --manifest-path experiments/qingjian-scorer/Cargo.toml
experiments/qingjian-scorer/target/release/qingjian-scorer-probe .cache/models/qingjian/model.qjm
```

从项目根目录运行，标准输入每行一个请求，例如：

```json
{"context":"","texts":["请把婚礼请柬放在桌子上。","请把婚礼青简放在桌子上。"]}
```

返回 `scores` 和 `elapsed_s`。分数是逐字累加的条件 log 概率，数值越大越优；不是识别置信度。本轮候选均为等长替换，不做长度归一化。评测时 `context` 为空，完整识别句子作为候选，未注入光标前文。

进程常驻加载一次；使用 Candle CPU / Accelerate、默认 f32。没有启用 Metal，也没有运行青简的完整拼音转换引擎。Python 接口会先预热，再记录重排耗时。

适配器使用 GPL-3.0-or-later，与所链接的 [qingjian](https://github.com/qingjian-team/qingjian/tree/30bf66ce49080df571273bf944d75f87a4195271) 代码许可一致。模型发布包也标注 GPL-3.0-or-later；原作者署名保留在上游代码及模型元数据中。

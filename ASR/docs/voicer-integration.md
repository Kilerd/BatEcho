# voicer 集成验证

2026-09-15，在 M4 / 32 GB / macOS 26.3 上完成。目标仓库为 `Kilerd/voicer`，基于 `4eec76546e4a09e42d92800efe7295115496685e`。

## 集成范围

my-asr 的运行代码、独立实验工具、词库和历史研究记录迁入 `ASR/`。`.venv`、模型缓存、合成音频与 Rust 编译产物未进入 Git。

voicer 新增本地 FireRed 引擎与设置入口，默认启用拼音上下文纠错；热词保持显式开启。原有 Fn 录音、悬浮波形、可选 LLM 纠错和上屏流程继续使用。Apple Speech 保留为可选引擎，语言菜单只对 Apple 生效；FireRed 自动处理中文与中英混排。

Swift 将麦克风原始采样率音频写入私有临时 CAF 文件，通过应用拥有的 Python 子进程完成 VAD、重采样、解码与纠错。子进程常驻、词库每次重读；通信使用带请求 ID 的 JSON 行协议。取消和超时终止当前子进程，旧响应不能被新录音接收。最多录音 30 秒，最多生成 512 token；超过上限返回错误，避免将不完整文本上屏。

环境与权重放在 `~/Library/Application Support/voicer/asr/`，源码与准备脚本随 `.app` 打包。首次准备可在语音设置执行，也可运行 `make setup-asr`；重新准备不覆盖已有个人词库。

## 已完成的验证

- **9 项 Swift 测试通过**：48 kHz 双声道 CAF 写入与删除、30 秒限制、UTF-8 分段响应、模型进程复用、请求错误、崩溃恢复、取消、超时和缺少运行时。
- **31 项 Python 测试通过**：包含此前的 22 项解码 / 拼音测试，以及 worker 的参数验证、词库即时更新、VAD、输入 / 输出上限和错误恢复。
- **Release 构建与签名校验通过**：`make build`、`codesign --verify --strict`。
- **打包后的准备脚本可重复执行**：使用已有固定版本模型完成环境检查，用户词库字节保持不变，见 [准备流程验证](../results/voicer-setup-verification.json)。
- **7 条真实模型集成用例通过**：把 `.app` 复制到临时目录，从仓库外启动其可执行文件，调用同一套 Swift 连接和 Python worker。

| 用例 | 实际行为 |
|---|---|
| 默认中文人名 | ASR 输出“景恒”，最终输出“璟珩” |
| 公开中文录音 | 输出“甚至出现交易几乎停滞的情况” |
| 默认配置静音 | 空文本 |
| 热词、关闭后置纠错 | ASR 直接输出“青简” |
| 热词、中英混排 | ASR 直接输出 `kubernetes` 和 `postgresql` |
| 热词配置静音 | 空文本 |
| 48 kHz 双声道 CAF | 转换后正确输出“这个项目由同事璟珩负责” |

同一进程中的连续三条文件均报告 `model_load_count: 1`。逐条输出、音频哈希与本轮源码哈希见 [voicer-integration-final.json](../results/voicer-integration-final.json)。这些用例验证接线和行为，不构成独立真人准确率评测。

## 尚未验收的部分

应用启动后，桌面工具能列出 **Speech Settings** 窗口；进程采样显示主线程在正常 AppKit 事件循环中等待。随后窗口访问持续返回辅助功能权限错误。权限查询显示已授予，但读取仍被拒绝，因此没有通过自动化点击设置控件，也没有完成真实麦克风 Fn 录音与目标应用上屏的人工验收。

FireRed 在松开 Fn 后整句识别，没有录音中的部分文本。英文保持小写，标点补全尚未实现。原有 LLM 功能如被启用，仍会向配置的服务发送识别文本。

## 复现

```bash
make setup-asr
make build
make test

# 固定研究音频可通过 ASR/scripts/prepare_audio.py 准备。
# 使用新的输出路径，保留已有的实测证据。
"$HOME/Library/Application Support/voicer/asr/.venv/bin/python" \
  ASR/scripts/check_voicer.py --output /tmp/voicer-check.json
```

GitHub Actions 验证 Swift 构建 / 测试，以及不依赖 MLX 和模型权重的 worker、拼音与选项测试。真实模型检查在本机执行。

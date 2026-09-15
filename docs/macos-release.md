# BatEcho 的 macOS 签名与发布

## 结论

采用 GhostLens 已使用的 **Developer ID Application → Hardened Runtime → Apple 公证 → staple → ZIP → Gatekeeper 验证** 流程。BatEcho 只有一个原生可执行文件，模型保存在用户数据目录，安装包无需包含约 4.6 GB 的模型权重。首版提供 Apple silicon / macOS 14+ 的 ZIP，解压后将 `BatEcho.app` 放入 Applications。

实现位于 [`scripts/release.sh`](../scripts/release.sh) 和 [`release.yml`](../.github/workflows/release.yml)。脚本只生成和验证安装包；发布由 workflow 的单独步骤负责。

## 与 GhostLens 的关系

参考本机 `/Users/kilerd/Projects/ghostlens` 的 `scripts/bundle-macos.sh`、`scripts/release.sh` 和 `.github/workflows/release.yml`，参考版本为 `0ebcd9f46607856e24374e177ba231b668e5aeab`。旧的 `docs/research-apple-signing.md` 描述的是更早的基线，当前可执行脚本已经接入公证。

2026-09-15 检查结果：

| 项目 | 本机状态 / BatEcho 的处理 |
|---|---|
| 签名身份 | Keychain 有有效的 `Developer ID Application: Chen Xin (V9ZRBTHDGR)`；脚本自动选择，也支持指定证书名称或 SHA-1 |
| 已安装 GhostLens | 带 Hardened Runtime、Developer ID 签名、安全时间戳和已装订公证票据 |
| 公证凭据 | 用户已在本机 `login.keychain-db` 配置 `batecho-notary`；显式指定该 Keychain 的认证检查通过 |
| GitHub runner | GhostLens 有在线的仓库级 `kilerds-Mac-mini`；BatEcho 仓库尚未注册 runner，不能直接使用另一个仓库的 runner |
| 应用更新 | BatEcho 当前没有自动更新功能，因此不生成 GhostLens 专用的 `latest-mac.yml` |
| 应用身份 | 保留 `com.kilerd.voicer`，沿用 UserDefaults 和 `Application Support/voicer/asr`；产品名、可执行文件、Swift 模块和图标改为 BatEcho |

证书名称和 profile 名称不是密码。流水线使用本机 Keychain，不导出私钥，也不在仓库保存 Apple 账号凭据。

## 签名需要什么

| 用途 | 所需配置 |
|---|---|
| 本机开发、PR 构建 | `make build` 使用可用签名身份，未找到证书时使用 ad-hoc；没有公证票据 |
| 官网 / GitHub ZIP 分发 | Developer ID Application、Hardened Runtime、安全时间戳、公证票据 |
| 录音 | `Resources/BatEcho.entitlements` 中的 `com.apple.security.device.audio-input`，以及 Info.plist 中的麦克风用途说明 |
| Fn 监听与上屏 | 用户在系统设置授予辅助功能权限；公证不会代替权限授权 |

Developer ID **Installer** 用于签 `.pkg`，当前 ZIP 方案不需要。当前功能不使用需要 provisioning profile 的受限 entitlement。MLX 的 Metal 内核打包在资源 bundle 中，当前只声明录音权限；不添加 `allow-jit`、`disable-library-validation` 或调试权限。

本机签名测试发现，MLXNN 的 CPU `relu` 会生成临时 `.so`，加载时因签名 Team ID 不一致被 Hardened Runtime 拒绝。Silero 的五处 ReLU 已改为数学上等价的 `MLX.maximum(x, 0)`，保留库签名验证。`verify-bundle.sh` 会执行签名应用的 `--verify-runtime`，用随机参数跑两帧完整 CPU VAD，不下载模型，也不触发麦克风权限；该检查能覆盖这次发现的动态库加载问题。

这些要求依据 Apple 的 [公证准备要求](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)、[Audio Input entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.audio-input)、[分发容器打包](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution) 和 [Provisioning Profiles](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)。

## 本机演练

这台 Mac 已有签名证书和有效的 `batecho-notary` profile。新机器上先在自己的终端运行以下命令，按提示输入 Apple ID 的 **app-specific password**；无需把密码交给脚本或写入命令历史：

```bash
xcrun notarytool store-credentials batecho-notary \
  --apple-id '<你的 Apple ID>' --team-id V9ZRBTHDGR \
  --keychain "$HOME/Library/Keychains/login.keychain-db"
```

随后执行：

```bash
scripts/release.sh --preflight
make test
make release
```

如果有效凭据实际存放在其他 profile，可设置 `BATECHO_NOTARY_PROFILE=<名称>`；其他 Keychain 可通过 `BATECHO_NOTARY_KEYCHAIN=<绝对路径>` 指定。默认显式使用 `$HOME/Library/Keychains/login.keychain-db`，与保存凭据的命令一致。`--preflight` 只检查版本、可用证书和 Apple 凭据认证，不提交应用。`make release` 会向 Apple 提交公证，但不创建 GitHub Release。成功输出：

```text
dist/BatEcho.app
dist/BatEcho-1.0.0-macos-arm64.zip
dist/SHA256SUMS
dist/build-info.txt
dist/notarization.json
```

版本来自 `Resources/Info.plist` 的 `CFBundleShortVersionString`，格式为 `X.Y.Z`；每次正式发布也要递增 `CFBundleVersion`。`build-info.txt` 记录 commit、工作区是否有修改和 Apple submission ID。公证失败时保留响应，能取得日志时写入 `dist/notarization-log.json`。

脚本先验证证书和公证认证，再构建、签名、提交。只有状态为 `Accepted` 才继续；先 staple 到 `.app`，再生成用户下载的 ZIP，并解压检查票据、资源和 Gatekeeper。ZIP 自身不能装订票据。流程依据 [Apple 自定义公证流程](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)。

Apple 超过 30 分钟仍未完成时，脚本停止等待并保留 submission ID。用 `xcrun notarytool info <id> --keychain-profile <profile> --keychain <Keychain绝对路径>` 查询进度，先确认原提交状态，避免连续重复提交。

## GitHub Actions 配置

首选继续使用这台 Mac，复用已有 Keychain。为 **BatEcho 仓库单独注册一个 runner**，使用独立的 runner 安装 / 工作目录；保持 GhostLens 当前注册不变。GitHub 仓库 **Settings → Actions → Runners → New self-hosted runner → macOS / ARM64** 会给出对应注册命令。

该 runner 需要：

1. 完整 Xcode、当前项目使用的 Swift 工具链以及已安装的 Metal Toolchain（`xcodebuild -downloadComponent MetalToolchain`）。
2. 在可访问签名私钥和公证 profile 的登录用户会话中运行。
3. 创建默认的 `batecho-notary` profile；若复用已有的有效 profile，则设置仓库 Actions variable `MACOS_NOTARY_PROFILE=<名称>`。
4. 可选 Actions variable `MACOS_SIGN_IDENTITY`，用于存在多个 Developer ID 时指定名称或 SHA-1。
5. 可选 Actions variable `MACOS_NOTARY_KEYCHAIN`，指定公证凭据所在 Keychain 的绝对路径；默认使用 runner 用户的登录 Keychain。

当前流程不需要把证书或密码放入 GitHub Secrets。若 runner 改成脱离登录会话的服务，需要另外解决 Keychain 解锁与私钥访问授权；脚本不会修改登录 Keychain 的锁定状态或访问控制。

| 触发方式 | 执行内容 |
|---|---|
| PR / main push 的 Tests | GitHub 托管 runner 上构建、测试，上传标为 development 的 ZIP；不使用签名凭据 |
| 推送 `ci/notarization` 分支 | 自托管 Mac 上测试、签名、公证并上传 Actions artifact；发布步骤跳过 |
| 手动 macOS Release，默认 `publish=false` | 自托管 Mac 上测试、正式签名、公证，上传可下载的 Actions artifact |
| 推送 `vX.Y.Z` tag | 校验 tag 与 Info.plist、运行同一打包流程，在当前仓库创建 Release |
| 手动 macOS Release，选择 `publish=true` | 要求 `vX.Y.Z` 已存在且指向所选 commit，通过验证后发布 |

正式发布步骤使用当前仓库的 `GITHUB_TOKEN`，不需要 GhostLens 跨仓库发布所用的 PAT。当前工作不创建版本 tag、不合入 PR。后续由维护者选择发布时点。

### workflow 合入之前的 CI 演练

GitHub 要求 `workflow_dispatch` 的定义先出现在默认分支；仅把 `--ref` 指向 PR 分支仍会返回 404。合入前可以将维护者确认的 commit 推送到专用测试分支：

```bash
git push origin HEAD:refs/heads/ci/notarization
```

这会运行同一个 `package` job；只有版本 tag 或显式选择 `publish=true` 的手动运行才会进入 `publish` job。测试分支不会创建 GitHub Release。触发规则依据 [GitHub 手动运行 workflow 文档](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow)。

仓库尚未配置常驻 runner 时，可注册带 `--ephemeral` 的独立 runner 供这次演练使用。它在一个 job 结束后自动注销；之后的 CI 发布需要重新启动 runner 或配置常驻 runner。

如果希望彻底改为 GitHub 托管 macOS runner，需要另行导出含私钥的 `.p12`，通过 Secrets 提供证书、导出密码和公证凭据，并在临时 Keychain 导入、结束后清理。GitHub 有 [证书导入范例](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications)。当前已有可用 Mac 和 Keychain，先沿用 GhostLens 的路径工作量更小。

## 发布验收

2026-09-15 本机验证：Release 构建与 16 项 Swift 测试通过；Developer ID 签名、安全时间戳、Hardened Runtime 和签名后的 CPU VAD 检查通过。签名应用复制到仓库外，7 条真实模型文件检查全部通过，涵盖中文、英文热词、静音与 48 kHz 双声道 CAF，详见 [`batecho-signing-integration.json`](../ASR/results/batecho-signing-integration.json)。Finder 读取到正确的蝙蝠图标；约 13 MiB 的签名预览 ZIP 解压后，签名、资源与 CPU VAD 再验证通过。

早期签名预览的 Gatekeeper 结果为 `Unnotarized Developer ID`。当前公证凭据认证已通过；实际发行包以 `dist/notarization.json` 中的 `Accepted` 状态、`stapler validate` 和 Gatekeeper 验证为准。自托管发布 job 还需注册 BatEcho runner。

```bash
scripts/verify-bundle.sh dist/BatEcho.app
codesign -dvv --xml --entitlements - dist/BatEcho.app
xcrun stapler validate dist/BatEcho.app
spctl --assess --type execute --verbose=2 dist/BatEcho.app
(cd dist && shasum -a 256 -c SHA256SUMS)
```

Gatekeeper 应返回成功并显示 `source=Notarized Developer ID`。另需验证实际用户下载后解压安装、首次麦克风 / 辅助功能授权、按住 Fn 录音与上屏，以及更新后的权限状态。命令行音频文件验证覆盖模型、MLX 与资源打包，不能代替实体麦克风和前台应用验收。

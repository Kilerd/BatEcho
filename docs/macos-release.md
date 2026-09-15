# macOS 打包与发布

BatEcho 提供 Apple silicon / macOS 14+ 的 ZIP 安装包。解压后将 `BatEcho.app` 移入 Applications；模型在首次设置时下载，不包含在安装包中。

## 构建

从源码构建需要完整 Xcode、项目要求的 Swift 工具链和 Metal Toolchain。

```bash
make build
make test
```

开发应用输出到 `build/BatEcho.app`。正式分发使用 Developer ID Application 签名、Hardened Runtime 和 Apple 公证：

```bash
make release
```

[`scripts/release.sh`](../scripts/release.sh) 检查签名配置，构建应用并提交公证。Apple 接受后，脚本将公证票据装订到应用，生成 ZIP，再解压验证签名、资源、MLX 运行时、票据和 Gatekeeper。只有验证通过的 ZIP 才会输出到 `dist/`。

## 发布配置

签名机器需要配置 Developer ID Application 证书及私钥，并具备可用的公证凭据。配置方法见 Apple 的[公证工作流文档](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)。

| 环境变量 | 用途 |
|---|---|
| `BATECHO_SIGN_IDENTITY` | 选择 Developer ID Application 签名证书 |
| `BATECHO_NOTARY_PROFILE` | 选择已配置的公证凭据 |
| `BATECHO_NOTARY_KEYCHAIN` | 指定保存公证凭据的 Keychain |
| `BATECHO_EXPECTED_VERSION` | 校验构建版本与发布版本一致 |

证书、私钥、账号凭据及机器配置由发布环境管理。仓库只保存可复用的构建配置。

## GitHub Actions

[`macOS Release`](../.github/workflows/release.yml) 在配置好签名环境的 macOS / ARM64 runner 上构建发行包。仓库变量 `MACOS_SIGN_IDENTITY`、`MACOS_NOTARY_PROFILE` 和 `MACOS_NOTARY_KEYCHAIN` 对应上述配置。

| 触发方式 | 结果 |
|---|---|
| PR / main 的 Tests | 构建并测试，上传 development ZIP |
| 手动运行，`publish=false` | 签名、公证并上传 Actions artifact |
| 推送 `vX.Y.Z` tag | 验证版本、签名、公证并创建 GitHub Release |
| 手动运行，`publish=true` | 要求对应版本 tag 指向所选提交，验证后创建 Release |

版本号来自 `Resources/Info.plist` 的 `CFBundleShortVersionString`，格式为 `X.Y.Z`；发布新版本时同步递增 `CFBundleVersion`。

## 发行产物

- `BatEcho-X.Y.Z-macos-arm64.zip`：签名且已公证的应用。
- `SHA256SUMS`：安装包校验和。
- `build-info.txt`：版本、来源提交和公证状态。

Gatekeeper 验证应成功并显示 `source=Notarized Developer ID`。首次使用时仍需授予麦克风和辅助功能权限。公证验证不能替代录音、Fn 按键和前台应用输入的功能验收。

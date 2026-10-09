# Storyhack 社区版 · 世界书

<img src="Assets/logo/v3/B-icon-square.png" width="120" alt="Storyhack 图标">

Apple 设备上的本地小说阅读、世界设定管理与互动叙事工具。你可以导入自己的小说，整理角色与设定，接入自选模型进行互动游玩，保存故事分支，或在 Mac 上处理改编与写作任务。

这是独立维护的开源社区版，当前为 **0.1.0 开发者预览**，采用 MIT 许可。没有内购，也没有世界书数量限制。书籍与模型密钥由使用者自行提供。

## 能做什么

| 功能 | macOS | iOS |
| --- | --- | --- |
| 导入与阅读 TXT、Markdown、EPUB | ✓ | ✓ |
| 新建、编辑、导入与导出世界书 / Lorebook | ✓ | ✓ |
| 管理角色、互动游玩、存档与故事分支 | ✓ | ✓ |
| 用模型分析小说并生成世界书的工坊 | ✓ | ✓，前台运行 |
| 改编、写作工作区及任务命令行 | ✓ | 界面暂未开放 |
| OpenAI-compatible 自选模型配置 | ✓ | ✓ |

阅读与编辑设定不需要模型密钥。互动叙事、工坊分析和 AI 写作会向你配置的模型服务发送相关内容，并可能产生费用。扫描版 EPUB、PDF 和 OCR 暂不支持。远程浏览器访问未包含在社区版中。详见 [当前限制](docs/LIMITATIONS.md) 与 [隐私说明](docs/PRIVACY.md)。

## 在 Mac 上开始

需要 macOS 14 或更新版本，以及包含 Swift 6 的 Xcode。首次构建需要联网下载 ZIPFoundation；本项目没有模型服务的默认账号。

```sh
git clone https://github.com/Doubixilin/storyhack-open-source.git
cd storyhack-open-source
./scripts/build-macos-app.sh debug
open .build/StoryhackCommunity.app
```

1. 在书架导入 [原创演示小说](Examples/雾港来信.md)，验证阅读功能。
2. 在书架的小说操作菜单中导入 [演示世界设定](Examples/雾港来信.lorebook)，或在故事世界页面新建空白世界。
3. 如需互动游玩，在「模型设置」添加服务地址、模型 ID 和自己的 API Key，再选择一个世界开始游玩。内容会发送到该服务，结果需要自行判断。

社区版使用独立的 `StoryhackCommunity` 数据目录、应用标识和 Keychain 服务，不会自动读取原版数据或密钥。迁移设定请使用导出 / 导入；请先备份自己的作品与存档。

## iOS 源码构建

用 Xcode 打开 `Worldbook.xcworkspace`，选择 `WorldbookIOS`。模拟器构建不需要开发者签名；安装到真机时选择自己的开发团队。仓库不包含作者的签名配置。最低 iOS 17，当前主要面向 iPhone。

```sh
xcodebuild -workspace Worldbook.xcworkspace -scheme WorldbookIOS \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/ios CODE_SIGNING_ALLOWED=NO build
```

## 验证与参与

```sh
swift test
python3 scripts/verify_task_cli.py
python3 scripts/public-preflight.py
./scripts/verify-macos-bundle.sh
```

默认测试使用本地夹具与模拟模型。真实模型测试需要显式环境开关与密钥；没有运行真实模型测试时，会显示为跳过。[验证记录](docs/VALIDATION.md) 区分自动测试、构建、资源验证与尚未完成的设备验收。

- [命令行任务说明](docs/CLI任务使用说明.md)
- [结构与维护边界](docs/ARCHITECTURE.md)
- [贡献指南](CONTRIBUTING.md) · [安全问题](SECURITY.md) · [更新记录](CHANGELOG.md)

## 许可与素材

项目代码、项目文档、项目图标及随附的原创 / 合成示例按 [MIT](LICENSE) 提供；依赖保留各自许可，见 [第三方声明](THIRD_PARTY_NOTICES.md)。[素材说明](Materials/README.md) 解释了内置生成素材与测试夹具的用途。用户自行导入的小说、图片与模型输出不因本项目开源而获得再分发许可。

目前提供源码，未发布经过 Developer ID 签名、公证的 Mac 安装包，也未发布 App Store 版本。

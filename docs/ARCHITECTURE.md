# 项目结构与维护边界

项目使用 Swift Package 管理核心模块，SwiftUI 提供 macOS 与 iOS 界面。包名和内部 `Worldbook*` 目标名保留，以减少迁移与格式兼容风险；公开应用名称是 Storyhack 社区版。

| 路径 / 模块 | 责任 |
| --- | --- |
| `NovelDocumentCore`、`LibraryCore` | 文本 / EPUB 解析与本地图书库 |
| `DirectoryJournalCore` | 目录与文件替换记录、恢复 |
| `StoryworldCore` | 世界设定、Lorebook、运行存档、分支与偏好 |
| `StorySessionCore` | 互动回合、上下文与提交边界 |
| `LLMProviderKit` | 模型配置、凭据、流式请求与协议解析 |
| `StoryworldFactory` | 小说分析、决策、候选生成、发布与续跑 |
| `WritingCore`、`WritingAssistantCore` | 原创 / 改编、草稿、版本、人工审阅与发布 |
| `WorldbookTaskCLI`、`Tools` | 任务命令行与迁移工具 |
| `StoryMaterialKit`、`Materials` | 编译素材、运行查找与测试输入 |
| `CharacterLibraryCore`、`MediaCore`、`SpeechProviderKit` | 角色资料、音频计划与系统朗读 |
| `VisualMediaCore` | 实验图片资产管理，生图界面暂未开放 |
| `WorldbookUI`、`Apps` | 共享 UI 与应用入口 |

外部 Swift 依赖只有 ZIPFoundation；准确版本见 `Package.resolved`。社区版不包含 StoreKit、内购策略或远程服务模块。

修改持久化模型时应考虑旧文件兼容和恢复路径；修改回合与草稿提交时应保留版本、分支和预期状态检查。CLI 和 App 可访问同一社区数据根目录，涉及并发写入的变更需要对应回归测试。

社区版为单独 Git 仓库，从经过筛选的源码建立首个提交；没有导入原仓库历史。后续维护以范围明确的 PR 为单位，不自动同步内部研究、用户数据、签名配置或未经确认的资源。

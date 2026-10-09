# CLI 任务使用说明

CLI 面向 Mac 上的工坊、原创与改编任务。先在社区源码目录构建：

```sh
swift build --product WorldbookTaskTool
.build/debug/WorldbookTaskTool --help
```

使用独立数据目录尝试演示文件：

```sh
TASK_ROOT=$(mktemp -d)
.build/debug/WorldbookTaskTool factory create \
  --root "$TASK_ROOT" --source Examples/雾港来信.md
.build/debug/WorldbookTaskTool factory list --root "$TASK_ROOT"
.build/debug/WorldbookTaskTool adaptation template --kind contract
```

默认 `--root` 为社区版数据根目录，可能与正在运行的 App 共用。实验时显式指定临时目录。输出为 JSON，包含任务 ID、阶段、待核对对象或错误；保存后检查实际字段再进行下一步。

需要模型的命令通过环境变量读取 `WORLDBOOK_API_KEY`。服务地址与模型可由 `--base-url` / `--model` 或 `WORLDBOOK_BASE_URL` / `WORLDBOOK_MODEL` 指定。CLI 不接受 `--api-key`，不读取或写入 App 的 Keychain 密钥。即使使用 `--provider` 读取 App 中保存的模型配置，也仍需要 CLI 环境凭据。

工坊一般按 `create → analyze → answer → generate → publish` 推进。`answer` 的文件需要包含返回的原始决策和审阅后的答案；断点续跑用 `resume`，不确定请求是否已发送时须查看 `pending` 并显式确认。不要自动批准所有待核对对象。

原创 / 改编任务的完整命令和参数见 `--help`。生成草稿后仍须审阅装配结果，`export` / `publish` 不自动接受过期审阅。退出码：0 完成，1 失败，2 参数错误，3 部分完成，4 待核对，75 忙碌，130 取消。

`python3 scripts/verify_task_cli.py` 使用本机模拟服务和合成文本，验证真实 CLI 的创建、续跑、取消、重发审阅与凭据处理，不访问付费模型。

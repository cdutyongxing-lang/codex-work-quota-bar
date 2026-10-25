基于 Thinkdiff-lw/codex-quota-bar v1.0.0 的 macOS 适配版本。

v1.0.2 修复：暂停时仍可手动刷新一次，明确显示暂停与旧数据状态；恢复时立即读取，主应用重新打开后重新连接，并忽略旧请求回包。新增回归检查，当前共 40 项检查。更新前请先从菜单退出旧版额度条，再替换应用。

- 菜单栏同时显示 5 小时与每周剩余额度。
- 适配 Bundle ID 为 `com.openai.codex` 的 ChatGPT / Codex 应用及其内置 CLI 路径。
- 默认无需辅助功能权限，可选窗口跟随、手动校准和登录启动。
- 约每 60 秒读取一次额度；工具不创建模型任务。
- 支持暂停后续查询，读取失败时保留旧值并标记待更新。

下载 `CodexWorkQuotaBar-macOS.zip`，解压后将 `.app` 移入“应用程序”并打开。它显示在屏幕顶部菜单栏，没有普通主窗口。

需要 macOS 13+ 和使用 ChatGPT 账户登录的官方 Codex CLI。支持 arm64 / x86_64 通用构建；Intel 运行环境、悬浮定位、多屏和登录启动仍需更多实机验证。

应用使用 ad-hoc 签名，尚无 Apple Developer ID 签名或公证。`.sha256` 用于文件一致性检查，不能代替安全审计。

原项目：https://github.com/Thinkdiff-lw/codex-quota-bar

本项目遵循 MIT 许可证，与 OpenAI 无隶属关系。

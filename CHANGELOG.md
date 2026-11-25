# Changelog

All notable changes to MailPilot are documented in this file.

## [0.4.0] - 2026-11-25

### Added
- **AI 本地附件解读**：新增 `AttachmentTextExtractor`，基于系统原生 `PDFKit`、AppKit 文档解析与离线 `Vision` OCR 支持读取 PDF、CSV/TXT/MD/JSON/HTML、DOCX/RTF 及图片/扫描件；支持右键附件一键解读与 AI 抽屉「含附件解读」开关。
- **全箱跨邮件检索问答 & 摘要持久化**：AI 抽屉支持切换「全箱检索问答」聚合多封本地邮件；单封 AI 摘要自动持久化至磁盘（LRU 300 封）。
- **结构化搜索筛选器与附件名检索**：搜索栏新增「未读 / 有附件 / 时间范围」组合筛选；后台索引写入附件文件名与 `has_attachments` 标记。
- **操作撤销与系统集成**：归档/删除新增 5 秒一键「撤销」Toast；新增原生 AppKit `NSStatusBar` 顶部菜单栏未读图标与基于 `SMAppService` 的登录自启开关。
- **工程化与分发**：新增 GitHub Actions CI (`ci.yml`) 与自动发版 (`release.yml`) 工作流、支持 Developer ID 公证的 `scripts/release_app.sh`，并拆分 `SettingsView` 与 `ContentView` 视图模块。
- **测试覆盖**：核心单元测试扩展至 41 组。

### Fixed
- 修复 SwiftUI `MenuBarExtra(isInserted:)` 在 macOS 27 下触发 `AppGraph` 无限递归导致的闪退与卡死，改用原生 `NSStatusBar` 实现。
- 修复远程图片拦截提示条使用了不存在 SF Symbol 名称的问题。

## [0.3.0] - 2026-11-25

### Added
- 本地联系人自动补全（只读检索 `Envelope Index` `addresses` 表）。
- 全部回复（`⌥⌘R`）、密送（BCC）、转发自动带入原附件、未保存草稿关闭确认条、按邮箱账号配置默认发件签名。
- 阅读区头部新增可折叠的收件人/抄送详情栏。

## [0.2.1] - 2026-11-25

### Added
- 写信附件实时读取进度条、iCloud 云端文件自动下载、拖拽添加附件、窗口内直显成功/失败反馈条与失败重试。
- 搜索范围动态提示、`⌘F` 聚焦与 `Esc` 清空快捷键、列表底部状态栏、AI 流式停止与自动滚动。

### Fixed
- 精简阅读区操作栏为纯原生 SF Symbols，移除 emoji 图标。
- 修复新邮件通知漏触发与程序坞角标不同步/查看后不消失的问题。

## [0.2.0] - 2026-11-24

### Added
- 拆分 `AppViewModel` 为独立协调器（`AIAssistantController`、`BodyIndexCoordinator`、`ComposeCoordinator`）。
- 强化 FTS5 事务写入错误提示与原子回滚、AI 上下文预算裁剪、大附件按需解码与 ROWID 游标分页扫描。
- 构建脚本自动从 Git Tag 推导版本号。

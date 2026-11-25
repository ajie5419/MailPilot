# MailPilot

基于 **SwiftUI + AppKit** 构建的 macOS 原生 AI 邮箱客户端。将收信、多账号推送、休眠唤醒与发信安全交由系统自带 **Mail.app** 处理，通过严格只读访问本地 `Envelope Index` + 实时目录监听 + AppleScript 委托写入，实现轻快、隐私可控的原生阅读、搜索、写信与 AI 助理体验。

---

## 核心特性

### 原生阅读、搜索与效率
- **严格只读索引 (`EnvelopeIndexReader`)**：以 `SQLITE_OPEN_READONLY | SQLITE_OPEN_URI` 访问 `~/Library/Mail/V*/MailData/Envelope Index`，绝不直接写库；支持 Gmail 多标签聚合、收件人/抄送详情折叠展示。
- **低内存大附件解析 (`EmlxParser`)**：基于内存映射与原始字节区间扫描 `.emlx`，支持 `multipart` / `base64` / `quoted-printable` / GB18030 / 内嵌 `cid:` 图片与中英文验证码自动提取；大附件仅在点击打开、保存或 AI 解读时按需解码。
- **全文检索与结构化筛选 (`BodySearchIndex`)**：本地独立 SQLite FTS5 (`trigram`) 全文索引，支持按正文与**附件文件名**检索；搜索栏内置 **未读 / 有附件 / 近 7 天·30 天·90 天** 组合筛选。
- **实时同步、桌面通知与角标 (`MailDirectoryWatcher` + `NotificationManager`)**：结合 `kqueue` vnode、`FSEvents` 与 8 秒轻量 `stat()` 兜底检测；同时同步程序坞红点与顶部菜单栏未读图标，查看/归档/删除邮件后即时消退，并支持归档/删除 5 秒一键「撤销」。
- **完整写信体验 (`ComposeCoordinator` + `ComposeMailSheet`)**：支持新邮件、回复、**全部回复（`⌥⌘R`）**、转发（自动带入原附件）、抄送/密送（BCC）、基于本地历史地址的联系人自动补全、按账号配置默认发件签名、拖拽附件（含读取进度条、iCloud 云端文件自动下载与精准报错重试），以及未保存草稿防误丢提醒。

### 内置 AI 助理与多模式订阅登录
- **ChatGPT 订阅（默认）**：浏览器 OAuth PKCE 授权直连 OpenAI Responses API；使用独立应用注册、JWT 身份签名校验与系统钥匙串，支持多账号切换、自动续期和退出撤销。
- **其他可选通道**：本机订阅 CLI（Claude Code / Codex CLI / Gemini CLI）、通用浏览器 OAuth 2.0 PKCE（含 OpenRouter 一键登录）、以及任意 OpenAI 兼容 API Key / 本地 Ollama。
- **本地附件解读 (`AttachmentTextExtractor`)**：纯本地使用 macOS 原生 `PDFKit`、AppKit 文档解析与离线 `Vision` OCR，读取 **PDF / CSV / TXT / MD / JSON / DOCX / RTF / 图片及扫描件** 参与总结、追问或单附件一键解读（受严格体积与字符预算约束，并经 `PrivacyMasker` 本地脱敏）。
- **全箱跨邮件检索问答 & 摘要持久化**：支持在 AI 抽屉切换「全箱检索问答」，自动检索本地相关邮件聚合汇总；单封摘要本地持久化缓存（LRU 300 封），重启不重复耗费额度。

---

## 常用快捷键

| 快捷键 | 功能 |
|---|---|
| `⌘N` | 写新邮件 |
| `⌘R` | 回复当前邮件 |
| `⌥⌘R` | 全部回复 |
| `⇧⌘F` | 转发当前邮件 |
| `⌘F` | 聚焦搜索栏 |
| `Esc` | 清空搜索 / 退出多选 / 关闭弹窗 |
| `⌘J` | 展开 / 收起右侧 AI 对话抽屉 |
| `⌃⌘A` | 归档当前邮件（5 秒内可撤销） |
| `⌘⌫` | 删除当前邮件（5 秒内可撤销） |
| `⇧⌘R` | 刷新本地邮件索引 |
| `⇧⌘N` | 通知系统 Mail.app 立即收信 |
| `⌘,` | 打开偏好设置 |

---

## 构建、测试与安装

无需完整 Xcode，仅需 macOS Command Line Tools（Apple Silicon `arm64`，macOS 14.0+）：

```bash
# 1. 运行全部核心单元测试（41 组核心套件 + ChatGPT 专项测试）
./scripts/run_tests.sh

# 2. 编译打包为标准 macOS .app（自动从 Git Tag 推导版本号，原子替换不破坏旧版本）
./scripts/build_app.sh

# 3. 一键构建、安装到 /Applications/MailPilot.app 并启动（推荐）
./scripts/install_app.sh

# 4. 生成可供分发的 release 压缩包与 SHA-256 校验文件
./scripts/release_app.sh

# 5. 安全同步远端最新提交与标签（仅在 main 分支且工作区干净时 fast-forward，可配合 cron/launchd）
./scripts/auto_sync.sh
```

### 首次使用权限配置
1. **完全磁盘访问权限（必需）**：打开「系统设置 → 隐私与安全性 → 完全磁盘访问权限」，勾选 `/Applications/MailPilot.app` 后重启应用。
2. **自动化权限（首次标已读 / 发信 / 归档时自动弹窗）**：允许 MailPilot 控制「邮件（Mail）」。
3. **本机开发证书（推荐，保留系统权限不因重编丢失）**：首次构建前可运行一次 `./scripts/setup_dev_cert.sh` 创建本机 `MailPilot Dev` 签名证书。

### 对外分发签名与 Apple 公证（可选）
若需面向其他 macOS 用户公开发布以通过 Gatekeeper 校验，可使用 Developer ID 证书与 `notarytool` 运行发布脚本：

```bash
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="MailPilotNotary" \
./scripts/release_app.sh
```

仓库同时内置 GitHub Actions 流水线：
- [ci.yml](.github/workflows/ci.yml)：每次推送或 PR 自动在 `macos-15` 运行测试并验证 `.app` 编译；
- [release.yml](.github/workflows/release.yml)：推送 `v*` 标签自动构建、可选公证并发布带 `.zip` 与 `.sha256` 的 GitHub Release。

---

## ChatGPT 订阅登录说明

- 首次授权会为 MailPilot 建立独立注册；令牌安全存入 macOS 系统钥匙串，不写入源码、日志或普通配置文件。浏览器回调仅监听本机 `127.0.0.1`，可随时取消且超时自动关闭。
- 模型列表由当前授权账号动态返回，所有订阅请求使用 `store: false` 和流式 Responses API；回答中断或额度不足会明确报错，不将残缺输出当作成功。
- 「退出登录」会清除本机令牌并尝试远程撤销；如远程撤销失败，界面会提示前往 [ChatGPT 使用量设置](https://chatgpt.com/settings/usage) 检查权限。

官方参考：[Sign in with ChatGPT](https://developers.openai.com/siwc/token-sharing-open-source/sign-in)、[模型与调用](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference)。

---

## 验证范围

`./scripts/run_tests.sh` 包含 **41 组核心测试**（涵盖只读索引、Gmail 多标签、FTS5 trigram 全文更新/删除与事务回滚、大附件流式分块惰性解析、本地附件文本抽取与离线 OCR 逻辑、附件名索引与日期/附件筛选、8bit GB18030 编码、内嵌 `cid:` 图片、O(1) `.emlx` 分桶定位、kqueue WAL 监听与 `stat()` 兜底、写信附件脚本与 BCC 生成、收件人/本地联系人联想、API Key 钥匙串隔离、OAuth 表单编码等）以及 ChatGPT 专项测试。所有单测均在本地合成数据上运行，不读取真实邮件或凭据。

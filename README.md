# MailPilot

基于 **SwiftUI** 构建的 macOS 原生 AI 邮箱客户端（MVP），将收信、多账号推送、休眠唤醒与发信完全交给系统自带 **Mail.app**，本地只读索引 + FSEvents 实时刷新 + AppleScript 安全写入。

## 核心架构

- **只读索引 (`EnvelopeIndexReader`)**：以 `SQLITE_OPEN_READONLY | SQLITE_OPEN_URI` 严格只读模式访问 `~/Library/Mail/V*/MailData/Envelope Index`，绝不直接写库。
- **本地正文与验证码解析 (`EmlxParser`)**：解析 `.emlx`（支持 `multipart` / `base64` / `quoted-printable` / HTML 清洗），自动识别中英文验证码并提供一键复制横幅。
- **实时刷新 (`MailDirectoryWatcher`)**：通过 macOS `FSEvents` 监听 `MailData` 目录变更，Mail.app 收到新邮件后自动刷新列表。
- **安全委托写入 (`MailAppleScriptBridge`)**：标已读、标星、在 Mail 中打开、创建回复草稿、触发收信全部通过 `osascript` 交给 Mail.app 执行。
- **内置 AI 助手与订阅式登录 (`AIService` + `ChatGPTService` + `KeychainStore`)**：
  - **ChatGPT 订阅（默认）**：浏览器授权登录，Swift 直接调用 OpenAI Responses API；无需安装或登录 Codex CLI，也不读取它的凭据。使用独立应用注册、PKCE、身份签名验证及系统钥匙串，支持账号切换、自动续期和退出撤销。
  - **本机订阅 CLI 模式（可选）**：保留 Claude Code、Codex CLI 和 Gemini CLI 接入，只有主动选择此模式才调用对应工具。
  - **浏览器 OAuth 2.0 PKCE 登录**：内置 OpenRouter 一键登录及自定义标准 OAuth 2.0 PKCE 平台，令牌安全加密存入 macOS 系统钥匙串（支持自动 Refresh）。
  - **API Key / 本地模型**：保留 Ollama / DeepSeek / OpenAI 等任意 OpenAI 兼容接口。
  - 统一支持本地隐私脱敏开关、一键总结、生成回复草稿并直接送入 Mail.app 草稿箱、未读简报与自由对话。

## 构建与运行

```bash
# 运行核心单元测试（仅需 CommandLineTools，无需完整 Xcode）
./scripts/run_tests.sh

# 打包为标准 macOS .app（原子替换，编译失败不破坏上一版本）
./scripts/build_app.sh

# 一键构建并通过 ditto 安全安装到 /Applications 并启动（推荐）
./scripts/install_app.sh
```

## 首次使用权限配置

1. **完全磁盘访问权限（必需，用于只读访问原生邮件索引）**：
   打开「系统设置 → 隐私与安全性 → 完全磁盘访问权限」，将 `dist/MailPilot.app`（或拖入 `/Applications/MailPilot.app` 后）勾选开启，然后重新打开 MailPilot。
2. **自动化权限（首次执行标已读/建草稿时系统自动弹窗）**：
   允许 MailPilot 控制「邮件（Mail）」。
3. **配置 AI 模型**：
   在应用内按 `⌘,` 打开设置 → AI 与订阅 → ChatGPT 订阅，点击「使用 ChatGPT 登录」，在 OpenAI 页面完成账号登录及订阅额度授权。返回应用后选择账号实际可用的模型，再点击「验证连接」。也可选择 API Key / 本地模型等其他接入方式。

## ChatGPT 订阅登录

- 首次授权会为 MailPilot 建立独立注册。登录资料保存在 macOS 钥匙串中，不写入源码、日志或普通配置文件。浏览器回调仅监听本机 `127.0.0.1`，可取消，超时自动关闭。
- 仅登录身份并不等于允许使用订阅额度；需要在 OpenAI 授权页面同意订阅使用权限。额度与接入资格以账号实际授权结果为准。
- 模型列表由当前账号返回，不硬编码可用模型。所有订阅请求使用 `store: false` 和流式 Responses API；回答中断或额度不足会显示错误，不把不完整回答当作成功。
- 「验证连接」只发送一条要求回复 OK 的测试消息，不读取或发送邮件，会消耗少量订阅额度。使用总结、回复等功能时才会按当前隐私设置发送相关邮件内容。
- 「退出登录」会清除本机令牌并尝试远程撤销，保留应用注册标识用于下次登录。若远程撤销失败，界面会提示前往 [ChatGPT 使用量设置](https://chatgpt.com/settings/usage) 检查权限。
- 现有 Codex CLI 配置首次打开新版会切换到 ChatGPT 浏览器登录，原有 API Key、通用 OAuth 和其他 CLI 模式继续保留。

官方接入说明：[Sign in with ChatGPT](https://developers.openai.com/siwc/token-sharing-open-source/sign-in)、[模型与调用](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference)。

## 验证范围

`./scripts/run_tests.sh` 包含 41 组核心测试（涵盖只读索引、Gmail 多标签、FTS5 trigram 全文更新/删除与事务回滚、大附件流式分块惰性解析、本地附件文本抽取与离线 OCR、附件名索引与日期/附件筛选、8bit GB18030 编码、内嵌 `cid:` 图片、O(1) `.emlx` 分桶定位、kqueue WAL 监听与 `stat()` 兜底、写信附件脚本与 BCC 生成、收件人/本地联系人联想、API Key 钥匙串隔离、OAuth 表单编码等）以及 ChatGPT 专项测试。网络调用使用本地模拟，不读取真实凭据、不发送真实邮件。真实账号登录及可用额度仍需在 OpenAI 授权后通过「验证连接」确认。

# AgentDeck

原生 macOS Agent 看板。自动发现本机 tmux 中的 Codex、Claude Code、自定义 Agent，以及 Hermes GUI 会话。

主界面只保留 Agent 卡片和设置。卡片展示小字号实时输出、Context 用量；状态由图标动画、颜色和完成 / 异常徽标表示。没有通知、收件箱、菜单栏常驻项、搜索、新建、筛选和手动刷新入口。

主窗口不在前台时，主屏幕左下角显示半透明置顶悬浮条，每个 Agent 一个图标。拖动图标或空白处可移动整个悬浮条，位置会保留到下次启动，刷新不会复位；显示器断开时会移回可见区域。点击图标返回对应会话详情。悬浮条不会获取键盘焦点，支持多个 Space；主窗口回到前台后自动收起。关闭主窗口继续监控，`⌘Q` 完全退出；退出不会停止 Agent。

## 安装

```bash
brew install --cask laixintao/tap/agentdeck
```

也可以从 [GitHub Releases](https://github.com/laixintao/agentdeck/releases) 下载对应 Apple Silicon 或 Intel 的 DMG / ZIP。要求 macOS 14+。安装包提供 `SHA256SUMS` 和 GitHub 构建来源证明。

应用采用 ad-hoc 签名，尚未经过 Apple 公证。首次打开如被拦截，按 [Apple 的说明](https://support.apple.com/zh-cn/102445)在「系统设置 → 隐私与安全性」中选择「仍要打开」。

更新：`brew upgrade --cask laixintao/tap/agentdeck`。

## 从源码运行

要求 macOS 14+、Swift 6 / Xcode。终端 Agent 需要 tmux（`brew install tmux`）；Hermes GUI 使用本地 Gateway。

```bash
./scripts/build-app.sh
open dist/AgentDeck.app
```

可把 `dist/AgentDeck.app` 拖到「应用程序」。本地构建采用 ad-hoc 签名，没有 Developer ID 公证，二进制按当前 Mac 架构构建，无第三方 Swift 依赖。

`⌘,` 打开设置。点击卡片标题查看完整输出、发送消息、中断任务或打开原应用。等待确认时使用「前往确认」。主界面预览和详情支持文本选择；详情可以暂停跟随输出。

## 状态与图标

- Codex：command 图标与旋转轨迹。
- Claude：旋转、呼吸的星芒。
- Hermes：使用 Hermes Desktop 官方图标原文件，运行时轻微摆动。
- 等待回答 / 确认：琥珀色脉冲与暂停徽标。
- 完成：绿色对勾；异常：红色感叹号。空闲、完成状态不持续动画。

遵循 macOS「减少动态效果」及「减少透明度」。约每 2 秒读取一次状态。输出暂停、回到输入提示符或界面重绘不会标记完成，也不会让工作状态因静默变为空闲。连接暂时失败保留上次状态，错误在设置中展示。

完成只依据明确事件：Codex `task_complete`、Claude `turn_duration`、完成 hook、Hermes Gateway 完成事件，或 Agent 正常退出。单个工具完成、Claude 的一条 `end_turn` 回复都不等于整个任务结束。无法精确关联会话日志时保留运行 / 未知状态，不猜测完成；已经完成后，普通输出变化不会重新触发运行状态。Codex 已关联的当前会话事件优先于 pane 级 hook（未关联时回退到 hook），避免旧会话的延迟 hook 覆盖新任务。

Claude 在空闲时自动压缩上下文产生的摘要和仅供 transcript 展示的消息，不视为新任务，保留之前的任务状态。

Codex 的 `Queued follow-up inputs` 中有待回答 question 时，即使同时显示 `Working`，图标也显示等待回答；回答后随终端状态恢复。

## Context 与实时输出

- **Codex**：优先用终端当前会话标题和工作目录唯一匹配本机只读会话索引，并校验 rollout 日志中的会话 ID 和目录，支持多个终端共享 app-server daemon。旧版 CLI 可回退到交互进程直接打开的唯一 rollout 文件，不读取共享后台服务或嵌套 agent 的文件来猜测归属。重名、日志缺失或索引不一致时不匹配。读取 `last_token_usage.total_tokens / model_context_window`，不使用累计消耗。
- **Claude**：根据 PID 注册文件、UTC 进程启动时间和 session ID 关联 transcript。用量为最近一次输入 token，包含 cache read / creation；上限读取本机当前模型目录的 `runtime.max_input_tokens`，尊重进程 context 上限配置。上限不可用时仍显示已用 token 数。预览读取文本和工具调用，不展示 thinking 数据。
- **Hermes GUI**：使用 `session.stats` 的 `context_tokens / context_length`，可回退到输出事件中的 `context_used / context_max`。
- 终端还支持显式状态栏：`81% context left`、`Context: 42% used`、`Context: 32k / 128k`。完全缺少数据时显示 `—`，悬浮提示说明来源。

卡片直接滚动显示最新输出，过滤输入框装饰、快捷键及运行页脚。点击标题展开详情。数据来源和原始 token 数可通过 Context 悬浮提示查看。

## Hermes GUI

默认读取 `~/.hermes/gateway.sock` 或其私有路径指针，校验权限和同用户 socket 对端，通过短期 ticket 连接 Gateway 的 loopback WebSocket。

- `session.active_list` 发现活跃会话与工作 / 等待状态。
- 不展示接口明确报告「没有消息且空闲」的 GUI 空会话；刚开始工作或等待回答的会话即使消息数为零也保留。只过滤显示，不关闭或删除 Hermes 会话。
- `session.stats`、`session.events.since` 获取 Context、工具调用、输出及完成事件。
- 被动扫描不 attach、不刷新策略，也不启动或重启 Hermes。
- 用户发送 / 中断时才调用 `session.resume`，再调用 `prompt.submit` 或带当前 execution generation 的 `session.interrupt`。
- 「打开 Hermes」激活桌面应用；尚未确认可用的会话 deep link，详情菜单可复制 session ID。
- 已验证本机安装版本的 `session-authority-v1` 协议。旧版及远程 Gateway 暂不支持。

```bash
./dist/AgentDeck.app/Contents/MacOS/agentdeckctl scan --hermes
```

Hermes 官方图标复制自安装源码的 `apps/desktop/assets/icon.png`，未经修改；许可见 `Resources/Hermes-LICENSE`。

## 终端精确状态

现有终端会话可以直接观察；通过 helper 启动后还能接收精确 hook 状态：

```bash
/path/to/AgentDeck.app/Contents/MacOS/agentdeckctl run --kind codex -- codex
/path/to/AgentDeck.app/Contents/MacOS/agentdeckctl run --kind claude -- claude
/path/to/AgentDeck.app/Contents/MacOS/agentdeckctl run --kind custom --title "任务" -- /path/to/agent
```

Codex 使用本次启动的 `notify` 配置；Claude 使用本次启动的 `--settings` hooks。不会修改磁盘上的全局配置，也不重启已运行会话。状态事件仅供图标判断，不发送通知。

经典 Hermes CLI 可在设置中点击「接入 CLI hooks」。安装器备份 `config.yaml`，保留已有 hooks，加入 `pre_llm_call`、`post_llm_call`、`on_human_input_request`、`on_human_input_resolved`。通过 `terminal-sessions/tty-*` 的 session ID 关联 pane；不修改 `hooks_auto_accept`。下次启动按 Hermes 提示批准观察 hooks。GUI 无需安装这些 hooks。

通用状态回调：

```bash
agentdeckctl event --state working
agentdeckctl event --state waiting
agentdeckctl event --state completed
agentdeckctl event --state failed
```

## 本地数据与操作

只读取目标 pane、精确匹配的会话日志 / 元数据及 Hermes 本地接口。无需 API Key；从进程环境仅提取 context 上限字段，不输出或保存其他字段。不会上传内容到外部服务。

终端约 120 行历史、最多 2 MB 会话日志尾部和 Hermes 有界事件输出仅在内存中处理。`~/Library/Application Support/AgentDeck/events` 的无正文状态事件保留 7 天，`state.json` 仅保存事件去重游标；不生成通知历史。

终端发送使用独立的 tmux buffer 和 bracketed paste，等待粘贴处理后单独发送 Enter，以提交新消息。不会改动系统剪贴板或已有 tmux buffer。拒绝控制字符 / 多行文本；输入前及提交前复核进程身份，避免发到已退出 Agent 的 shell。发送失败保留输入框里的消息。「打开终端」通过 AppleScript 调用 Terminal，可能需要 macOS 自动化授权，也可复制连接命令手动使用其他终端。远程 SSH 和其他桌面 Agent 暂不支持。

## 版本发布

安装版本工具：`pipx install bump2version==1.0.1`。在干净的 `main` 分支执行：

```bash
make release                  # 内部调用 bumpversion，递增 patch 并原子推送 main 和版本标签
make release VERSION=0.2.0    # 指定更高版本
```

也可以直接使用 bumpversion，然后一次推送分支和标签：

```bash
bumpversion patch            # 同时更新 VERSION、Info.plist，创建提交和 vX.Y.Z 标签
git push --atomic origin main "v$(cat VERSION)"
```

`v*` 标签触发 GitHub Actions。流程运行测试，分别构建 macOS 14+ 的 Apple Silicon / Intel 应用，验证签名、版本、架构及 ZIP/DMG 内容，生成 `SHA256SUMS` 和构建来源证明，再发布 GitHub Release。发行资产命名遵循 [Homebrew tap 发布规范](https://github.com/laixintao/homebrew-tap/blob/main/docs/RELEASE_STANDARD.md)。已公开的 Release 不会被覆盖；失败的 draft 可以重跑对应版本的 Release workflow。

`make release` 推送失败时保留本地提交和标签，并给出精确重试命令。使用该命令重试，不要再次 bump。Homebrew tap 使用现有的六小时自动同步机制，无需跨仓库 token。

## 开发与验证

```bash
./scripts/test.sh
./scripts/build-app.sh debug
open -n dist/AgentDeck.app --args --demo
```

测试脚本自动使用完整 Xcode 的 XCTest。隔离的 tmux / 模拟 Gateway 测试覆盖发现、字面量输入、Context、PID 复用、事件回放及中断，不操作真实用户会话。

原生界面与悬浮条验证（debug）：

```bash
AGENTDECK_DATA_DIR="$PWD/artifacts/runtime-data" \
  dist/AgentDeck.app/Contents/MacOS/AgentDeck \
  --verify-runtime "$PWD/artifacts/runtime-report.json"
```

验证状态、输入、去重、详情路由，以及悬浮条在最小化 / 隐藏 / 恢复主界面时的行为、主屏幕左下角定位、图标和空白处拖动、位置持久化、屏幕边界、置顶和不抢焦点。报告与悬浮条预览写入指定 artifacts 目录。

<h1 align="center">Agent HUD Open · 仅看板</h1>

<p align="center">
  Claude Code、Codex 以及另外 15 款 agent 的额度窗口、API 余额、过去 24 小时的 Token 与最近的会话，集中在一块面板里：从 Mac 的刘海，或任意屏幕边缘的一排 agent 图标展开。
</p>

<p align="center">
  <a href="#从源码构建"><img src="docs/badges/macos.svg" alt="macOS 14+" height="22"></a>
  <a href="Package.swift"><img src="docs/badges/swift.svg" alt="Swift 6" height="22"></a>
  <a href="LICENSE"><img src="docs/badges/license.svg" alt="Apache-2.0 许可证" height="22"></a>
</p>

<p align="center">
  <a href="README.md">English</a> · <strong>简体中文</strong> · <a href="#支持的-agent">支持的 agent</a> · <a href="#文档">文档</a>
</p>

这是 [Agent HUD Open](https://github.com/jazzenchen/agent-hud-open)（Swift 编写的 macOS 应用）的仅看板版本，从上游 v0.5.3 分叉而来。上游此后已转向另起炉灶的 Rust/Tauri 重写版。本分支保留 Swift 代码，只留下核心的看板，其余全部移除。应用仍叫 Agent HUD Open，包内版本号仍是 0.5.3。

## 看板

把指针悬停在刘海或图标上，面板就会展开。自上而下：

- **刷新失败**：上一次刷新失败时，说明出了什么问题。
- **额度**：每个厂商的额度窗口，按账户分组，显示每个窗口还剩多少、何时重置。已用不足 70% 为绿色，达到 70% 为黄色，达到 90% 为红色。每个厂商的区块可在剩余比例（%）、消耗速率与每小时 Token（#）之间切换；悬停在某一行上会给出它的走势，例如按当前速度何时用完。Codex 账户列出可用的额度重置次数，Grok 列出预付余额与按需用量。
- **余额**：按用量计费的 API（例如 DeepSeek 的 API）显示账户余额，以及过去 24 小时的费用估算。
- **Token**：过去 24 小时，共 96 根 15 分钟的柱，每个模型用自己的颜色堆叠，计入所有 Token 类型。悬停在柱上显示该时段及每个模型的 Token。
- **会话**：最多五个。正在进行的排在最前，其中等你处理的在仍在运行的之前；其后是过去一天内活跃过的会话。「还有 N 个」统计其余会话。每一行显示 agent 的图标（角上标出会话状态）、会话标题与 Token 数。会话行不能点击。

面板底部左侧是设置（齿轮），右侧是退出（电源图标）。每次展开面板都会重新读取各账户的额度，每个 agent 每分钟最多一次。「设置 → 显示 → 展开面板」可以分别开关额度与余额、重置倒计时、Token 图表和会话列表。

## 形态与设置

每块屏幕从三种形态中选一种，在「设置 → 显示 → 屏幕」中设置：

| 形&#8288;态 | 屏幕上的样子 |
| --- | --- |
| **刘&#8288;海** | 有刘海的屏幕默认使用：HUD 待在刘海处。没有刘海的屏幕上，会在顶部居中画一条黑条代替。 |
| **动&#8288;态** | 其余屏幕默认使用：一排 agent 图标停靠在任意屏幕边缘，图标直接显示，背后没有底色。可以把这一排拖到别的边缘或位置；拖动刘海会切换为「动态」。 |
| **关&#8288;闭** | 这块屏幕上没有 HUD。所有屏幕都关闭时，主屏幕仍保留 HUD，因为只能从它的面板进入设置。 |

这一排图标先列出你关注的 agent，再列出过去一天内运行过的其他 agent；共用同一图标的 agent 只占一个位置。展开的面板和刘海带一层柔和的阴影；收起时的一排图标没有阴影。

设置从面板底部的齿轮进入：

- **通用**：外观、语言（英文或简体中文）、登录时启动，以及客户端回调。
- **智能体**：每个 agent 要显示哪些账户与窗口、它们的顺序、实时状态；GitHub Copilot 还需在这里同意读取额度。Pi 与 OpenCode 会说明观察器是否已就位。
- **显示**：每块屏幕的形态、重置位置、Logo 大小、离屏幕边缘的距离、间距与「显示 Logo」（关闭后，这一排仍占着原来的位置，悬停在那里照样展开面板）；面板显示哪些内容；以及悬停交互：按 Option 才展开、鼠标触顶立即展开、展开延迟与收起延迟。

## 移除了什么

与上游 v0.5.3 相比，以下内容的代码与界面都已移除：

- 光晕，包括所有样式与效果、相关设置和 ⌘⌥H；Bot 动画。
- 简约形态，以及「按 agent 分开」和它的单个 agent 卡片。
- 灵动岛上的提醒：额度预警、新增额度重置、「有新回复」。
- 在 HUD 上回答批准请求与提问，包括所有客户端、Codex Desktop、Antigravity 与 DeepSeek Harness。
- 从 HUD 回到会话。
- 统计窗口、菜单栏图标及其菜单、首次启动窗口。
- 演示模式、演示脚本、`--snapshot` 与 `--record`。
- 宿主扩展点：额外的设置页、菜单项、HUD 控件与灵动岛事件转发。
- Beta 更新源。

## 客户端回调

「设置 → 通用」中的**客户端回调**默认打开。打开时，每次启动都会把以下回调指向当前运行的这份应用，并为已安装的 agent 补上缺失的回调：

- **Claude Code 的通知回调**：Claude Code 请求权限或等待输入时，它的会话显示为等待批准。
- **GitHub Copilot CLI 的停止回调**：仍在运行的 Copilot 回合会立即结束。
- **Pi 的扩展与 OpenCode 的插件**：Pi 回合的运行与结束（没有它，Pi 会话永远不会显示为运行中），以及 OpenCode 回合的结束。

功能更完整的版本给 Antigravity、Cursor、CodeBuddy 与 Qwen Code 装的停止回调只用于回合提醒（这些客户端的会话从不显示为运行中），每次启动都会移除。关闭客户端回调会移除 Agent HUD 的所有回调，无论是哪一份应用添加的，之后也不再写回；用量、额度与会话不受影响。

**已停用的回调。** 功能更完整的版本还会安装 `--permission-hook <client>`（在 HUD 上回答批准请求）和 `--session-origin-hook <claude|codex>`（找到会话所在的终端）。仍在调用它们的客户端会立即得到回应，应用不会因此启动：批准请求得到空回应，客户端照常显示自己的提示；会话来源回调得到 `{}`。每次启动、每次切换客户端回调时，都会从 Claude Code 的 `settings.json`、Codex 的 `hooks.json`，以及 Qoder、Qoder CN、QoderWork、CodeBuddy、WorkBuddy、ZCode 与 Qwen Code 的设置中，移除指向这份应用自身可执行文件的这类回调；其他程序的回调保持不动。详见[已停用的回调](docs/session-lifecycle.md#retired-handlers)。

## 支持的 agent

安装并登录想要监测的 agent，应用会自动发现它们。17 款都提供 Token 与会话。

| Agent | 额度 | 实时状态 | 客户端回调 |
| --- | :---: | :---: | --- |
| **Claude&nbsp;Code** | ✓ | ✓ | 通知回调 |
| **Codex** | ✓ | ✓ | |
| **DeepSeek&nbsp;Harness** | 余额 | ✓ | |
| **Antigravity** | ✓ | | |
| **Cursor** | ✓ | | |
| **Grok&nbsp;CLI** | ✓ | ✓ | |
| **Grok&nbsp;Bot** | ✓ | | |
| **GitHub&nbsp;Copilot&nbsp;CLI** | ✓ | ✓ | 停止回调 |
| **OpenCode** | ✓ | | 插件 |
| **Kimi** | ✓ | ✓ | |
| **Pi** | ✓ | ✓ | 扩展 |
| **OpenClaw** | | ✓ | |
| **Hermes&nbsp;Agent** | | | |
| **ZCode** | | | |
| **CodeBuddy** | | | |
| **WorkBuddy** | | | |
| **Qwen&nbsp;Code** | | | |

实时状态指面板会显示哪些会话正在运行；只有 Claude Code 的会话还会显示等待批准，Pi 需要它的扩展。另外还读取 **GLM Coding Plan** 的额度。Copilot 的额度需先在「设置 → 智能体」中同意读取。其余见[各 agent 的详情](docs/providers.md)。

## 你的数据

- **在这台 Mac 上读取**：各 agent 已经保存的记录。用量历史保存在本机数据库中。
- **向各厂商读取**：额度、余额与账户用量，使用 agent 现有的登录状态或已配置的密钥。任何一次读取都不会向模型发送消息，凭据不会被保存。
- **在这台 Mac 上写入**：上述客户端回调，写在各 agent 自己的设置与目录中，以及它们留给应用的记录；每次启动时，还会从这些设置中移除这份应用已停用的回调。「设置 → 通用」里的**客户端回调**开关可移除这些回调。
- **上传**：不上传任何数据。

用 `make build` 构建的应用把数据放在 `~/Library/Application Support/Agent HUD Open Desktop`（其 `Info.plist` 指定了这个目录）；未指定目录时为 `Agent HUD Open`。另见[数据访问](docs/data-access.md)。

## 从源码构建

**环境要求：** macOS 14+，以及包含 Swift 6 工具链的 Xcode 或 Xcode 命令行工具。无需开发者账户、签名身份或预置描述文件。

| 命令 | 用途 |
| --- | --- |
| `make build` | 构建 `build/Agent HUD Open.app`，使用临时签名供本机运行 |
| `make run` | 构建并打开应用 |
| `make test` | 运行单元测试（`swift test`） |
| `make check` | 检查源码边界 |
| `make clean` | 删除 `.build` 与 `build` |

不用 `make` 时，`swift test` 同样会运行测试。`--open-panel`、`--show-settings`、`--probe` 等启动参数见[命令行](docs/command-line.md)。

Swift 包提供 `AgentHUDSupport`（记录与身份）、`AgentHUDCore`（数据源、模型、存储与客户端回调）和 `AgentHUDDesktop`（HUD 与设置窗口）；`AgentHUDOpen` 是独立可执行程序。宿主可以嵌入这些库并提供自己的数据源，详见[宿主集成](docs/architecture.md#host-integration)。持续集成检查源码边界、运行单元测试、构建应用，并验证签名与资源。

## 文档

[屏幕上的 HUD](docs/hud.md) · [数据源](docs/providers.md) · [用量口径](docs/usage-semantics.md) · [会话生命周期](docs/session-lifecycle.md) · [数据访问](docs/data-access.md) · [架构](docs/architecture.md) · [性能](docs/performance.md) · [命令行](docs/command-line.md) · [品牌素材](docs/brand-assets.md) · [变更记录](CHANGELOG.md)

## 许可证

[Apache-2.0](LICENSE)。数据源引用与图标素材沿用各自的[第三方声明](THIRD_PARTY_NOTICES.txt)与[图标许可](Sources/AgentHUDDesktop/Resources/LobeIcons-LICENSE.txt)。

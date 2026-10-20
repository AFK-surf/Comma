# 运行 still.fail

Comma 怎么运行 station 见 [README](../README.md)。

## 安装与启动

在 [still.fail web](https://app.still.fail) 的 workspace 设置里添加 station，按页面生成的一次性命令安装并加入 workspace。安装器把发布包放到 `~/.stillfail/app`，把 `stillfail` 链接进 `~/.local/bin`，并注册用户服务（macOS 用 launchd，Linux 用 systemd）。`stillfail update` 更新发布包，`stillfail status` 查看绑定与连接状态。这样装的 station 默认在空闲时自动更新到所在通道的新版本。`config.json` 里 `"autoUpdate": false`（或 Updates 页面关掉）即不再自动更新。桌面应用自带的 station 随应用更新。

station 必须加入 workspace 才接 Slack、运行 agent。数据默认在 `~/.stillfail`（`STILLFAIL_DATA` 可改，兼容 `EMBER_DATA`）。开发测试使用独立数据目录，不使用已有真实会话的 station。

更新支持原地交接：启动器（`native/launcher`，pid 不变）收到 SIGUSR2，起新版本的 Node 进程，新的就绪后放掉旧的。轮次、运行时和 job 不断（`native/launcher/src/run.rs`、`src/ops/launcher.ts`）。

## 管理界面

管理 station 从 workspace 内进入，通过客户端 core 与 station 建立带成员凭证的连接。本机管理端口 4760 只重定向到 cloud。4750 是 agent MCP 端点，不要对公网暴露。这两个端口默认只监听本机，实际端口以 station 的运行记录为准。

新安装使用 workspace 设置管理连接、账号和 station，控制面设计见 [cloud.md](cloud.md)。

## config.json

也可以直接编辑，格式如下（改完需要重启 still.fail）：

```json
{
  "connects": [
    { "id": "ds", "kind": "slack", "mode": "multi-session",
      "bind": { "runtime": "claude", "profile": "claude-ocg", "model": "deepseek-flash" },
      "slack": { "appToken": "xapp-…", "botToken": "xoxb-…" } },
    { "id": "ops", "kind": "slack", "mode": "single-session", "requireMention": false,
      "bind": { "runtime": "codex" }, "enabled": false }
  ],
  "profiles": [
    { "id": "claude-ocg", "name": "OpenCode Go（Claude Code）", "runtime": "claude", "home": "homes/claude-ocg",
      "access": { "kind": "opencode-go", "key": "…" } },
    { "id": "codex-main", "runtime": "codex", "home": "homes/codex-main", "access": { "kind": "subscription" } }
  ],
  "maxNudges": 2,
  "warmMinutes": 30,
  "maxWarmClaude": 4,
  "autoArchiveDays": 1,
  "telemetry": { "errors": false }
}
```

- 连接的 `id` 是会话记录的一部分，创建后不要改。`bind.profile` 可省略，省略时由账号池在该运行时启用了这个模型的账号里挑。
- `autoArchiveDays`：空闲且已结束的会话和对话多少天后自动归档，0 为不自动归档。
- 账号的 `home` 相对数据目录。用订阅登录时，对这个目录登录一次：`CLAUDE_CONFIG_DIR=<home> claude`，或 `CODEX_HOME=<home> codex login`。
- `env` 里的 `{route}` 会替换成每个会话的路由 ID（Codex 的 app-server 按账号共享，替换成账号 ID），用于 OpenCode Go 这类需要会话亲和头的服务。
- 账号的 `access` 决定运行时怎么接模型：
  - `subscription`：订阅登录。
  - `opencode-go`、`anthropic-api`：要 `key`。
  - `api-provider`：用 `provider` 指定服务商（如 `openai`、`deepseek`、`openrouter`、`azure-openai`、`custom`），再加 `key`。Azure OpenAI、Cloudflare、`custom` 还要 `endpoint`，`custom` 的 key 可省。服务商有 Anthropic 接口的跑 Claude Code，有 Responses 接口的跑 Codex，有 Chat Completions 接口的可用于自动决策。只有 Chat Completions 的服务商不跑任何运行时。
  - `env`：只用 `env` 里手写的变量。
- `mesh.port`（可选，默认不设）：station 的 IPv4 QUIC（iroh）socket 固定绑定 `0.0.0.0:<port>`，重启和更新后端口不变，防火墙可以只放行这一个 UDP 端口。不设时每次启动用任意空闲端口。IPv6 socket 总是用任意空闲端口。值必须是 1–65535 的整数。端口被占用或值不对时，station 不上 mesh，日志写 `mesh stopped`，不换用别的端口。设了这个端口时，更新交接中新进程先等旧进程退出（最多 40 秒）再绑定，这段时间 mesh 连不上。
- `telemetry.errors` 打开后，这台 station 的错误（不带内容）上报到 still.fail 的 PostHog 项目，默认关闭，见 [telemetry.md](telemetry.md)。
- 共享的记忆和 skills 在 `<数据目录>/agent/`（`MEMORY.md` 和 `skills/`），启动时链接进每个账号的配置目录。

## 会话方式

- **多会话**（`multi-session`）：每个 thread 一个会话。在 thread 里 @ 它开始，之后这个 thread 的回复都进这个会话。私聊直接开会话。
- **单会话**（`single-session`）：这个连接看到的所有 thread 进同一个会话。`requireMention: true`（默认）时，被 @ 的 thread 才会进来，进来之后的回复不用再 @。`false` 时它能看到的每条消息都进来。

两种方式下，agent 收到的每条消息都带着来源（`thread="频道/thread_ts"`），回复时必须用 `to=` 指明发到哪个 thread，没有默认位置。

## 在 Slack 里使用

- `@名字 <任务>`：开始一个会话（单会话连接则把这个 thread 带进它的会话）。
- 同一个 thread 里可以 @ 多个连接，它们各自有独立的会话。
- `-stop`：中断当前 turn。

## 原生部分

原生部分预编译，见 `scripts/native.ts`。不要在不同检出路径之间共享 Cargo target：vendor 里的 iroh 会按每个路径编一份，rustc 会拿错（E0308「multiple different versions of crate iroh_relay」）。

# still.fail 设计

still.fail 是团队聊天里的 coding agent 服务。人在 Slack 或 still.fail 的网页对话里找它。每个对话落到一个持久的 agent 会话，agent 由 Claude Code 或 Codex 驱动。会话在 hot / warm / cold / 归档之间流转，归档后有新消息就自动恢复。

本文只记录已确定的设计和约束。实现细节以源码为准。

## 1. 边界

- **station（宿主）负责**：聊天接入、会话身份与状态、入站消息持久化、结束状态约定、后台任务、账号池、进程数量、会话 workspace 与归档、可观测性。
- **运行时驱动负责**：启动 / 恢复 / 结束 agent 进程，送入输入，读出事件流。
- agent loop、上下文压缩、内置工具属于 Claude Code / Codex 本身，still.fail 不改写。
- **still.fail cloud 只管人**：账号、workspace、成员和成员凭证。客户端（网页、桌面、Android）通过 iroh 直接连 station，不经过业务服务器。见 [cloud.md](cloud.md)。

## 2. 进程结构

station 是 TypeScript（`src/`，跑在发布包自带的 Node 上）。原生部分只有三件，都预编译：启动器 `stillfail-station`（`native/launcher`）、每个 agent 一个 runner（`native/runner`）、iroh 和图片编解码的 Node 插件（`native/mesh`）。见 [station-ts.md](station-ts.md) 和 [station-ts-native.md](station-ts-native.md)。

station 由 launchd（macOS）或 systemd 用户服务（Linux）托管。桌面端自带一份，作为子进程用 `--with-parent` 启动。

```
Chat 接入(Slack / 网页对话) ── Store(SQLite) ── SessionActor(每个会话一个，串行)
                                                    │
                                              AgentDriver(claude / codex)
                                                    │
                                    MCP 端点(HTTP, 127.0.0.1) ◄── agent 调用
Jobs   账号池   空闲进程回收   自动归档
管理 API ◄── iroh(客户端，带 still.fail cloud 签发的成员凭证)
```

## 3. 聊天接入

- 接口与平台无关：入站消息（thread 坐标、作者、文本、附件）和出站操作（发消息、读历史、状态提示）。实现有两个：Slack Socket Mode，以及 station 自己的网页对话（固定连接 `ember`，thread 为 `EMBER/…`）。
- 入站事件**先写库再 ack**。写库失败就不 ack，让 Slack 重投。按 thread + 消息 ts 去重。
- 在一个 thread 中途加入时，先补记之前的消息（不投递），让 thread 的记录完整。
- 哪些消息进哪个会话由连接的会话方式决定（多会话 / 单会话，见 [operations.md](operations.md)）。每条进来的消息都转给 agent，由 agent 判断是否与它相关。

## 4. 会话

- 一个会话可以在多个 thread 里（单会话连接、网页对话把会话拉进来）。一个 thread 里也可以有多个会话。
- runtime 在会话创建时确定，之后不能换。model、effort、profile 可以在两个 turn 之间改。
- Slack 会话用连接绑定的 runtime / model / effort。连接绑定了 profile 就用它，否则由账号池挑。网页对话由发起人选。
- 会话的所有状态变更都在它的 actor 里串行执行。
- 输入投递：
  - 空闲时 `prompt`
  - turn 进行中 `steer`（Claude 的 profile 可以先把 turn 正在等的命令和子 agent 挪到后台，让消息立刻被读到）
  - 不能 steer 时留在库里的待投递队列，turn 结束后投递

## 5. 运行时驱动

still.fail 定义自己的接口（`src/agents/runtime.ts`），其余部分只依赖这层。运行时发生的事按顺序作为事件送回会话自己的任务，不用回调。

- 两个驱动都自己实现，共用一套进程管理（进程组、stdin）。账号相关全部自己实现。
- 驱动层把 turn 失败归一分类：认证失败、限流、模型错误、进程退出、其他。
  - Claude 的 turn 成败看 `result.is_error`，不看 `subtype`（认证失败时是 `subtype: "success"` + `is_error: true`）。
  - Claude 遇到 401/403 会静默重试数分钟，只发 `system/api_retry` 帧。驱动在第一个 401/403 的 `api_retry` 就判定认证失败并中止 turn。
- **Codex：每个账号共享一个 app-server**，多个会话按 thread 复用同一个进程。
  - 与会话相关的配置（MCP token 等）通过 `thread/start` / `thread/resume` 的 `config` 按 thread 传入，不放进进程环境变量。
  - thread 以 `approvalPolicy: "never"` + `sandbox: "danger-full-access"` 启动。否则 MCP 调用会被拒绝。
- **Claude：每个会话一个 `claude -p` 进程**（stream-json 输入输出）。会话在进程启动时绑定，进程不能复用。
- 子进程的 stdin 必须由驱动持有或显式关闭。两个 CLI 都会读 stdin。

## 6. 给 agent 的工具（MCP）

still.fail 直接提供 HTTP MCP，不为每个会话另起进程。工具的名字、参数和说明在 `src/tools/`。

- 每个会话有自己的 token，MCP 服务按 token 识别会话。agent 不能冒充其他会话。
- `slack_api` 以连接的 Slack bot 身份调 Web API。别的会话所在的 thread 不能写。
- Claude：启动时用 `--mcp-config` 传入 MCP 服务，header 为 `Authorization: Bearer ${STILLFAIL_MCP_TOKEN}`。token 作为该会话进程的环境变量注入。
- Codex：MCP 服务不写进账号配置。`thread/start` / `thread/resume` 的 `config` 按 thread 传 `mcp_servers.stillfail.url` 和 `mcp_servers.stillfail.http_headers`，因为一个 app-server 进程承载多个会话。

## 7. 结束状态约定

- agent 的最终回答**不自动转发**。agent 用 `chat_post` 发送，并用 `to` 指明发到哪个 thread。
- 每个 turn 结束时要声明 `all_done` / `need_human` / `waiting` 之一（`chat_post` 的 `kind` 或 `chat_state`）。旧写法 `final` / `block` 仍被接受。
- turn 结束时没有声明：提醒 agent 补上，最多 `maxNudges` 次。超过后在 thread 里说明"停下来了但没有明确结果"。
- 声明了 `waiting` 的，到预计时间还没有东西唤醒它（任务结束、有人回复），就再问它一次。
- 失败的 turn：
  - Claude 认证失败：重开进程一次，用续写提示接着做，不重放原请求。
  - 限流：station 管账号时换到另一个 profile 接着做。没有可换的就在 thread 里说明，等设置变化。
  - 其他失败：分类后在 thread 里说明，不自动重试。

## 8. 后台任务

- agent 用 `job_start` 让 station 执行 shell 命令，agent 不自己跑 sleep 循环。每个任务在独立进程组里跑，输出写日志文件。
- 任务结束时通知 agent。任务里可以用 `stillfail-job notify <文字>` 随时给 agent 发消息。通知作为输入注入会话，唤醒 agent。
- 带 `port` 的是 web 服务：一直保持运行（退出后按递增间隔重启），workspace 成员经 still.fail cloud 的链接打开。
- station 重启后，原来在跑的任务继续，没活下来的重新启动，并告诉 agent。

## 9. 账号池

- profile = 运行时配置目录 + 接入方式（订阅 / API key / 自定义 env）+ 启用的模型 + 登录检查和额度缓存。
- 新会话只在启用了所选模型的 profile 里挑，跳过登录失效、key 被拒或额度用尽的。
- 已有会话尽量留在原账号（运行时缓存在那个账号上），不可用时换一个。运行时会话记录按 runtime 放在所有 profile 共享的目录里，换账号 resume 不需要迁移。

## 10. 内存

进程是最贵的资源。

- **hot**（turn 进行中）：绝不驱逐、绝不暂停。
- **warm**（turn 结束后）：进程保留 `warmMinutes`。
- 空闲的 Claude 进程超过 `maxWarmClaude` 个时，超过 warm 时长的按最久空闲先结束。Codex 的 thread 共用 app-server，不回收。
- **防泄漏**：
  - 每个 runtime 进程放进独立进程组，dispose 时整组结束
  - 进程组 ID 和启动时间记进 SQLite。启动时清理上一轮遗留，按启动时间确认是自己的，防 pid 复用

## 11. 磁盘

**少写**
- 不重复存储运行时的原始事件，运行时自己已经存了完整会话记录。still.fail 只存 thread 里的消息和精简的 turn 记录（起止时间、结果、声明的状态）。
- 仓库共享：规范 clone 放在 `<数据目录>/repos`，会话在自己的 workspace 里从它建 git worktree。

**归档**
- 空闲超过 `autoArchiveDays` 且已结束的会话和对话自动归档（没有在跑、没有在跑的后台任务、没有待投递、没有停在 `need_human`、发起人没有未读、没有单会话连接绑着）。也可以手动归档。
- 归档的会话从列表隐藏，空闲进程结束。会话空闲后，workspace 里可重新生成的目录被删除，其余 workspace 和运行时会话记录被压缩。下次运行或重新显示前先恢复。
- thread 的会话全部归档后，它的消息写成 `archive/threads/<id>.jsonl.zst` 并从库里删除，读时从文件读。
- 有人在 thread 里说话，或手动恢复，就恢复成活跃状态。文件布局见 [station-storage.md](station-storage.md)。
- 删除会话时，删掉它的 workspace 目录和压缩副本。运行时的会话记录留在原处。
- 会话记录文件是 resume 的全部依赖：
  - Claude：`$CLAUDE_CONFIG_DIR/projects/<cwd 编码>/<id>.jsonl`。路径里编码了 cwd，所以 workspace 路径必须保持不变。
  - Codex：`$CODEX_HOME/sessions/YYYY/MM/DD/rollout-…-<id>.jsonl`。

**稳健性**
- 全程只用一个用户运行。

## 12. 存储

- SQLite，一个库 `stillfail.db`。表结构和变更通知见 [station-storage.md](station-storage.md)。
- 运行时会话记录按 runtime 放在 `<数据目录>/transcripts/<runtime>`，每个 profile 目录里的 `projects/`（Claude）/ `sessions/`（Codex）链接到那里。

## 13. 可观测性

- 管理页：网页版 / 桌面端 / Android 经 iroh 连到 station。不在 workspace 里的 station 不干活，`stillfail status` 说明它在哪、为什么停着。管理页能看会话、执行历史（运行时会话记录 + 进行中 turn 的实时步骤）、进程和后台任务，并做管理操作。
- 多会话连接在 Slack 里新开的会话，先在 thread 里贴一个"在 still.fail 里查看这个会话"的链接（station 加入 workspace 之后）。
- 错误上报和链路追踪都可选，默认关闭，见 [telemetry.md](telemetry.md)。

## 14. 计划中、尚未实现

- **内存预算**：软上限超出时回收空闲进程，新 turn 照常启动。硬上限（swap 或内存压力超过阈值）才让新 turn 排队，并在 thread 里说明原因。现在只按 `maxWarmClaude` / `warmMinutes` 回收空闲的 Claude 进程，不看内存。
- **孤儿进程对账**：定期结束带 still.fail 实例标记但在会话表里找不到主人的进程。现在只在启动时清理上一轮遗留。
- **Slack 漏消息补查**：定期对活跃 thread 补查漏掉的消息。现在靠先写库再 ack、Slack 重投。
- **后台任务心跳超时**：任务超时没有心跳就判定失败。现在只看进程是否结束。
- **按磁盘预算回收**：数据目录有总预算和最低空闲空间，超出时依次回收：调试日志 → 最久未用的会话归档 → 删除最老的归档 → 共享仓库 `git gc`、删除长期不用的仓库。现在只有按空闲天数的自动归档。
- **purge**：归档到期（或超预算）后删除。之后该 thread 再有消息就开新会话，从聊天历史回填上下文。现在归档一直保留，只有手动删除会话。
- **共享缓存**：pnpm store、npm / cargo 缓存共享，`CARGO_TARGET_DIR` 按仓库共享。现在只共享规范 clone。
- **调试用原始记录**：运行时原始事件只在调试开关打开时写。现在不写。
- **日志按大小轮转**。现在不轮转。
- **换 runtime 交接**：换 runtime 就开新会话，并把旧会话的摘要交给新会话。现在 runtime 不能换。
- **选择顺序**：首条消息里的显式指定 > 频道默认 > 用户默认 > 全局默认。现在 Slack 只用连接绑定的设置，网页对话由发起人选。

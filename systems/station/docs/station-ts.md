# TS station 的结构

station 全部逻辑是 TypeScript。原生部分的约定见 [station-ts-native.md](station-ts-native.md)。

## 进程结构

```
launchd / 桌面 app
  └─ stillfail-station        原生启动器（Rust，预编译）：pid 不变，持有锁、端口、信号
       └─ node station.js      全部逻辑（TS 打包成一个文件，带自己的 Node）
            ├─ mesh.node        iroh 插件（Rust，预编译）：endpoint、连接、流
            └─ worker 线程       SQLite 读
  stillfail-runner × N          每个 agent 进程一个看守（Rust，预编译）：
       └─ claude / codex       持有 agent 的 stdin/stdout，station 重启后重新接上
```

- **启动器**：安装器和桌面 app 认的是「`station.json` 里 pid 不变、startedAt 变了 = 交接成功」、SIGUSR2/SIGUSR1/SIGHUP、退出码 3。启动器 pid 不变。收到 SIGUSR2 就起新的 Node，等它准备好再让旧的退出。它还持有 `run/station.lock` 和 `--with-parent` 的父进程检查。
- **runner**：agent 进程挂在 runner 下面。station 重启或崩溃都不影响正在跑的轮次。新 station 起来后按 `run/runners/<id>.sock` 重新接上，从 runner 的缓冲里接着读。

## 写法：Effect

- 异步和编排一律用 Effect 4（`effect` 包）：服务是 `Context.Service`，各部分是 `Layer`，在组合根（`src/main.ts`）拼起来。长任务是 fiber，挂在所属部分的 scope 里（`Effect.forkScoped`、`FiberSet`），部分停了它们一起停。资源用 `acquireRelease` 保证释放。退避和定时用 `Schedule`，推送用 `PubSub`/`Stream`，计时相关的规则用 `TestClock` 测。
- 纯计算（读视图的拼装、格式化、协议解析）保持普通函数，不进 Effect。热路径同理。
- 回调式的 API（ws、子进程、原生插件的事件）用 `Effect.callback` 包一层，取消时要能清理。
- 不用全局状态。需要什么，在服务里声明依赖。
- 时间：station 自己的时间一律走 Effect 的 `Clock`。Effect 代码用 `Clock.currentTimeMillis`、`Effect.sleep`。类（服务持有的 Hub、Accounts、Store、Events……）构造时拿一个 `clock`（测试给 `TestClock`），用 `src/ops/fibers.ts` 的 `Fibers` 取 now、排定时、跑后台工作，`close` 时一起停。和别的程序共用的时间（文件的 mtime、登录和 credential 的到期、锁的心跳、给子进程/套接字/对端的期限）用 `wall`。`wall` 是 station 里唯一直接用 Node 定时器和 `Date.now` 的地方。别处不要写 `Date.now`、`new Date()`、`setTimeout`、`setInterval`。

## 模块划分（Node 进程内）

组合根（`src/main.ts`、`src/services.ts`）把各部分作为参数传进去，没有全局注册表。

| 目录 | 职责 |
|---|---|
| `store` | SQLite（WAL）。一个写连接在主线程 |
| `read` | 读模型（侧栏、会话、概览等），在 worker 线程里用只读连接查 |
| `api` | admin API：路由、幂等、语言、事件流（`GET /events`） |
| `cloud` | 登记、presence、签名、通知上报 |
| `mesh` | iroh 插件之上：成员 credential、请求流、预览、adb 隧道、站间 peer、经 Salix 的中继 |
| `sessions` | 每个会话一个 actor：轮次、送达、等待、催办、限额切换、认证重试、归档 |
| `agents` | claude、codex 驱动（命令行、环境、输出解析、失败分类）、runner 接入 |
| `tools` | MCP 服务（HTTP，Bearer 令牌）和全部工具。工具的副作用经会话队列 |
| `slack` | Slack HTTP 客户端、Socket Mode、应用和配置令牌、名字缓存 |
| `accounts` | 凭据（文件/钥匙串）、OAuth 续期、检查、额度、登录 |
| `jobs` | 后台任务、服务、预览、站间任务 |
| `tasks` | Task（跨 station 的对话） |
| `connector` | 与 Salix 的连接（见 [../README.md](../README.md)） |
| `updates` | 运行时安装和 station 自更新 |
| `ops` | 配置、`run/*` 文件、端口、日志、i18n、遥测、时间（`fibers.ts`） |

库和归档文件见 [station-storage.md](station-storage.md)。

## 推送优先（原则）

能推送的就不让客户端请求。station 知道什么变了，就推给关心的人。客户端只在第一次需要、或者要做写操作时发请求。

- 所有写都经过 store 的写入口，写完发变更事件。读模型按变了的行推。
- 内部也一样：文件用 watch，子进程用退出事件，站间用推送。只有对外部系统（Slack、模型额度、更新源）才保留必要的定时。
- `GET /events`（SSE）的事件名和数据形状保持不变，每个事件另带 `id:` 行（序号）。老客户端忽略它。

## agent 运行

轮次规则见 [design.md](design.md) 第 7 节。驱动的命令行、环境变量和 MCP 配置在 `src/agents/`。

## 兼容约束清单

安装器、桌面 app、客户端和 cloud 依赖下面这些。改动只能向后兼容地追加。

- 命令行：`run --app --port --data --with-parent --handoff`、`enroll`、`status`、`id`、`handoff-version`、`channel`。退出码 3、2。`bin/stillfail` 的用法。
- 信号与文件：SIGTERM/USR1/USR2/HUP。`run/station.json`（单行，安装器用 sed 读）、`presence.json`、`ports.json`、`drained`、`handoff-failed`、`channel-ask/answer`、`update.*`。
- 数据目录：`mesh/secret.key`、`mesh/cloud.json`（字段和权限）、`config.json`（保留未知字段，0600）、`stillfail.db`、`slack-names.json`、`sessions/`、`jobs/`、`thumbs/`、`uploads/`、`archive/`、`remote/`。
- `stillfail.db` 的 `user_version` 是 12。station 拒绝打开别的版本。
- mesh：ALPN（`stillfail/admin/1`，含旧名 `ember/admin/1`）、首个流的 credential/续期、请求头行格式、关闭码、mDNS 两个名字、DHT、keeper、peer 协议。
- cloud：still.fail cloud 的 `/v1/stations/enroll|connect|notify`、`/v1/feedback`、`/v1/feedback/fixed`、`/v1/telemetry/traces`，Comma 控制面的 `/v1/comma/stations/enroll|connect|notify`，以及它们的签名和头。
- admin API：全部路由与字段（含给老客户端留的 `decision`、`declared` 旧词、`footprint`、`follows`）、幂等、语言头。
- MCP：全部工具名和参数、旧写法。

## 已定

1. 重启不断轮次：做启动器 + runner。
2. 随 station 发固定版本的 Node。
3. 权限：凭 credential 进来的成员按 credential 里的角色授权。`viewer` 只能读（和改自己的标记），部分管理操作（如共享账号）只限 owner / admin（`src/mesh/credential.ts`、`src/api/`）。

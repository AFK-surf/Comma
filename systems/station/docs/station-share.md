# Station 之间分享 Profile 和 skill

一台 station 可以把自己的 Profile 和 skill 分享给同一 workspace 里的其他 station。其他 station 直接用，不用再配、不用再登录。代码在 `station/src/share/index.ts`。

## 规则

- 分享是一个开关。每个 Profile、每个 skill 默认只在自己那台用。打开后默认所有 station 都能用，也可以只给几台（`allow`，null 表示整个 workspace）。
- 只有 workspace 的 owner 和 admin 能分享、改可用的 station、换 host。
- 数据只在 station 之间走（站间传输，iroh 端到端加密）。cloud 不记分享，也不碰 key 和 token。cloud 只给出 workspace 里有哪些 station。
- 不做：cloud 存配置、多个 workspace 之间共享、自动换 host、Slack bot 分享。

## 概念

- **分享项**：一样分享出来的东西，有 id（`sh-<hex>`）、种类、名字和 `allow`。
- **host**：拿着正本的那台 station。
- **使用方**：用它的其他 station。

| 种类 | 内容 | 使用方怎么用 | host 不在线时 |
|---|---|---|---|
| 订阅 Profile | Claude / Codex 订阅登录 | 每次启动进程时向 host 借短期 access token | 借不到，开不了新进程 |
| key Profile | API key 类 profile | profile 和 key 存一份在本地 `config.json` | 照常用最后一次拿到的 |
| skill | `agent/skills/` 里的一个 skill（不含 `MEMORY.md`） | 本地存一份，agent 可读可写，修改发给 host | 照常读写 |

**订阅只能由 host 刷新。** refresh token 刷一次就换。两台各刷一次会互相登出。所以只有 host 拿着登录，使用方只借 access token。

## 谁记什么

- **host**：分享了什么、谁能用、告诉过谁、告诉的是第几版（state.json `hosted[id].told`）。分享、修改、不再给某台、搬走时，host 直接告诉每台能用的 station（`share.changed`）。没联系上的，过一阵再告诉。
- **使用方**：每个副本从哪台来、第几版（profile 的 `share.host`，state.json `borrowed[id].host`）。每次启动问一次 host 现在是第几版（`share.version`）。对方说搬走了，就转去问新的 host。
- 借 token 或问状态失败时，使用方记下 host 联系不上（overview 的 `share.reachable`）。

## 站间方法

走 `stillfail/station/1`（`jobs/remote.ts` 的 `handle` 把 `share.*` 交给 `share/index.ts`）。跟 `session.message` 一样，只要求对方是同 workspace 的 station，不需要 `remoteJobs.allow`。host 再检查对方在 `allow` 里，或 `allow` 为 null。

| 方法 | 谁问谁 | 做什么 |
|---|---|---|
| `share.changed {id, version \| gone \| host}` | host → 使用方 | 内容变了、不再给这台了、搬到哪台了 |
| `share.version {id}` | 使用方 → host | 现在是第几版，或 `{moved}` |
| `share.get {id}` | 使用方 → host | 拿 profile（有 key 时带 key，不带登录）或 skill 的文件 |
| `share.lend {id}` | 使用方 → host | 借订阅的 access token |
| `share.status {id}` | 使用方 → host | 订阅的检查结果和额度 |
| `share.put {id, base, files}` | 使用方 → host | 写 skill。`base` 不是最新版时按冲突处理 |
| `share.take {id, profile, credentials, allow, version}` | 原 host → 新 host | 换 host：把 profile 和登录交过去 |

## 管理接口

- `POST /profiles/:id/share {on, allow}`：分享或停止分享一个 Profile，或改 `allow`。
- `POST /skills/:name/share {on, allow}`：同上，对象是 skill。
- `POST /profiles/:id/move {station}`：把分享的 Profile 换到另一台 station。

## 订阅

- Claude Code：跟 `machine` profile 一样，用 `CLAUDE_CODE_OAUTH_TOKEN` 把借来的 token 交给进程。进程自己不刷新。
- Codex：使用方把借来的 token 写进 profile home 的 `auth.json`。Codex 一直用到过期，不自己刷新。快过期时，没有会话在跑的话，使用方重启 app-server 并重新借。host 只在自己没有 Codex 进程用这个登录时才替它续期，因为续期会换掉 refresh token。
- 配额和检查：使用方不直接调 provider，而是问 host（`share.status`）。

## 换 host

只能由原 host 发起，原 host 和新 host 都要在线。只有 Profile 能换 host，本机登录（`machine` profile）不能换。

1. 原 host 停止借出。
2. 原 host 用 `share.take` 把 profile、key 和登录文件交给新 host。新 host 写好本地文件，回答收到。失败时原 host 恢复借出，什么都不改。
3. 原 host 删掉本地的登录文件，把本地这条 profile 改成从新 host 借用的副本（id 不变）。
4. 原 host 告诉它告诉过的 station：搬到新 host 了。

这样同一时刻只有一台拿着 refresh token。host 那台机器没了，订阅就要重新登录。

## 使用方的 `config.json`

分享来的 Profile 写成一条带 `share` 字段的 profile。host 一侧是 `share: {id, allow}`，使用方是 `share: {id, borrowed: true, host}`。这个字段只由 `share/index.ts` 写和删。

- key 类：`key` 照常写进去（权限 600）。
- 订阅：home 里不放登录文件，免得 Claude Code / Codex 自己去刷新。
- 停止分享，或这台不在 `allow` 里了：使用方删掉这条。正在用它的 chat 按「profile 不可用」处理。

分享的 skill 记在 host 的 `config.json` 的 `sharedSkills: {name: {id, allow}}`。

## skill

- 使用方把 skill 存在 `<data>/share/<id>/`，链接进 agent home 的 `skills/`。本台有同名 skill 时，本台的优先，分享来的不链接。
- 使用方的 station 盯着这些文件。agent 改了，就用 `share.put` 发给 host。host 按顺序接收，加版本号，告诉其他使用方。
- 冲突：在旧版本上的修改，host 不覆盖，而是存成 `SKILL.conflict-<station>.md` 放在 skill 旁边。agent 看到它就合并进 `SKILL.md`（见 `agents/migrations.ts`）。
- 内置 skills（`stillfail-*`）由各台自己写，不参与分享。

## 兼容

新字段都是可选的（`config.json` 和 overview 的 `share`）。旧 station 和旧客户端都当没有。新客户端配旧 station 时显示「只在这台」，不能分享。

# still.fail cloud：账号、workspace 与 station

still.fail 的执行节点叫 **station**。一个人可以登录多个 Google 账号。一个账号可以建多个 **workspace**，也可以被邀请进别人的 workspace。一个 workspace 里可以有多台 station。客户端通过 iroh 连到 station，不经过任何业务服务器。

```
浏览器 ──(iroh，只走 relay)───────────────┐
客户端（桌面、Android）──(iroh：局域网直连、   ├─ station
                        relay 或 n0 的 relay)┘
            │ 登录、workspace、成员凭证（30 天，缓存在设备上）
            ▼
Cloudflare：still.fail cloud（stillfail-cloud API、stillfail-relay、stillfail-web / stillfail-admin / stillfail-preview 静态站点，官网 still-fail-site）
```

设备直接连 station，station 在不在线也由设备自己连出来判断。still.fail cloud 只管"人"：账号、workspace、成员，以及签发成员凭证。登录过一次之后，局域网里没有 still.fail cloud 也能用。

## 什么存在哪

- **控制面**：账号、workspace、成员与角色、邀请、station 名单、成员凭证的签发与吊销。
- **station**：连接、运行时账号、会话、对话、agent 的记忆和 skills。station 只用邮箱记"谁"（连接的添加人、对话的发送人、会话的发起人）。名字和头像由客户端从控制面的成员名单里取。

## 对象

| 对象 | 是什么 | 标识 |
|---|---|---|
| 账号 | 一个 Google 身份 | Google `sub` |
| 客户端 | 一个浏览器或 App 安装，持有一把 iroh 设备密钥，可以同时登录多个账号 | 设备公钥 |
| workspace | 一组人和一组 station。账号在其中的角色是 owner / admin / member | ULID |
| station | 一台 still.fail 节点，属于一个 workspace | station 的 iroh 公钥 |

- 一个账号可以创建多个 workspace（成为 owner），也可以接受邀请加入别人的。
- owner / admin 可以邀请成员、登记 station、移除成员和 station。owner 还可以改角色、删除 workspace。workspace 至少保留一个 owner。
- 邀请按邮箱发出。对方用这个邮箱登录 still.fail，就会在 workspace 切换菜单里看到邀请。
- 没有 workspace 的账号登录后会自动得到一个自己的 workspace。
- 客户端里每个已登录的账号各自持有会话（access / refresh token），互不影响。

## 登录

Google OAuth（`openid email profile`）。access token 5 分钟。refresh token 轮换，闲置 7 天或最长 30 天过期。重放旧 refresh token 会吊销整个会话。

网页版在同一域名下走授权码 + PKCE：页面生成 verifier，跳到 `/v1/auth/google/start`，回到 `/auth/callback?code=…`，再用 verifier 换 token。回调地址只允许本域的 `/auth/callback`（网页）和 `127.0.0.1` 回环地址（命令行）。token 不出现在 URL 里。

## station 登记

1. admin 在 workspace 里点「添加 station」，得到一条一次性、1 小时有效的登记命令。
2. 在要当 station 的机器上运行它。station 用自己的 iroh 密钥签名，证明持有这把密钥。控制面把这个公钥记入 workspace。
3. station 保存控制面的签名公钥（Ed25519）。之后校验成员凭证不需要访问控制面。

## 连接 station 与成员凭证

设备连 station 靠一张 **成员凭证**（`POST /v1/workspaces/:ws/credential {device}`）。它是 still.fail cloud 用 Ed25519 签的 JWT（`typ: stillfail-member+jwt`，station 也认旧的 `ember-member+jwt`），写明账号、邮箱、名字、workspace、角色、设备公钥和登录会话（`sid`），30 天有效。

- station 离线校验：签名来自登记时保存的公钥，workspace 是自己的，设备公钥等于这条 iroh 连接对端的公钥，没过期，没被吊销。同一张凭证进这个 workspace 的每一台 station。
- 设备把凭证存在本地（`credential/<账号>/<workspace>`，记着签给哪台设备）。一天内直接用，过了一天向 still.fail cloud 换新的。still.fail cloud 连不上时，旧的一直用到过期。station 拒绝时（被吊销、过期）立刻换新的。退出账号时一并删掉。
- **吊销**：成员被移除或改角色（`sub`）、登录会话被注销（`sid`）时，still.fail cloud 通过 station 的控制通道推一条吊销（`revoke` 帧。`state` 帧里也带着最近 31 天的吊销）。station 拒绝签发时间不晚于吊销时间的凭证，并断开已连着的连接。station 不在线时错过的吊销，下次连上 still.fail cloud 时从 `state` 里补上。
- still.fail cloud 下线时，已登录过的设备凭缓存的凭证照常连 station（局域网直连或 relay）。只有新登录、新成员需要它。

连接用 ALPN `stillfail/admin/1`，也接受旧版 `ember/admin/1`。第一个流交换凭证。之后每个流承载一个管理 API 请求：请求头是一行 JSON（method、path、headers），随后是请求体。回应头是一行 JSON（status、headers），随后是回应体。流结束即回应结束（SSE 就是一直不结束的回应）。

station 端在 `station/src/mesh/serve.ts`（iroh 在 Node 插件 `station/native/mesh` 里）。它把请求交给 station 的管理 API，带上已验证的用户身份。

## Control planes (still.fail cloud, Comma)

A station and the client core talk to "the control plane" through one interface. The same station and core can be enrolled in still.fail cloud or, experimentally, in Comma (AFK-surf/Cue). still.fail cloud is the default.

- **Station** (`station/src/cloud/plane.ts`): `cloud/provider.ts` holds what differs per provider (paths, signing tags, header names, credential `iss`/`typ`). `cloud.json` has `provider` (absent means `"stillfail"`). The station reads it at each use, so no restart is needed. Feedback (`/v1/feedback`) and session page links are still.fail only.
- **Enrolling in Comma**: `stillfail station enroll <origin> <token> --provider comma` posts to `/v1/comma/stations/enroll` (`comma-station-enroll-v1` proof). Presence is `/v1/comma/stations/connect` (`comma-station-connect-v1`, `x-stillfail-*` headers only); its `state` frames also carry `gateway_keys`, kept in cloud.json. On it the station sends `{type: "reach", home_relay, addrs}` (its endpoint's home relay and direct addresses, `mesh/reach.ts`) at connect and whenever they change; Comma gives them, while the station is online, to its peers in `peers` and to members in the stations list, as hints for dialing: a station dials a peer there besides the relays and Salix (`mesh/peer.ts` `peerAddr`), the Comma client core a station (`clients/packages/core/src/hosts/mesh.ts`); each is still known by its key, and one that gave none is found by its id. Notices go to `/v1/comma/stations/notify` (`comma-station-notify-v1`). Comma takes no traces yet. Releases and the installer are under `<origin>/stations` (`releases/station.json`, `install.sh`); `stillfail update` follows cloud.json's provider.
- **Credentials**: Comma's are `typ: comma-member+jwt`, `iss: comma`, checked like still.fail's. Role `viewer` is read-only on every station: reads (GET/HEAD) and the viewer's own read/dismissed marks only. Other requests and phone sharing answer 403. Every other member may start a Task (a chat on the station's page, `POST /sessions`) and write in one on any station of the workspace, a Cloud VM's included; no station keeps it to its owner (decided by 左子健, 2026-10-19).
- **Device tools** (`station/src/mesh/tools.ts`, `station/src/device/tools.ts`) reach the station two ways, with the same requests and answers.
  - Comma pushes them on the presence socket by default: `{type: "tool", id, request}`, answered on the socket with `{type: "tool_result", id, response}`. Being on the socket the station signed into is the admission.
  - Or a gateway calls `comma/tools/1`, an iroh ALPN on the station's endpoint. Only ids in `gateway_keys` are admitted (rechecked per request). One request per stream: a JSON line `{op, id, context, args}`, answered by `{ok, result}` or `{ok: false, error: {code, message}}`.
  - Either way the station takes only requests whose `context.workspace` is its own.
  - The computer's one access value decides what runs (`device/access.ts`): `tools.access` in config.json (`off` | `read` | `full`, default `off`). The station's device connection to Salix follows the same value (see below). Any member can read it with `GET /tools/access`. `PUT /tools/access` is for the computer's owner (`tools.owner`, the user its device connection belongs to); a station without a device connection (a Cloud VM, a still.fail cloud station) takes it from the workspace's owners and admins. `read` allows reads of files, processes, runtimes and chat states (the op list is `READ_OPS` in `device/tools.ts`). `full` allows all ops, including `exec`, `fs.write` and `process.*`, which run as the station's user and can reach what that user can.
  - The device connection: `full` allows operations; `read` and `off` make it read-only (`local_file_read`), and `off` also refuses its file reads. Its metadata says the value (`capabilities.access`). Salix's `device_access` sets the value: `{access}` (off | read | full), or the 2-level `{allow_operations}` of servers from before (true is `full`; false is `read`, and an `off` computer stays `off`). A desktop app's connection file whose `scope` alone changed sets it the same 2-level way (`""` is true). Once the computer has a value (`tools.computer: true`), a connection's own scope says nothing.
  - A station from before has only the device tools' value. The first device connection that starts gives the computer its value: the access that connection was configured with (the desktop app's choice, or a standalone device's `device-access.json`), `read` or `full`, whatever `tools.access` said before.
  - At every level, file ops and working directories refuse the station's data directory (its key, cloud.json, the profiles' homes), its config and the machine's Claude/Codex logins, also through symlinks.
  - `session.start`/`session.say` create and drive normal station chats through the admin API as the requester (`requester_email`).
- **A workspace told by a new id**: the control plane may rename a workspace. The enroll answer and every `state` frame carry `workspace` (the id now) and `workspace_was` (the earlier ids, oldest first, absent means none). `cloud.json` keeps both (`cloud/state.ts`).
  - A new `workspace` is a rename when its `workspace_was` leads back to the same first id. Otherwise it is another workspace. The first id (`workspaceKey`: `workspace_was[0]`, else `workspace`) never changes.
  - What a station keeps and what stations say to each other use the first id: remote jobs, their ids and session directories, the `outgoing` and `used` records, and the `workspace` of a peer request. A rename changes none of them, so running jobs go on.
  - What comes from outside may name any id (`workspaceIds`): a member credential's `ws`, a peer request's `workspace`, a device tool's `context.workspace`. A credential from before the rename still works.
  - A station that does not know `workspace_was` takes a new `workspace` as another workspace: it stops the remote jobs it hosts and refuses its peers. So the control plane renames a workspace only when every station of it reports a version that knows it (the `version` each sends at connect).

The wire contract shared with Comma is "Station ↔ Comma control-plane contract (v1)".

## 网页版

从 still.fail cloud 打开，先登录。每台 station 都必须加入一个 workspace 才干活。station 不提供页面和本机管理 API。它的本机端口（默认 4760）只把旧的 `/admin` 链接 302 到 still.fail cloud。

一个 workspace 的页面同时连着它所有在线的 station。所有请求都经浏览器里的 iroh（wasm，只能走 relay）送到各自的 station。

连接和对话记录添加它的人（still.fail cloud 账号的邮箱）。Slack 发起的会话记录发起的 Slack 用户，用 Slack 资料里的邮箱和 still.fail cloud 账号对应。

浏览器的设备密钥存在 IndexedDB。清掉站点数据等于换了一个新客户端，重新申请凭证即可，不需要任何人重新审批。

## relay 与发现

Cloudflare Container 里跑官方 `iroh-relay`，前面由 Worker（`stillfail-relay`，`cloud/src/relay-worker.ts`）转发 WebSocket。总量限制（RelayBudget）只在建连接时检查：当天流量超额就重启容器、拒绝新连接。单个客户端的速率由 iroh-relay 自己限。relay 是单独的 Worker，部署 API 不会断开 relay 连接。

station 平时只以 still.fail 的 relay 为家（浏览器只认它）。still.fail 的 relay 都连不上时，station 才临时加入 iroh 官方的公共 relay，恢复后撤掉（`station/src/mesh/relays.ts`）。

station 在哪、怎么连，设备自己找，不经过 still.fail cloud：

- **局域网**：mDNS（服务名见 `station/native/mesh/src/lib.rs` 的 `MDNS_SERVICE`）。只有 station 广播，设备只查询。
- station 的 QUIC 端口默认每次启动随机。防火墙要放行局域网直连时，在 `config.json` 设 `mesh.port` 固定它，见 [operations.md](operations.md#configjson)。
- **公网**：station 把自己所在的 relay 发布到 Mainline DHT，设备查得到它换过的 relay。
- 浏览器（wasm）只能走 relay：still.fail 的，或下面说的 workspace 自己的。

**workspace 自己的 relay**：owner 和 admin 可以给 workspace 加自己部署的 iroh-relay（`PUT /v1/workspaces/:id/relays {relays: [url]}`，要 https）。云不检查它们能不能连上。它们只给这个 workspace 用：
- station：state 帧的 `relay_urls` 在 still.fail 的 relay 后面接上它们（`relay_url` 不变）。station 按远近选家。
- 设备：`/v1/me` 和 `/v1/workspaces/:id` 的 workspace 带 `relays`。设备连这个 workspace 的 station 时，拨号和测速才加上它们。连不上的不会被选。
- 网页版要求 relay 用公开签发的证书（如 Let's Encrypt，iroh-relay 自带 ACME）。
- 不做访问控制：relay 只转发端到端加密的 QUIC，看不到内容。谁能用它由部署者在 iroh-relay 里配。

iroh 相关库的修补在 `station/vendor/`，见 [vendor/README.md](../vendor/README.md)。

## 推送通知

设备（浏览器的 Web Push 订阅、安卓的 FCM token）登记在登录的账号和会话下（`POST/DELETE /v1/push`，会话退出时一起删掉）。station 把自己 chat 的通知签名后发到 `POST /v1/stations/notify`。still.fail cloud 只推给通知里点名、并且是这台 station 所在 workspace 成员的人。接口、签名和推送内容见 [notifications.md](notifications.md)。

API Worker 的密钥都可以不设。没有 VAPID 就没有 Web Push（`/v1/push/key` 回 404）。没有服务账号就不推安卓。

- `VAPID_PUBLIC_KEY` / `VAPID_PRIVATE_KEY` / `VAPID_SUBJECT`：`deploy.py` 从部署目录的 `vapid.json`（`{public, private, subject}`）读。只生成一次，之后别换。换了，浏览器的订阅全部作废：

  ```sh
  node -e 'const j=require("crypto").generateKeyPairSync("ec",{namedCurve:"P-256"}).privateKey.export({format:"jwk"});console.log(JSON.stringify({public:Buffer.concat([Buffer.from([4]),Buffer.from(j.x,"base64url"),Buffer.from(j.y,"base64url")]).toString("base64url"),private:j.d,subject:"mailto:<运维邮箱>"}))' > "$STILLFAIL_DEPLOY_DIR/vapid.json"
  ```

- `FCM_SERVICE_ACCOUNT`：Firebase 项目的服务账号 JSON（Firebase 控制台 → 项目设置 → 服务账号 → 生成新的私钥），原样放在部署目录的 `fcm-service-account.json`。

## 部署

still.fail cloud 由以下 Worker 组成（`cloud/wrangler*.jsonc`）：

| Worker | 是什么 | 在哪 |
|---|---|---|
| `stillfail-cloud` | API（`cloud/src/index.ts`） | `app.still.fail/v1/*`、`admin.still.fail/v1/*`、`/healthz`、`/install.sh`、`/releases/*`、`/.well-known/*` |
| `stillfail-relay` | relay 及其容器 | `app.still.fail/relay`、`/ping`、`/generate_204`、`/v1/admin/relay/*` |
| `stillfail-web` | 网页版，纯静态 | `app.still.fail`（Custom Domain） |
| `stillfail-admin` | 管理后台，纯静态 | `admin.still.fail`（Custom Domain） |
| `stillfail-preview` | 预览页，纯静态 | `preview.still.fail`（Custom Domain） |
| `still-fail-site` | 官网，纯静态（`pnpm build:site`，`python3 cloud/deploy.py site`） | `still.fail`（Custom Domain） |

同一个域名上，路由优先于 Custom Domain，所以 API 和 relay 的路径到各自的 Worker，其余都是静态站点。

`cloud/deploy.py [api relay web admin preview]` 逐个部署，不写就是全部。它在维护者的部署机上运行，需要 `wrangler login` 和 docker。只部署改动涉及的 Worker。只有部署 relay 才会断开 relay 连接。

- 线上地址 `https://app.still.fail`。
- 部署目录默认是 `~/stillfail-deploy`（`STILLFAIL_DEPLOY_DIR` 可覆盖。只有旧 `~/ember-deploy` 存在时仍沿用它）。
- Google 登录用单独的 OAuth 客户端，客户端 JSON 在部署目录的 `google-oauth.json`。
- 密钥在 `keys.json`。丢了会让所有人重新登录，所有 station 需要重新加入。
- PostHog 的项目 key 在 `posthog.json`，构建网页版时带进去。
- Axiom 的写入令牌和数据集在 `axiom.json`（`{dataset, token}`），部署时写成 API Worker 的 `AXIOM_TOKEN` / `AXIOM_DATASET`。客户端和 station 的 trace 发到 `POST /v1/telemetry/traces`，由 Worker 转给 Axiom，令牌不出 Worker。见 [telemetry.md](telemetry.md)。

本地联调（不需要 Cloudflare）：`cloud/test/dev.ts` 在 miniflare 里按线上的路由起全部 Worker（Google 用模拟），配合 `iroh-relay --dev`。

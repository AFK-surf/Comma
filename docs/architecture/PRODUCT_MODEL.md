# Comma 核心产品概念模型

> TLA+ coverage update (2026-09-08): feature-level models referenced below
> have been retired from TLC/CI under the [system-core policy](../../tla/README.md).
> Their model links, commands and passing-run claims are historical, not current
> verification. Product contracts and implementation regression tests are unchanged.


本文件是架构图的语义入口。阅读顺序固定为：先理解产品概念和关系，再看概念落到哪些代码、Actor 和存储。模块名、进程名和数据库表不能反过来定义产品概念。

这不是全量功能清单。它先覆盖新开发人员理解 Chat、Task、Single Session、Compute 和 Comma Center Recommendation 所需的核心主线；Billing、Meeting、Schedule、OAuth 和其它设备管理能力在后续专题中展开。

The broader [domain concept inventory](DOMAIN_CONCEPTS.md) records current concepts, owners, aliases, and entity reuse rules.

## 核心概念

| 概念                | 面向用户/产品的定义                                    | 关键关系                                                                                        |
| ------------------- | ------------------------------------------------------ | ----------------------------------------------------------------------------------------------- |
| 用户                | 登录产品、获得授权并发起工作的人                       | 用户通过 Owner 或 Membership 获得范围访问权；用户不是 Agent，也不是 Runtime Session 的 Owner    |
| 账户与授权范围      | 决定用户能看见和管理什么                               | Comma 中是 Workspace；BFT 中是 Organization + Membership                                          |
| Agent 工作范围      | 一组 Agent、Conversation、能力和运行环境共同工作的范围 | Comma 中仍是 Workspace；BFT 中是 Agent Swarm；账户范围可以尚未创建任何 Agent 工作范围             |
| Router              | 配置后成为工作范围内唯一的当前协调 Agent               | 一般状态为 0..1；只有 chat-ready / active execution scope 才要求恰好一个 Router                 |
| Worker              | 完成具体任务的 Agent                                   | 每个范围可以有多个 Worker；同一 Worker 可以处理多个独立 Task                                    |
| Assistant Chat      | 用户与当前 Router 的长期可见对话                       | Comma: one fixed Router Conversation per current Group. BFT: one current Chat per User × Agent Swarm.                                               |
| Agent Task          | Router 或 Worker 委派的独立、可持久工作对象            | 对应一个 `agent_task` Conversation；当前 Router `im_api.internal.task.create` assigns one responsible Worker |
| Task lifecycle      | Task 对外可见的粗粒度生命周期                          | 只有 Conversation `status` 一份权威；Gate progress 不是第二套 Task 状态                         |
| Gate / Progress     | Gate 定义阶段；Progress 是 Gate 的一次具体 activation  | 每次 activation 只指向一个普通 Agent Participant；可分叉、汇合和有界循环                        |
| Human review        | 人类接受自己实际审阅过的 Task 结果                     | 自动化成功停在 `ready_for_review`；精确 version 验证后才能进入 `completed`                      |
| Conversation        | 用户和 Agent 可见的协作消息事实边界                    | `user_chat` 和 `agent_task` 是主要 kind；一个范围内可以有很多 Conversation                      |
| Message             | Conversation 中有序保存的可见事实                      | sender 是具体用户、Agent 或 Provider 身份                                                       |
| Participant         | Conversation 的接收目标                                | 决定消息通知谁；Participant 不是 Message sender 的同义词                                        |
| Runtime Session     | Agent 处理输入、执行模型和工具的上下文                 | Session 属于 Agent runtime；已配置 Router 是 1:1，Worker 是 0:N                                 |
| 工作结果 / Artifact | Task 或主动工作产生的可见结果                          | 由 Task 产生，可以继续被用户或 Agent 使用                                                       |
| Comma Center Recommendation | 当前 Workspace 成员的结构化 briefing 产品 projection | 不是 Conversation Message；prompt action 只填充 composer 草稿，用户手动发送才进入 Assistant Chat path |

概念的主干组织关系如下：

```text
用户
└─ 通过 Owner / Membership 进入账户与授权范围
   └─ 访问 0..N 个 Agent 工作范围
      ├─ 当前 Router [0..1；chat-ready 时为 1]
      │  └─ Canonical Runtime Session [已配置 Router 恰好 1]
      ├─ Worker [0..N]
      │  └─ Task Runtime Session [0..N]
      ├─ Assistant Chat [Comma: shared per Group; BFT: per User × Agent Swarm]
      ├─ Comma Center Recommendation [每个成员 0..1 current projection]
      └─ Agent Task [0..N]
         ├─ Task lifecycle [恰好 1；Conversation status]
         │  ├─ Gate [1..N，有界]
         │  ├─ Participant Binding [1..N，role → 普通 Agent Participant 的 participant_id]
         │  └─ Progress [0..N；active / blocked / completed，可并行]
         └─ 工作结果 / Artifact [0..N]

Assistant Chat / Agent Task
└─ Conversation [1]
   ├─ Message [0..N，有序；保存具体 sender]
   └─ Participant [0..N，保存接收目标]
      └─ 每个 Agent target = agent_id + 唯一明确的 session_id
```

对应的可视化是 `01 · 用户、范围与 Agent 团队`、`02 · Chat、Task 与 Conversation`、`03 · 产品概念在 Comma / BFT 中的命名` 和 `03B · Comma Center Recommendation 是产品 Projection`。

## Comma 与 BFT 的产品命名

| 稳定抽象            | Comma                                                | BridgeForTeams                             |
| ------------------- | -------------------------------------------------- | ------------------------------------------ |
| 产品用户            | Comma User                                           | BFT User                                   |
| 账户与授权范围      | Workspace，同时承担 Agent 工作范围                 | Organization，通过 Membership/RBAC 授权    |
| Agent 工作范围      | Workspace 对应的当前 Salix Group                   | Agent Swarm；当前代码历史名为 `Project`    |
| 当前 Assistant Chat | 当前 Group 共用一条固定 Router Conversation | 每个 User × Agent Swarm 一份 New Home Chat |
| Agent 团队          | 0..1 当前 Router + 默认/后续 Worker                | 0..1 当前 Router + 0..N Worker Agent       |

这里最容易误读的是 BFT `Project`：它在当前产品语言里是 Agent Swarm，不是通用项目管理对象。另一个差异是 Comma Workspace 同时承担“授权范围”和“Agent 工作范围”，BFT 则把两层拆成 Organization 与 Agent Swarm。

## Task delegation

A Task is an `agent_task` Conversation with one responsible Worker.
The Router creates it with `im_api.internal.task.create`, using `agent_id` and self-contained `content`.
The Worker publishes ordinary result Messages. The Router owns Conversation status changes.
The owning Router may complete a plain one-shot Task after verified delivery with no remaining work or human decision.
This path excludes recurring, product-assigned Triage and legacy Workflow Tasks.
Human acceptance remains a separate, version-checked operation. A completed status alone does not prove human acceptance.
Tasks retain their identity, history, source authority, and participant-owned Sessions.
See [Tasks](../salix/tasks-background-execution.md).

## Single Session 到底是什么

Single Session 的完整限定词是：

> 每个已配置的当前 Group Router Agent 只有一个 canonical Agent Runtime Session。

它不表示整个产品只有一个 Session，也不表示一个用户只有一个 Conversation。正确的 cardinality 是：

| 关系                                                               | Cardinality | 含义                                                                                                                         |
| ------------------------------------------------------------------ | ----------- | ---------------------------------------------------------------------------------------------------------------------------- |
| 账户与授权范围 → Agent 工作范围                                    | 0:N         | BFT Organization 可以尚未创建 Agent Swarm                                                                                    |
| Agent 工作范围 → 当前 Router                                       | 0..1        | 未配置/准备中的范围允许没有 Router；chat-ready 范围恰好 1 个                                                                 |
| 已配置的当前 Router → Router Runtime Session                       | 1:1         | `router_session_id` 持久化在 Router agent control record 上                                                                  |
| 带当前 Router Participant 的 Conversation → Router Runtime Session | N:1         | 多个用户 Chat、Task 通知和其它 Router 入口共享同一个长期执行上下文；没有 Router Participant 的 Conversation 不进入该 Session |
| Comma Group → 固定 Router Conversation                               | 0..1        | chat-ready Group 恰好一条；同 Group 用户复用该 Conversation，不再建立 Comma User×Group Chat                                   |
| Worker → Worker Runtime Session                                    | 0:N         | 目标 Worker 按 Task 使用新 Session；Worker 委派者可以复用 origin Session                                                     |

因此，User、Agent、Conversation 和 Session 的关系不是“都装进一个 Session”，而是：

1. Comma 用户在当前 Group 的固定 Router Conversation 中发送 Message；Message 仍记录具体用户 sender。BFT 自己的产品 Chat binding 不受此 Comma 基数影响。
2. Conversation 的 Router Participant 是接收目标。它保存 Router `agent_id` 和明确的 `session_id`。
3. Router Participant 的多个投递最终都进入该 Router control record 上的同一个 canonical `router_session_id`。
4. Router Runtime Session 保留跨 Conversation 的执行上下文，但每条输入仍携带来源 Conversation/Message identity。
5. Router Participant 私下订阅当前 Router Session，并把经过范围校验的 Activity 与可选 transient draft 作为 Participant realtime status 暴露；Comma 只按 Participant identity 订阅，不绑定 Session。draft 清除不表示 Message 完成。
6. 所有内部用户可见回复都由 Agent 显式调用 `im_api.internal.send_message`，再经 `ConversationServer -> ConversationActor` 追加 canonical Message。普通 assistant content 与 `end_turn` 只结算 Runtime，不自动写 Message。外部 Feishu/Slack 等 Provider operation 成功后写入对应外部 Channel，不追加产品 Conversation。Conversation read/list 不会从 Runtime transcript 懒投影可见消息。
7. Router 或 Worker 委派 Task 时创建独立 `agent_task` Conversation；普通 Task 的 assigned Worker 获得新 Session。
8. Router delegator 复用 canonical Router Session；Worker delegator 复用 `origin_session_id`。

`04 · 用户消息如何进入 Router Single Session` 展示 Router 主路径，`04B` 展示显式可见回复边界，`04C` 单独对照 Task 中 Router/Worker Participant 的 Session 规则。

### 控制面显式重新指定 Group Router

这里的重新指定是低频人工或控制面操作：Group 的 `router_agent_id` 从一个 Router Agent 明确改为另一个 Router Agent。它不是请求级负载均衡、Pod 重启，也不是自动故障转移。Single Session 仍是“每个 Router Agent 一份”，不是“每个 Group 永久一份”；重新指定前的 Router 与控制面当前 Router 各自保留不同的 canonical Session。

- Comma：产品 Chat binding、Conversation ID 和历史展示保持不变。`Comma.Conversations.send_message/5` 在已有 `user_chat` 的下一次发送前，请求 Salix 按当前 Group authority reconcile Router Participant；Conversation owner 停用重新指定前的 target，并激活控制面当前 Router target。并发重试继续使用同一个 serving Conversation 和同一个 client request identity。Group Router 缺失、无效或 Participant identity 不明确时，在 append 前 fail closed。
- BFT：保留同一 `UserAssistantChat` binding 行，但 `AssistantChats` 发现原 Conversation 的 required Router Participant 不再匹配后，会把它视为 stale、创建替代 Conversation，并更新 binding 的 `conversation_id`。

`04D · Comma：控制面显式重新指定 Group Router` 和 `04E · BFT：控制面显式重新指定 Group Router` 分别展示两条产品生命周期。两图都只描述明确的控制面操作，不表示 Router 会在普通请求之间自动切换。

Comma 的收敛触发点有意限定在下一次发送：ensure/list/detail 不做隐式 participant mutation。因而从控制面操作完成到下一次成功发送之间，依赖“控制面当前 Router Participant 已存在”的 activity events/SSE 会 fail closed；detail/history 仍可读。这个短窗口不表示自动恢复或后台切换，客户端在下一次发送完成后恢复正常 activity stream。

### 一个有意保留的例外

Router-bound Slack、Feishu、Telegram、WeChat、Signal 直接入站不创建 Conversation Message。它携带精确 Provider source identity，直接进入同一个 canonical Router Session；可见回复通过对应 Provider API 返回。Worker-bound Slack Task 仍使用 `agent_task` Conversation 和独立 Worker Session。

这个例外改变的是“是否先落 Conversation”，不改变“所有 Router 输入进入同一个 canonical Router Session”的不变量。

## “Session”同名概念消歧

| 名称                           | Owner / 用途                                     | 是否是 Single Session 所指对象             |
| ------------------------------ | ------------------------------------------------ | ------------------------------------------ |
| Comma/BFT Auth Session           | 产品身份、Cookie/Bearer、登录与撤销              | 否                                         |
| Electron Session / Lease       | Main 中的凭证 custody 和桌面并发隔离             | 否                                         |
| Salix Agent Runtime Session    | Agent 的模型、Tool、Wait、Runtime state 上下文   | 是                                         |
| `work_session` Conversation    | BFT 展示一次工作日志的 Conversation kind         | 否                                         |
| Provider native thread/session | Connector 本机用于 Codex/Pi/Kimi 恢复的 identity | 否；它只能映射到一个 Salix Runtime Session |

这也是架构图把 `16 · Electron 已认证产品命令` 中的 Session 明确写成 Auth Session 的原因。

## Compute、External Worker 与 Service Route

Comma Workspace 与 BFT Agent Swarm（代码历史名 `Project`）是 Compute Environment 的唯一产品 owner。产品层保存 ACL、intent 和有界 projection；普通成员不能选择 Cloudflare 或 Agent VMM。共享 Salix Compute SSOT 持有 `ComputePool → ProviderBinding/Allocation → Environment → Workload → RuntimeInstance`，并以 exact revision、generation、connection epoch 与 current authority 拒绝迟到结果。

External Worker Binding 恰好有两种稳定形态：`connected_runtime(device_runtime_id)` 与 `compute_workload(workload_id, runtime_spec)`。Provider-native endpoint、registration 或 container 不进入 Agent or Message。活跃 External Session 保持原 stable target；新的 RuntimeInstance connection epoch 只有完成 durable catch-up 后才能签发 exact session/runtime/epoch capability。

Service Route 是 Workload 间的 capability-gated authority，不是某个 Provider 的 service 记录。prepare/activate/renew/drain/revoke/expiry 由同一 provider-neutral ledger 表达；每次访问都重查 source/destination Workload generation、Environment authority、exact route capability 与 expiry。Unsupported hosting capability fail closed。

Comma Desktop 的“将此 Mac 作为计算节点”是显式 opt-in 的 Compute capacity。当前 Electron Main 管理已 provisioned 节点的 status/configure/restart/repair/drain/remove，Renderer 只消费生成式 native capability；configure 仍要求底层 enrollment 已经 provisioned，不能把本地安装成功冒充 Salix ready。UI 分别展示 connection、runtime readiness、work activity、admission/drain 与 installation health，不用单个模糊的“在线”状态代替。

`07D · Compute、External Worker 与 Service Route` 展示产品 owner、共享 SSOT、Provider contract、runtime binding、ServiceRoute 和桌面 Compute Node 的落点。协议语义与迁移边界以 [`compute-behavior-baseline.md`](../salix/compute-behavior-baseline.md)、[`runtime-agent.md`](../salix/runtime-agent.md) 和 [`compute-migration-runbook.md`](../salix/compute-migration-runbook.md) 为准。

## Comma Center Recommendation

Comma Center Recommendation 是 `Member × Workspace` 的产品 projection，不是 Salix Conversation Message，也不引入第二条 Conversation mutation path。`Comma.Recommendations` 及其 `RecommendationProfile/RecommendationRun` PostgreSQL 记录是设置、source revision、generation、active run、current snapshot 和 freshness 的唯一产品 SSOT。`send_to_comma` 与 `open_task_form` action 在客户端统一为填充 composer 草稿——用户在输入框里手动发送后才进入既有 Comma Assistant Chat path；`open_url` 也只能使用版本化 contract 注册的字段。

刷新请求先在 profile 行锁下分配单调 generation，并固定当时的 `source_revision`。Comma Web 最多收集 12 个已选择的 exact source，限制为 4 路并发、每 source 10 秒和整轮 30 秒。GitHub、Linear、Notion 使用 Salix Group OAuth binding ID，凭证由 Salix 解析并刷新后直接请求 provider；其他 source 使用 Composio connected-account ID，凭证由 Composio 管理：generic 模式执行固定只读 recipe；member 模式经绑定该账号的代理会话直接调用 provider 官方 API，不依赖 Composio 工具。原生应用的 enabled 选择属于 Member×Workspace Profile，跨连接缺失保留；缺失的连接不参与采集。Server 在调用模型前持久化 bounded source evidence marker。member 模式由成员的 Router 以自身模板发起一次有界、无工具的模型请求，完成选择、排序和建议命名；运维配置的 Routine 模板只替换模型。服务端逐行校验，无效行单独丢弃；响应不是选择结果或返回行全部无效时本轮失败，并保留上一份有效快照。generic 模式仍为单次 Worker 模型请求。两者均不运行隐藏会话 Agent，旧 Agent capability 入口拒绝调用。发布校验 run、generation 和 source revision；新 generation 或 source 变更会使迟到结果 `superseded`。

客户端 contract 只注册 `text-list@1` 和 `media-list@1`。未知或 malformed generated card 不作为当前模板执行。Electron 的可选图片增强经生成式 `recommendationMedia.load` 进入 Main：只接受 credential-free HTTPS，执行 public-DNS pin/redirect 重验、总 deadline、图片尺寸与格式检查，并把解码重编码后的 bounded PNG 返回 Renderer。Web 不做无法完整验证 DNS 的远程图片 fallback，只保留相同 text/action。媒体失败不会改变权威 recommendation snapshot。

`03B · Comma Center Recommendation 是产品 Projection`、`07E · Recommendation SSOT 与 Runtime`、`07F · Recommendation 客户端 Contract 与媒体`、`16B · Recommendation 刷新与事实收集`、`16C · Recommendation 远程媒体安全边界` 和 `16D · Recommendation 发布与行锁结算` 分别展示产品边界、实现 Owner、客户端契约与动态路径。发布与 runtime materialization 使用实现回归测试；旧 `tla/recommendations/` 模型仅为历史证据，当前模型范围见 `tla/README.md`。

## 从产品概念落到当前实现

| 产品/领域概念                       | 当前代码锚点                                                                                                                                                                               | 实现含义                                                                               |
| ----------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------- |
| Comma 用户                            | [`Comma.Accounts.User`](../../systems/apps/comma_core/lib/comma/accounts/user.ex#L1)                                                                                                             | Comma 产品身份；不创建 Salix User                                                        |
| Comma Workspace                       | [`Comma.Data.Workspace`](../../systems/apps/comma_core/lib/comma/data/schemas.ex#L41)                                                                                                            | 保存 Tenant/Group/Router/默认 Worker 映射和 generation                                 |
| Comma 当前 Chat                       | [`Comma.AssistantChats`](../../systems/apps/comma_core/lib/comma/assistant_chats.ex#L1) + [`SalixIM.RouterConversationInput`](../../systems/apps/salix_im/lib/salix_im/router_conversation_input.ex#L1)             | 授权当前 Group，直接解析并复用该 Group 的固定 Router Conversation                      |
| BFT Organization                    | [`BridgeForTeams.Schema.Organization`](../../systems/apps/bridge_for_teams_core/lib/bridge_for_teams/schema/organization.ex#L1)                                                            | 1:1 映射 Salix Tenant                                                                  |
| BFT Agent Swarm                     | [`BridgeForTeams.Schema.Project`](../../systems/apps/bridge_for_teams_core/lib/bridge_for_teams/schema/project.ex#L1)                                                                      | 1:1 映射 Salix Group；产品名与代码历史名不同                                           |
| BFT 当前 Chat                       | [`BridgeForTeams.Schema.UserAssistantChat`](../../systems/apps/bridge_for_teams_core/lib/bridge_for_teams/schema/user_assistant_chat.ex#L1)                                                | `User × Project` 唯一                                                                  |
| Conversation                        | [`SalixIM.ConversationActor`](../../systems/apps/salix_im/lib/salix_im/conversation_actor.ex#L1)                                                                                           | Message 与 membership 的唯一 mutation owner                                            |
| Participant                         | [`SalixIM.ConversationParticipantActor`](../../systems/apps/salix_im/lib/salix_im/conversation_participant_actor.ex#L1)                                                                    | Participant lifecycle、provider log cursor、发送回执与重试的 owner                              |
| Message sender                      | [`SalixIM.ConversationMessage`](../../systems/apps/salix_im/lib/salix_im/conversation_message.ex#L1)                                                                                       | sender identity 存在 Message 上，不从 Participant 猜测                                 |
| Task 创建与模板选择                 | [`SalixIM.Provider.Manuals`](../../systems/apps/salix_im/lib/salix_im/provider/manuals.ex#L1) + [`SalixIM.Ports.TaskCreate`](../../systems/apps/salix_im/lib/salix_im/ports/task_create.ex#L1) | The internal IM operation selects one Worker and passes a self-contained command through the configured port to the Conversation owner. |
| Router Session 选择                 | [`SalixAgent.AgentRoleActor`](../../systems/apps/salix_agent/lib/salix_agent/agent_role_actor.ex#L369)                                                                                     | 忽略 delivery session hint，覆盖为持久化 canonical `router_session_id`                 |
| Worker Session 选择                 | [`SalixIM.AgentDeliveryPayload`](../../systems/apps/salix_im/lib/salix_im/agent_delivery_payload.ex#L181)                                                                                  | 目标 Worker 新建 Session；Worker delegator 可复用 `origin_session_id`                  |
| Comma 控制面显式重新指定 Group Router | [`Comma.Conversations.send_message/5`](../../systems/apps/comma_core/lib/comma/conversations.ex#L185) + [`RouterConversationInput`](../../systems/apps/salix_im/lib/salix_im/router_conversation_input.ex#L1) | 下一次发送通过固定 Router Conversation input reconcile Router Participant；保留同一 Conversation 与历史 |
| BFT 控制面显式重新指定 Group Router | [`BridgeForTeams.AssistantChats`](../../systems/apps/bridge_for_teams_core/lib/bridge_for_teams/assistant_chats.ex#L95)                                                                    | required Router 不匹配时替换 Conversation，并更新同一产品 binding                      |
| Group 固定 Router Chat              | [`SalixIM.RouterConversationInput`](../../systems/apps/salix_im/lib/salix_im/router_conversation_input.ex#L18)                                                                             | 会 reconcile Router Participant；这是 Group 固定 Conversation，不是 Comma Assistant Chat |
| Internal Session Owner              | [`SalixAgent.InternalSessionActor`](../../systems/apps/salix_agent/lib/salix_agent/internal_session_actor.ex#L1)                                                                           | `{agent_id, session_id}` 的 internal runtime 单写者                                    |
| External Session Owner              | [`SalixAgent.ExternalSessionActor`](../../systems/apps/salix_agent/lib/salix_agent/external_session_actor.ex#L1)                                                                           | `{agent_id, session_id}` 的 external runtime 单写者；Salix 平台也支持 external Router  |
| Compute SSOT                        | [`SalixStore.Compute`](../../systems/apps/salix_store/lib/salix_store/compute.ex#L1)                                                                                                       | Pool/Environment/Allocation/Workload/RuntimeInstance/Grant/command 的唯一共享写者      |
| Compute Provider                    | [`SalixEnv.ComputeProvider`](../../systems/apps/salix_env/lib/salix_env/compute_provider.ex#L1)                                                                                            | Cloudflare 和 Agent VMM 的统一 contract 与 conformance surface                  |
| External Worker Binding             | [`SalixAgent.RuntimeBindingResolver`](../../systems/apps/salix_agent/lib/salix_agent/runtime_binding_resolver.ex#L1)                                                                       | 精确两种 binding；stable target 与 live epoch 分离                                     |
| Service Route Authority             | [`SalixStore.ServiceRoutes`](../../systems/apps/salix_store/lib/salix_store/service_routes.ex#L1)                                                                                          | 每次访问重查两端 generation、环境 authority、capability 与 expiry                      |
| Desktop Compute Node                | [`ComputeNodeService`](../../clients/apps/electron/src/main/modules/compute-node/index.ts#L1)                                                                                              | Main-owned provisioned-node status/configure/repair/drain/remove；generated bridge      |
| Comma Recommendation SSOT             | [`Comma.Recommendations`](../../systems/apps/comma_core/lib/comma/recommendations.ex#L1)                                                                                                         | Member×Workspace profile/run、generation/source revision 与 current snapshot 的唯一产品 owner |
| Recommendation Source/Runtime       | [`CommaWeb.RecommendationRuntime`](../../systems/apps/comma_web/lib/comma_web/recommendation_runtime.ex#L1)                                                                                      | Server 有界收集只读 facts；持久化 job 执行决策、文本生成与受约束的发布                |
| Recommendation Contract             | [`@comma/recommendation-contract`](../../clients/packages/recommendation-contract/src/index.ts#L1)                                                                                           | 两个版本化模板、bounded document/action schema 和旧客户端 fallback                     |
| Recommendation Media                | [`recommendationMedia.load`](../../clients/packages/native-bridge/src/capability-leaves.ts#L1624)                                                                                          | Electron Main 安全 intake；Web 只保留 text/action                                      |

Comma/BFT 当前产品 Schema 只允许 internal Router；这是一条产品约束，不是 Salix runtime 的平台级不变量。`06 · 产品概念 → 持久化与权威 Owner`、`07 · Router Single Session → 当前代码实现`、`07B · Worker Multi Session → 当前代码实现` 将产品关系与代码落点分开。

## 如何维护这层模型

- 产品概念和关系由维护者基于真实用户路径与当前代码语义维护，不能由依赖图自动推导。
- [`generate-inventory.mjs`](scripts/generate-inventory.mjs) 会验证上表关键实现锚点仍存在，并把结果写入 [`generated/inventory.md`](generated/inventory.md)。这只能发现锚点漂移，不能证明业务含义仍然正确。
- `pnpm architecture:validate` 在本地重建证据并校验 LikeC4；锚点变化后，应重新检查 cardinality、Owner、入口例外和术语，而不是机械替换模块名。
- 程序化校验通过后，必须由独立的架构师 Agent 阅读生产代码和直接测试，按 blocker / important / suggestion 输出评审；生成模型的 Agent 不能自行宣告语义已经收敛。
- RFC 和旧文档只用于定位问题。图中的当前态判断以生产代码、直接测试和持久化约束为准。

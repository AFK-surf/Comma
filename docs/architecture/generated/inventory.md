# 程序生成的仓库架构事实清单

> 从当前检出的源码确定性生成。这里是证据附录，不是架构叙事；相关源码变化后运行 `pnpm architecture:validate`。评审基线由 PR 或评审记录绑定，不写入生成物。

## 产品概念实现锚点

这张表提供人工维护的实现与测试链接，不检查源码字符串或测试名称，也不证明业务语义。行为证据以实际测试结果为准。

| 产品/领域概念 | 层次 | 当前实现锚点 | 关键直接测试 |
| --- | --- | --- | --- |
| Comma 用户 | 产品身份 | [`Comma.Accounts.User`](../../../systems/apps/comma_core/lib/comma/accounts/user.ex) | — |
| Comma Workspace | 产品范围 | [`Comma.Data.Workspace`](../../../systems/apps/comma_core/lib/comma/data/schemas.ex) | — |
| Comma 当前 Assistant Chat | 产品入口 | [`Comma.AssistantChats`](../../../systems/apps/comma_core/lib/comma/assistant_chats.ex)<br>[`SalixIM.RouterConversationInput`](../../../systems/apps/salix_im/lib/salix_im/router_conversation_input.ex) | [assistant ensure resolves and reuses the Group fixed Router Conversation](../../../systems/apps/comma_core/test/comma_core_test.exs) |
| BFT 用户 | 产品身份 | [`BridgeForTeams.Schema.User`](../../../systems/apps/bridge_for_teams_core/lib/bridge_for_teams/schema/user.ex) | — |
| BFT Organization | 产品范围 | [`BridgeForTeams.Schema.Organization`](../../../systems/apps/bridge_for_teams_core/lib/bridge_for_teams/schema/organization.ex) | — |
| BFT Agent Swarm | 产品范围 | [`BridgeForTeams.Schema.Project`](../../../systems/apps/bridge_for_teams_core/lib/bridge_for_teams/schema/project.ex) | — |
| BFT 当前 Assistant Chat | 产品绑定 | [`BridgeForTeams.Schema.UserAssistantChat`](../../../systems/apps/bridge_for_teams_core/lib/bridge_for_teams/schema/user_assistant_chat.ex) | — |
| Agent 工作范围的 Chat-ready 条件 | 产品生命周期 | [`BridgeForTeams.AssistantChats.ensure_chat/4`](../../../systems/apps/bridge_for_teams_core/lib/bridge_for_teams/assistant_chats.ex) | [invalid router config creates no chat](../../../systems/apps/bridge_for_teams_core/test/contexts/assistant_chats_test.exs) |
| Conversation | 协作事实 | [`SalixIM.ConversationActor`](../../../systems/apps/salix_im/lib/salix_im/conversation_actor.ex) | — |
| Participant 接收目标 | 协作事实 | [`SalixIM.ConversationParticipantActor`](../../../systems/apps/salix_im/lib/salix_im/conversation_participant_actor.ex) | — |
| Message | 协作事实 | [`SalixIM.ConversationMessage`](../../../systems/apps/salix_im/lib/salix_im/conversation_message.ex) | — |
| Router Single Session | 执行上下文 | [`SalixAgent.AgentRoleActor`](../../../systems/apps/salix_agent/lib/salix_agent/agent_role_actor.ex) | [a session-less delivery to a router resolves its session at deliver time](../../../systems/apps/salix_agent/test/deliver_ingress_test.exs) |
| Worker Multi Session | 执行上下文 | [`SalixIM.AgentDeliveryPayload`](../../../systems/apps/salix_im/lib/salix_im/agent_delivery_payload.ex) | [worker participant payload uses origin session only when it is the delegator](../../../systems/apps/salix_im/test/agent_actor_role_routing_test.exs) |
| Task 创建与持久化边界 | Task creation input | [`SalixIM.Provider.Internal.internal.task.create`](../../../systems/apps/salix_im/lib/salix_im/provider/internal.ex)<br>[`SalixIM.Provider.Manuals.internal.task.create`](../../../systems/apps/salix_im/lib/salix_im/provider/manuals.ex)<br>[`SalixIM.Ports.TaskCreate`](../../../systems/apps/salix_im/lib/salix_im/ports/task_create.ex)<br>[`Salix.Bindings.AgentConversations`](../../../systems/apps/salix_web/lib/salix/bindings/agent_conversations.ex)<br>[`SalixCluster.TaskSchedules`](../../../systems/apps/salix_cluster/lib/salix_cluster/task_schedules.ex)<br>[`SalixIM.TaskConversationInput`](../../../systems/apps/salix_im/lib/salix_im/task_conversation_input.ex) | [im_api.internal.task.create owns command preparation and calls only the TaskSchedules port](../../../systems/apps/salix_im/test/provider_test.exs) |
| 普通 Task Worker 停机监督 | Task owner | [`SalixIM.TaskWorkerWatch`](../../../systems/apps/salix_im/lib/salix_im/task_worker_watch.ex) | [TaskWorkerWatch reminds a silent stopped Worker once, then tells the Router](../../../systems/apps/salix_im/test/conversations_test.exs)<br>[TaskWorkerWatch does not escalate the stop it already reminded for after a restart](../../../systems/apps/salix_im/test/conversations_test.exs)<br>[TaskWorkerWatch retries a reminder whose append failed](../../../systems/apps/salix_im/test/conversations_test.exs) |
| Participant 实时状态与显式 Message 边界 | 可见输出 | [`SalixAgent.ToolPolicy`](../../../systems/apps/salix_agent/lib/salix_agent/tool_policy.ex) | [participant direct reads recover a missed realtime draft clear invalidation](../../../systems/apps/salix_im/test/conversations_test.exs)<br>[participant status keeps display text separate from its exact presentation on a shared session](../../../systems/apps/salix_im/test/conversations_test.exs)<br>[an internal conversation gains an agent Message only from explicit send_message](../../../systems/apps/salix_agent/test/server_test.exs)<br>[explicit Feishu dynamic IM operation is the visible reply path](../../../systems/apps/salix_agent/test/server_test.exs) |
| Comma Workspace → Group scope revision | 产品授权 | [`Comma.WorkspaceGroupBinding`](../../../systems/apps/comma_core/lib/comma/workspace_group_binding.ex) | — |
| Comma 控制面显式重新指定 Group Router：固定 Conversation 发送 | 产品生命周期 | [`Comma.Conversations.send_message/5`](../../../systems/apps/comma_core/lib/comma/conversations.ex) | [the next Comma Chat send follows an explicitly reassigned Group Router](../../../systems/apps/comma_web/test/comma_api_test.exs) |
| Group 固定 Router Conversation 显式重新指定收敛 | Salix 产品编排 | [`SalixIM.RouterConversationInput`](../../../systems/apps/salix_im/lib/salix_im/router_conversation_input.ex) | [concurrent Router reassignment cannot deactivate both desired Router participants](../../../systems/apps/salix_im/test/conversations_test.exs) |
| BFT 控制面显式重新指定 Group Router | 产品生命周期 | [`BridgeForTeams.AssistantChats`](../../../systems/apps/bridge_for_teams_core/lib/bridge_for_teams/assistant_chats.ex) | [revalidates canonical kind, current Router, and BFT provider before reuse](../../../systems/apps/bridge_for_teams_core/test/contexts/assistant_chats_test.exs) |
| Comma Center Recommendation 产品 Projection SSOT | 产品 Projection | [`Comma.Recommendations`](../../../systems/apps/comma_core/lib/comma/recommendations.ex)<br>[`RecommendationProfile`](../../../systems/apps/comma_core/lib/comma/data/recommendation_profile.ex)<br>[`RecommendationRun`](../../../systems/apps/comma_core/lib/comma/data/recommendation_run.ex) | [a repeated manual refresh atomically supersedes the active run and clears its evidence](../../../systems/apps/comma_core/test/comma/recommendations_test.exs)<br>[source changes supersede an active run and stop exposing refreshing state](../../../systems/apps/comma_core/test/comma/recommendations_test.exs) |
| Recommendation 有界 Source Collector 与受限 Renderer | 产品 Runtime | [`CommaWeb.RecommendationSourceCollector`](../../../systems/apps/comma_web/lib/comma_web/recommendation_source_collector.ex)<br>[`RecommendationRuntime`](../../../systems/apps/comma_web/lib/comma_web/recommendation_runtime.ex) | [HTTP refresh durably queues work before collection and publishes one stateless model response](../../../systems/apps/comma_web/test/local_recommendation_flow_test.exs) |
| Recommendation 版本化 Contract 与 Electron Media Intake | 客户端边界 | [`@comma/recommendation-contract`](../../../clients/packages/recommendation-contract/src/index.ts)<br>[`recommendationMedia.load`](../../../clients/packages/native-bridge/src/capability-leaves.ts)<br>[`Electron Recommendation Media`](../../../clients/apps/electron/src/main/modules/recommendation-media/index.ts) | [rejects a hostname if any returned address is private](../../../clients/apps/electron/src/main/test/recommendation-media.test.ts) |
| Internal Runtime Session | 执行 Owner | [`SalixAgent.InternalSessionActor`](../../../systems/apps/salix_agent/lib/salix_agent/internal_session_actor.ex) | — |
| External Runtime Session | 执行 Owner | [`SalixAgent.ExternalSessionActor`](../../../systems/apps/salix_agent/lib/salix_agent/external_session_actor.ex) | — |

## 客户端 Workspace 模块

| 模块 | 类型 | 产品/Peer 依赖 | 开发依赖 |
| --- | --- | --- | --- |
| [@comma/admin](../../../clients/apps/admin/package.json) | 应用 | @comma/app<br>@comma/config<br>@comma/ui | — |
| [@comma/app](../../../clients/packages/app/package.json) | 包 | @comma/chat-contract<br>@comma/config<br>@comma/i18n<br>@comma/layout-inspector<br>@comma/native-bridge<br>@comma/product-inbox-runtime<br>@comma/recommendation-contract<br>@comma/session-contract<br>@comma/session-history-runtime<br>@comma/ui | — |
| [@comma/chat-contract](../../../clients/packages/chat-contract/package.json) | 包 | — | — |
| [@comma/config](../../../clients/packages/config/package.json) | 包 | — | — |
| [@comma/electron](../../../clients/apps/electron/package.json) | 应用 | @comma/app<br>@comma/chat-contract<br>@comma/config<br>@comma/i18n<br>@comma/native-bridge<br>@comma/product-inbox-runtime<br>@comma/session-contract<br>@comma/session-history-runtime | — |
| [@comma/i18n](../../../clients/packages/i18n/package.json) | 包 | — | — |
| [@comma/layout-inspector](../../../clients/packages/layout-inspector/package.json) | 包 | — | @comma/test-utils |
| [@comma/native-bridge](../../../clients/packages/native-bridge/package.json) | 包 | @comma/chat-contract<br>@comma/session-contract | — |
| [@comma/product-inbox-runtime](../../../clients/packages/product-inbox-runtime/package.json) | 包 | @comma/native-bridge<br>@comma/session-contract | — |
| [@comma/recommendation-contract](../../../clients/packages/recommendation-contract/package.json) | 包 | — | — |
| [@comma/session-contract](../../../clients/packages/session-contract/package.json) | 包 | — | — |
| [@comma/session-history-runtime](../../../clients/packages/session-history-runtime/package.json) | 包 | @comma/native-bridge<br>@comma/session-contract | — |
| [@comma/test-utils](../../../clients/packages/test-utils/package.json) | 包 | @comma/native-bridge | — |
| [@comma/ui](../../../clients/packages/ui/package.json) | 包 | @comma/i18n | @comma/layout-inspector |
| [@comma/web](../../../clients/apps/web/package.json) | 应用 | @comma/app<br>@comma/chat-contract<br>@comma/config<br>@comma/i18n<br>@comma/native-bridge<br>@comma/product-inbox-runtime<br>@comma/session-contract<br>@comma/session-history-runtime | — |

## Release 子系统成员

来源：[`Comma.@subsystems`](../../../systems/apps/comma/lib/comma.ex)。成员关系表示“启用该子系统时按顺序启动”，不表示每个 OTP 应用都是独立部署的服务。

| 子系统 | 按启动顺序排列的 OTP 应用 |
| --- | --- |
| `alert_router` | `alert_router` |
| `salix` | `salix_store`, `salix_calendar`, `salix_analytics`, `billing_core`, `billing_commerce`, `billing_stripe`, `salix_agent`, `salix_cluster`, `salix_llm`, `salix_env`, `salix_im`, `salix_voice`, `salix_signal_proto`, `salix_signal`, `salix_mcp`, `salix_web`, `salix_migrate`, `salix_media`, `salix_meet` |
| `comma_product` | `billing_core`, `billing_commerce`, `billing_stripe`, `comma_core`, `comma_web`, `comma_tui`, `comma_ssh` |
| `bridge_for_teams` | `billing_core`, `billing_commerce`, `bridge_for_teams_core`, `bridge_for_teams_web` |

## OTP 源码依赖

| OTP 应用 | 运行时子系统成员 | 生产 in_umbrella 依赖 |
| --- | --- | --- |
| [`alert_router`](../../../systems/apps/alert_router/mix.exs) | `alert_router` | `systems_observability`, `salix_store` |
| [`billing_commerce`](../../../systems/apps/billing_commerce/mix.exs) | `salix`, `comma_product`, `bridge_for_teams` | `billing_core`, `salix_analytics` |
| [`billing_core`](../../../systems/apps/billing_core/mix.exs) | `salix`, `comma_product`, `bridge_for_teams` | `systems_observability`, `salix_analytics` |
| [`billing_stripe`](../../../systems/apps/billing_stripe/mix.exs) | `salix`, `comma_product` | `billing_commerce`, `billing_core` |
| [`bridge_for_teams_core`](../../../systems/apps/bridge_for_teams_core/mix.exs) | `bridge_for_teams` | `systems_observability`, `billing_core`, `billing_commerce`, `salix_store`, `salix_calendar`, `comma_log` |
| [`bridge_for_teams_web`](../../../systems/apps/bridge_for_teams_web/mix.exs) | `bridge_for_teams` | `systems_observability`, `bridge_for_teams_core` |
| [`comma`](../../../systems/apps/comma/mix.exs) | 传递/支持应用 | `systems_observability` |
| [`comma_core`](../../../systems/apps/comma_core/mix.exs) | `comma_product` | `systems_observability`, `billing_core`, `salix_store`, `salix_agent` |
| [`comma_log`](../../../systems/apps/comma_log/mix.exs) | 传递/支持应用 | `systems_observability` |
| [`comma_ssh`](../../../systems/apps/comma_ssh/mix.exs) | `comma_product` | `comma_core` |
| [`comma_tui`](../../../systems/apps/comma_tui/mix.exs) | `comma_product` | — |
| [`comma_web`](../../../systems/apps/comma_web/mix.exs) | `comma_product` | `systems_observability`, `billing_core`, `billing_commerce`, `billing_stripe`, `comma_core`, `salix_agent`, `salix_cluster`, `salix_im`, `salix_mcp`, `salix_web` |
| [`salix_agent`](../../../systems/apps/salix_agent/mix.exs) | `salix` | `systems_observability`, `salix_ifc`, `salix_store`, `salix_media` |
| [`salix_analytics`](../../../systems/apps/salix_analytics/mix.exs) | `salix` | `salix_store`, `salix_cluster` |
| [`salix_calendar`](../../../systems/apps/salix_calendar/mix.exs) | `salix` | `salix_store` |
| [`salix_cluster`](../../../systems/apps/salix_cluster/mix.exs) | `salix` | `salix_store`, `salix_agent`, `salix_calendar`, `salix_env`, `salix_im` |
| [`salix_env`](../../../systems/apps/salix_env/mix.exs) | `salix` | `salix_store`, `systems_observability` |
| [`salix_ifc`](../../../systems/apps/salix_ifc/mix.exs) | 传递/支持应用 | — |
| [`salix_im`](../../../systems/apps/salix_im/mix.exs) | `salix` | `salix_ifc`, `salix_store` |
| [`salix_llm`](../../../systems/apps/salix_llm/mix.exs) | `salix` | `systems_observability`, `salix_agent`, `salix_media` |
| [`salix_mcp`](../../../systems/apps/salix_mcp/mix.exs) | `salix` | `salix_agent`, `salix_store`, `salix_env` |
| [`salix_media`](../../../systems/apps/salix_media/mix.exs) | `salix` | — |
| [`salix_meet`](../../../systems/apps/salix_meet/mix.exs) | `salix` | `systems_observability`, `salix_store`, `salix_agent`, `salix_calendar`, `salix_cluster`, `salix_im` |
| [`salix_migrate`](../../../systems/apps/salix_migrate/mix.exs) | `salix` | `salix_store`, `salix_agent` |
| [`salix_signal`](../../../systems/apps/salix_signal/mix.exs) | `salix` | `salix_signal_proto`, `salix_voice`, `salix_store`, `salix_cluster` |
| [`salix_signal_proto`](../../../systems/apps/salix_signal_proto/mix.exs) | `salix` | — |
| [`salix_store`](../../../systems/apps/salix_store/mix.exs) | `salix` | `comma_log`, `systems_observability` |
| [`salix_voice`](../../../systems/apps/salix_voice/mix.exs) | `salix` | `salix_store`, `salix_agent`, `salix_im`, `salix_cluster` |
| [`salix_web`](../../../systems/apps/salix_web/mix.exs) | `salix` | `salix_store`, `salix_agent`, `salix_im`, `salix_mcp`, `salix_meet`, `salix_calendar`, `salix_env`, `salix_cluster`, `salix_voice`, `salix_signal`, `bridge_for_teams_core`, `salix_llm`, `salix_analytics`, `systems_observability` |
| [`systems_observability`](../../../systems/apps/systems_observability/mix.exs) | 传递/支持应用 | — |

## Native Capability Namespace

来源：[Leaf Registry](../../../clients/packages/native-bridge/src/capability-leaves.ts)。同一 ID 的 command/event/state wrapper 按各自类型计数一次。

| Namespace | Command | Event | State | ID |
| --- | ---: | ---: | ---: | --- |
| `airDrop` | 3 | 1 | 1 | airDrop.act<br>airDrop.preview<br>airDrop.state<br>airDrop.state.changed |
| `appearance` | 2 | 0 | 0 | appearance.fontFamilies<br>appearance.setResolvedTheme |
| `applicationMenu` | 1 | 1 | 0 | applicationMenu.command<br>applicationMenu.update |
| `appPreferences` | 4 | 1 | 1 | appPreferences.initializeClientSettings<br>appPreferences.openNotificationSettings<br>appPreferences.state<br>appPreferences.state.changed<br>appPreferences.update |
| `audioCapture` | 11 | 1 | 1 | audioCapture.cancel<br>audioCapture.microphones<br>audioCapture.openPermissionSettings<br>audioCapture.openSaved<br>audioCapture.pause<br>audioCapture.resume<br>audioCapture.selectMicrophone<br>audioCapture.sources<br>audioCapture.start<br>audioCapture.state<br>audioCapture.state.changed<br>audioCapture.stop |
| `browserSidebar` | 7 | 2 | 0 | browserSidebar.capture<br>browserSidebar.changed<br>browserSidebar.close<br>browserSidebar.inspect<br>browserSidebar.navigate<br>browserSidebar.open<br>browserSidebar.openTabRequested<br>browserSidebar.showPermissions<br>browserSidebar.update |
| `chat` | 23 | 2 | 2 | chat.acceptTaskReview<br>chat.acknowledgeIntakeFailures<br>chat.attach<br>chat.attachLocalFiles<br>chat.beginSendIntent<br>chat.cancelSendIntent<br>chat.clearPresentation<br>chat.discard<br>chat.drafts<br>chat.drafts.changed<br>chat.listSkills<br>chat.pickAttachments<br>chat.presentInSideChat<br>chat.readGroupImage<br>chat.refresh<br>chat.release<br>chat.removeAttachment<br>chat.resolveWorkspaceChat<br>chat.retain<br>chat.retry<br>chat.retryAttachment<br>chat.send<br>chat.setDraft<br>chat.state<br>chat.state.changed |
| `clipboard` | 4 | 0 | 0 | clipboard.readImage<br>clipboard.readText<br>clipboard.writeImage<br>clipboard.writeText |
| `computeNode` | 6 | 1 | 1 | computeNode.configure<br>computeNode.drain<br>computeNode.rebuild<br>computeNode.remove<br>computeNode.repair<br>computeNode.state<br>computeNode.state.changed |
| `computerUse` | 2 | 0 | 0 | computerUse.getPermissions<br>computerUse.openPermissionFlow |
| `connectorRuntime` | 4 | 1 | 1 | connectorRuntime.copyConnectCommand<br>connectorRuntime.scope<br>connectorRuntime.setScope<br>connectorRuntime.state<br>connectorRuntime.state.changed |
| `driveCatalog` | 2 | 1 | 1 | driveCatalog.query<br>driveCatalog.state<br>driveCatalog.state.changed |
| `files` | 5 | 0 | 0 | files.copyDownload<br>files.listOpenApplications<br>files.openDownload<br>files.revealDownload<br>files.saveDownload |
| `localData` | 1 | 0 | 0 | localData.status |
| `localFiles` | 2 | 0 | 0 | localFiles.pick<br>localFiles.preview |
| `meetingPresence` | 2 | 1 | 1 | meetingPresence.icon<br>meetingPresence.state<br>meetingPresence.state.changed |
| `meetingRecorder` | 8 | 1 | 1 | meetingRecorder.acknowledgeSaved<br>meetingRecorder.action<br>meetingRecorder.dragWindow<br>meetingRecorder.layoutWindow<br>meetingRecorder.retryTaskSync<br>meetingRecorder.selectMicrophone<br>meetingRecorder.setInteractive<br>meetingRecorder.state<br>meetingRecorder.state.changed |
| `messageNotifications` | 0 | 1 | 0 | messageNotifications.event |
| `native` | 1 | 0 | 0 | native.info |
| `notch` | 10 | 1 | 0 | notch.close<br>notch.event<br>notch.hide<br>notch.open<br>notch.preview<br>notch.pulse<br>notch.show<br>notch.status<br>notch.stop<br>notch.toggle<br>notch.update |
| `peers` | 1 | 0 | 0 | peers.connect |
| `productInbox` | 4 | 1 | 1 | productInbox.refresh<br>productInbox.release<br>productInbox.retain<br>productInbox.state<br>productInbox.state.changed |
| `recommendationMedia` | 1 | 0 | 0 | recommendationMedia.load |
| `session` | 8 | 1 | 1 | session.cancelAuthAttempt<br>session.reconcile<br>session.requestEmailLogin<br>session.signInWithGoogle<br>session.signOut<br>session.state<br>session.state.changed<br>session.verifyEmailLogin<br>session.verifyGoogleLink |
| `sessionHistory` | 4 | 1 | 1 | sessionHistory.load<br>sessionHistory.release<br>sessionHistory.retain<br>sessionHistory.state<br>sessionHistory.state.changed |
| `shell` | 1 | 0 | 0 | shell.openExternal |
| `sideChat` | 12 | 2 | 2 | sideChat.close<br>sideChat.closeTestWindow<br>sideChat.debugSettings<br>sideChat.debugSettings.changed<br>sideChat.finishInteractiveProgress<br>sideChat.openSettings<br>sideChat.openTestWindow<br>sideChat.presentation<br>sideChat.presentation.changed<br>sideChat.resetDebugSettings<br>sideChat.setContentSize<br>sideChat.setInteractiveProgress<br>sideChat.updateDebugSettings<br>sideChat.updateShortcut |
| `sitePermissionMenu` | 2 | 1 | 1 | sitePermissionMenu.act<br>sitePermissionMenu.changed<br>sitePermissionMenu.state |
| `subscriptionAuthorization` | 3 | 0 | 0 | subscriptionAuthorization.cancel<br>subscriptionAuthorization.start<br>subscriptionAuthorization.status |
| `surfaces` | 2 | 3 | 2 | surfaces.changed<br>surfaces.state<br>surfaces.windowFullScreen<br>surfaces.windowFullScreen.changed<br>surfaces.windowResizeSettled |
| `synchronicity` | 21 | 0 | 0 | synchronicity.adopt<br>synchronicity.adoptTree<br>synchronicity.delete<br>synchronicity.importFile<br>synchronicity.list<br>synchronicity.openLocalRoot<br>synchronicity.pickFolder<br>synchronicity.pin<br>synchronicity.read<br>synchronicity.replicaSet<br>synchronicity.replicaSync<br>synchronicity.restart<br>synchronicity.saveDownload<br>synchronicity.scan<br>synchronicity.setDomain<br>synchronicity.setSpaceSettings<br>synchronicity.sourceAdd<br>synchronicity.sourceRemove<br>synchronicity.state<br>synchronicity.versions<br>synchronicity.write |
| `transport` | 1 | 0 | 0 | transport.status |
| `windows` | 3 | 0 | 0 | windows.close<br>windows.create<br>windows.focus |

### 冻结的 raw IPC 例外

来源：[Electron Main 入口](../../../clients/apps/electron/src/main/index.ts)。这些是生成式 Gateway 的当前态例外，不是扩展点。

- `comma:connector:configure`
- `comma:connector:restart`
- `comma:connector:start`
- `comma:connector:status`
- `comma:connector:stop`
- `comma:connector:uninstall`
- `comma:updates:apply`
- `comma:updates:check`
- `comma:updates:download`
- `comma:updates:status`

## 当前部署表面

来源：[Helm Application Template](../../../k8s/comma/chart/templates/application.yaml)。

- Workload 类型：`StatefulSet`
- 启用的子系统：`salix`, `bridge_for_teams`, `comma_product`
- Container 端口：`salix-http:4000`, `salix-transfer:4400`, `teams-http:4101`, `product-http:4200`, `epmd:4369`, `dist:9100`, `telemetry:9568`, `http:4300`, `telemetry:9568`

| Service | 端口 | Target Port |
| --- | ---: | --- |
| `comma-alert-router` | 80 | `http` |
| `comma-headless` | 4400 | `salix-transfer` |
| `comma-salix` | 80 | `salix-http` |
| `comma-teams` | 80 | `teams-http` |
| `comma-product` | 80 | `product-http` |

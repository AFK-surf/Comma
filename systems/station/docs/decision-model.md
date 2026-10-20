# 自动决策

设置中有独立的「自动决策」页面，按决策点列入口。进入决策点后，分别配置各 station 的启用开关和模型。检查记录在独立页面查看。现在唯一的决策点是归档建议（见下）。默认关闭。只有 workspace 管理员能保存配置或触发检查，由 station 校验。配置只保存 `automaticDecisions.completion.{enabled,model}`，凭据始终由 Profile 管理。

## 模型和连接

模型候选来自现有 Profile 的能力发现。不另填地址和 key，不手工绑定 Profile。多个健康 Profile 可以提供同一个模型。临时连接失败时，自动换另一个支持该模型的 Profile，不换成另一个模型。

station 启动、Profile 修改或检查、自动决策页「刷新模型」时都会识别能力。合成探针验证原生 Jev 概率，或关闭 thinking 的单 token logprobs。模型名称只用于排序，不能证明可用。探测不通过的模型不会被选中。不把模型生成的“置信度”当 logits。OpenCode 和 OpenCode Go 的网关要求每个请求带 `x-opencode-session: <任意 uuid>`，探测和真实决策请求都会带上。

连接来源：

- API 服务商 Profile（OpenCode Go 与「API 服务商」）：用服务商目录里的 chat_completions 接口和 Profile 保存的 key。只有 Responses 或 Anthropic 接口的服务商（如 OpenAI、xAI、Azure OpenAI）不能做自动决策。
- Codex Profile：既有环境变量、config.toml provider 或 API-key 登录。普通 API 用 base_url/env_key，或 OPENAI_BASE_URL/OPENAI_API_KEY。订阅 OAuth token 不当 API key 用。
- Jev：用 Profile 的 TYPESAFE_API_KEY / JEV_API_KEY 与可选的 TYPESAFE_BASE_URL。Jev 也可以作为「API 服务商」Profile 添加（只填 key）。它只用于自动决策，不接 Claude Code 和 Codex。它没有模型列表，key 在发现决策能力时才被试。

## 归档建议

agent 的一轮以 `all_done`（旧 `final` 同）结束后，station 在后台问决策模型：这个 chat 还有没有事情要做。agent 的结束状态、发帖和落库不等它，也不会被它拦下。规则没开、模型不可用或请求失败，都只是没有推荐。规则刚打开或换了模型时，以及 station 启动后，会补查还没有判断结果的已完成 chat。

- 模型看到这个 session 各会话从新到旧、放得下的消息，按时间顺序排好，加上待决定的卡片。放不下的旧消息会注明被省略。
- 问法由归档策略决定：一段说明加若干选项，每个选项注明算不算推荐归档。人在页面上改策略，agent 用 `archive_policy` 工具改，存在 `archive_policy` 表。没人改过时用默认策略（[archive-policy.ts](../src/sessions/archive-policy.ts)）。
- 模型选中的选项算推荐归档，并且所有算推荐归档的选项的概率之和达到阈值，才推荐归档。模型概率不是校准过的正确率。
- 推荐后，这个 chat 标为「推荐归档」。规则开着的 station 上，只有推荐过的 chat 才淡出、排到当天最后、可以一点归档。没推荐的照常显示。推荐记在 `archive_suggestions`，带着判断时 chat 的最后一条消息号。之后任何人在 chat 里再说话，推荐自动失效。用户选「保留」的 chat 不显示推荐。
- 判断期间设置、策略变了或 chat 又有新消息，这次结果作废。每次结果（含失败）写进 `decision_checks`，审计不存聊天正文或凭据。在自动决策页的检查记录里看。新结果通过 station 事件刷新 Overview，客户端不轮询。

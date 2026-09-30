# 多 agent 收件人误接单：脱敏现场回放

两段 fixture 来自 2026-09-04 生产 Slack 归档和对应 GCP ingress 日志；经用户要求脱敏后保留在测试中。它们不是模型生成的对话。

- `notion_owner_table.json`：用户与 Bridge 整理 owner 表格，随后用户**只 @个人 agent**，要求创建 Notion 文档并审阅规则；Bridge 却回复接单。
- `jenkins_mcp.json`：用户先同时提到 Bridge 和个人 agent 讨论方案，两者都参与；随后用户**只 @个人 agent**，要求接入 Jenkins MCP；Bridge 再次插话。

`history` 保留触发前已取到的消息顺序和正文；`trigger` 是本次需要拒绝的真实消息；`observed_incorrect_reply` 只记录历史错误结果，不作为期待生成的答案或新的回调输入。没有收录触发后的长篇输出、文件和 Notion 页面内容。

脱敏规则：

- 人物、bot、workspace、channel、event 等身份换成固定测试标识；无真实 ID 映射表、token、内部链接或客户名称。
- 仓库名替换成 `sample-repo-NN`；个人 agent 的名称替换成 `Personal Agent`；链接替换为 `example.test`。
- 每个线程从虚构 epoch 开始，保留消息相对时间差及 `thread_ts` 关联。
- 触发消息的 text 与 rich-text user/text 元素沿用日志确认的结构；不保留无关的 block ID。历史行来自归档字段重建事件信封，补齐测试所需 channel/type/bot 标记，不声称是原始 webhook 全量导出。

## 回放边界

`slack_triage_callback_route_test.exs` 经签名验证的 `ProviderHTTP.handle_slack_event/4` 回放历史和触发消息。真实 PostgreSQL participation 表重建现场已验证的“Bridge 参与过线程”；现场无 command owner / Task binding、Triage 未 provision。S3、归档 outbox、AgentDelivery 使用现有测试替身，不调用 LLM、Slack 或 Notion。

断言触发和重送均为 ignored、仍归档、不投递 Router、无 receipt、无新增或修改的 Task conversation。另有不带 @ 的正向续聊，防止用“关闭全部回复”通过测试。相同真实触发还用于 command owner + Triage 开/关的补充矩阵；这些 owner 状态是测试构造，不是生产现场结论。真实绑定 Task 的拒绝与正常续聊由 `provider_test.exs` 的 Task handover 集成测试覆盖。

这些用例固定本次明确 @ 收件人的回归边界，不证明所有自然语言指代都能被正确理解，也不代表代码已经部署。

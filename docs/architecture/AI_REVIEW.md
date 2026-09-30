# 独立架构师 Agent 复核记录

本轮先由生成 Agent 基于生产代码构建产品模型、LikeC4 视图和程序化证据，再交给独立的架构师 Agent 复核。架构师 Agent 不以生成结果自证，而是重新阅读相关生产代码与直接测试，按 blocker / important / suggestion 输出结论。

2026-08-25 amendment：本文前几轮中关于“plain assistant + standalone
`end_turn` 自动提交 Message”的描述只保留为历史评审记录，已经由
[`Participant-owned realtime status and explicit Message egress`](../adr/2026-08-25-participant-owned-realtime-status-and-explicit-message-egress.md)
取代。当前实现由 exact Participant 拥有 realtime activity/draft 订阅；canonical Message
只来自 Agent 显式调用发送 API。

[`generated/inventory.json`](generated/inventory.json) 只记录由当前检出源码确定的事实，不嵌入会随提交或工作树变化的元数据。评审基线由 PR 或评审记录绑定；现有 RFC/说明文档只作为代码定位线索，不直接作为当前实现事实。

## 架构师 Agent 的评审输入与门槛

评审至少覆盖：

- [`PRODUCT_MODEL.md`](PRODUCT_MODEL.md)、人工 LikeC4 模型和程序生成的事实清单；
- 支撑关键关系的生产代码、持久化约束和直接测试；
- 产品概念、cardinality、生命周期、Owner、入口例外与图的首次阅读体验；
- 当前工作树，而不只是 HEAD 上的旧版本。

程序化校验通过不等于语义评审通过。Blocker 未修正并经架构师 Agent 再次确认前，生成 Agent 不能宣告架构模型已经收敛。

## 第一轮发现与修正

| 级别      | 架构师 Agent 发现                                                                | 本轮修正                                                                                                                     |
| --------- | -------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| Blocker   | Organization、Agent 工作范围和 Router 被画成无条件 `1..N / 1:1`                  | 改为 Organization → Agent Swarm `0:N`、范围 → 当前 Router `0..1`；只有 chat-ready 范围要求 Router 为 `1`                     |
| Blocker   | 动态图把所有 Round 完成画成自动写入可见 Conversation                             | 当时先拆出 runtime transcript 与显式 IM/provider operation；第五轮曾加入 source-bound 窄例外，该历史合同现已由本文开头的 2026-08-25 amendment 取代 |
| Important | “每个 Worker Participant 都新建 Session”遗漏 Worker delegator 复用 origin 的例外 | 新增 Assigned Worker、Router Delegator、Worker Delegator 三种明确 Participant，并增加 `04C`、`07B`                           |
| Important | `04` 没有同时表达 Message sender 与 Router Participant target                    | `04` 改为 Router 主路径，显式加入 Message 与 Router Participant；Worker 对照拆到独立视图                                     |
| Important | 缺少控制面显式重新指定 Group Router 的生命周期（此前文档称 Router rotation）     | 第一轮先新增通用 `04D`；第二轮发现 Comma/BFT 行为不同后，再拆成两条产品路径                                                    |
| Important | 把 internal Router 误写成 Salix 平台级不变量                                     | `07` 同时画出 Internal/External Session Owner，并明确“Comma/BFT 当前 internal”只是产品约束                                     |
| Important | 维护流程仍允许普通 AI 自行完成语义复核                                           | README 与产品模型明确要求独立架构师 Agent 评审和 blocker 再复核                                                              |
| Important | 只记录 HEAD、锚点只验证字符串，证据溯源不足                                      | 清单增加 20 个实现锚点和关键直接测试链接；评审基线在外部绑定，继续声明 marker 不证明业务语义                                 |

## 第二轮发现与修正

| 级别      | 架构师 Agent 发现                                                       | 本轮处理                                                                                                                                                                       |
| --------- | ----------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 验收校正  | 首页仍展示全部视图 Gallery，曾被理解为“目录根级仍拍平”                  | 用户截图对应的是图内左上角目录菜单；已用构建后的真实 UI 复核，该菜单根级只有 6 个主题文件夹。README 同时明确：首页 Gallery 是浏览表面，不是目录层级                            |
| Blocker   | `04B` 把 internal reply 与 Provider reply 合并，并统一指向 Conversation | 拆成不同 operation 与 sink：内部显式回复经 ConversationServer 进入产品 Conversation，Provider operation 进入外部 Channel；第五轮曾补 direct Comma source-bound 窄分支，现已退休 |
| Blocker   | 第一轮 `04D` 把 Comma 保留 Conversation 的行为泛化到 BFT                  | 拆为 `04D · Comma` 与 `04E · BFT`：Comma 保留 Conversation 并 reconcile Participant；BFT 保留 binding 行、创建新 Conversation 并更新 `conversation_id`，两者都显式画出新旧 Session |
| Important | `Conversation → Router Session N:1` 缺少 Router Participant 条件        | 表格改为“带当前 Router Participant 的 Conversation → Router Session”；没有该 Participant 的 Conversation 不进入 Router Session                                                 |
| Important | 产品主图只表达 Router 创建 Task，与 Worker 再委派不一致                 | `Agent Task` 改为 Router 或 Worker 委派，并在产品模型中同时加入两条 delegator 关系                                                                                             |
| Important | 复核记录没有说明第二轮 verdict 和测试边界                               | 本节记录第二轮发现；最终结论必须等待这些修正完成后的再次独立复核                                                                                                               |

## 第三轮发现与修正

| 级别       | 架构师 Agent 发现                                                                                             | 本轮处理                                                                                                                                                                                |
| ---------- | ------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Blocker    | `04D` 错把 `RouterConversationInput` 的 Group 固定 Router Conversation reconcile 当作 Comma Assistant Chat 行为 | 当时改为明确的实现缺口：Comma binding 与 Conversation 保持，但发送路径只 ensure User Participant；重新指定前的 Router Participant 不会收敛到控制面当前 Router。该历史缺口已由后续变更修复 |
| Important  | `.preview/png` 未清理，已经删除的旧视图仍会残留                                                               | 新增 `architecture:prepare-preview`，`architecture:build` 在导出前只清理并重建 `.preview/site` 与 `.preview/png` 两个精确目标                                                           |
| Suggestion | `04B` 两条互斥可见回复路径可能被按顺序理解                                                                    | 关系标签增加“内部入口分支 / 外部入口分支”，继续保留不同 operation 和不同 sink                                                                                                           |

第三轮修正后仍必须再次由独立架构师 Agent 复核，特别确认 `04D` 没有把实现缺口写成目标态，以及本地构建不会再保留已删除视图。

## 第四轮最终结论

独立架构师 Agent 的最终 verdict 为：**Blocker 0，Important 0；当前态架构原型语义收敛。**

这项历史结论只表示当时材料准确反映当时生产代码。之后的“控制面显式重新指定 Group Router”变更已经补上 Comma Participant reconcile、集成回归、TLA+ 模型与图中证据锚点；本轮仍需再次由独立架构师复核。

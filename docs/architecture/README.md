# Comma 架构导览（可读性原型）

这套材料用于帮助新入职开发人员先建立产品词汇和概念关系，再理解“这些概念由谁实现、谁拥有哪类事实、一次关键操作如何穿过运行时边界”。它不是类图，也不尝试枚举 Route、模块或函数。

当前只表达已在代码中成立的架构。目标态、历史方案和仍在迁移中的愿望不会混入当前态；确实存在的例外会明确标为例外。

## 开始阅读

在仓库根目录安装依赖并启动交互式浏览器：

```sh
pnpm install
pnpm architecture
```

先阅读 [`PRODUCT_MODEL.md`](PRODUCT_MODEL.md)。它解释核心产品概念、Comma/BFT 的术语差异、Task lifecycle，以及 Single Session 中 User、Agent、Conversation、Participant 和 Runtime Session 的准确关系。

进入任一图后，左上角目录菜单的根级只保留六个主题文件夹，避免像旧版本一样把所有视图平铺在该菜单中：`01 · 产品与领域`、`02 · Single Session`、`03 · 概念到实现`、`04 · 系统与运行时`、`05 · 关键动态路径`、`06 · 程序化证据`。LikeC4 首页仍保留全部视图的缩略图 Gallery，便于浏览，不把它当成目录层级。

随后按下面的顺序阅读文件夹中的图：

1. `01–03`：用户、范围、Agent 团队与协作对象。
2. `04–05`：Single Session 的准确语义和所有同名 Session 的消歧；`04B` 拆分内部/外部显式回复 sink，`04C` 对照 Worker，`04D` 展示 Comma 在控制面显式重新指定 Group Router 后复用 Conversation 的路径，`04E` 展示 BFT 的替换路径。
3. `06–08`：从产品概念延伸到当前代码 Owner、Router/Worker Session 实现和数据权威；Router、Worker、Compute 与 Recommendation 的实现分别在 `07`、`07B`、`07C`、`07D`、`07E–07F`。
4. `09–12B`：系统上下文、实际运行时边界、客户端宿主差异与 Salix 内部结构。
5. `13–14`：单写者约束与当前生产部署。注意逻辑边界不等于独立 Pod 或数据库实例。
7. `E` 前缀的图与 [`generated/inventory.md`](generated/inventory.md)：程序从源码提取的证据，用来复核人工抽象，而不是代替人工抽象。


也可以生成可离线查看的 HTML 和 PNG：

```sh
pnpm architecture:build
```

输出位于 `.preview/`，该目录只供本地查看，不提交仓库。

## 图的层次

- 产品概念图只回答“用户在什么范围内，与什么对象协作，这些对象如何组织”。这一层不出现模块、Actor 或数据库表。
- 概念实现图回答“稳定产品概念当前落到哪个记录、Owner 与 runtime contract”。映射不是概念定义本身。
- 运行时图回答“什么真正运行、通过什么边界通信”。OTP 应用不会因为源码分包就被画成微服务。
- 单写者图回答“谁有权改变资源”。放置、缓存、读模型和存储层不自动成为第二个 Owner。
- 部署图将逻辑数据所有权与物理部署分开。多个逻辑 Schema 可以由同一个 Cloud SQL 实例承载。
- `E` 后缀的图只陈述可机械提取的源码依赖、注册项和模板事实。源码依赖线不等于网络调用线。

## 材料结构

- [`model/landscape.c4`](model/landscape.c4)：人员、运行时、系统边界、数据边界和外部依赖。
- [`PRODUCT_MODEL.md`](PRODUCT_MODEL.md)：产品词汇、cardinality、Task/Single Session 语义和代码锚点。
- [`model/concepts.c4`](model/concepts.c4)：产品概念、跨产品命名、概念实现映射、权威数据与单写者约束。
- [`model/deployment.c4`](model/deployment.c4)：当前 Helm 部署形态。
- [`model/views.c4`](model/views.c4)：面向读者组织的静态视图与动态路径。
- [`generated/inventory.md`](generated/inventory.md)：程序生成、可追溯到源文件的事实清单。
- [`AI_REVIEW.md`](AI_REVIEW.md)：本轮独立架构师 Agent 的发现、修正和证据边界。
- [`scripts/generate-inventory.mjs`](scripts/generate-inventory.mjs)：事实提取器；不解析业务语义。

## 更新方式

相关代码变化后先运行：

```sh
pnpm architecture:validate
```

它会重建事实清单和实现链接，并校验整个 LikeC4 模型。实现链接不再通过源码字符串或测试名称断言来验证。随后必须由独立的架构师 Agent 阅读相关生产代码和直接测试，检查：

- 产品概念、cardinality 与 chat-ready 等生命周期条件；
- Task 唯一 Conversation status、 exact-version 人工接受；
- Message sender、Participant target、Session Owner 与唯一 mutation path；
- 控制面显式重新指定 Group Router、Worker delegator、Provider ingress 等入口例外；
- 图是否能让第一次阅读者区分产品事实、可见 Conversation 与 runtime transcript。

架构师 Agent 按 blocker / important / suggestion 输出结论；blocker 修正并复核前，不把模型标为语义收敛。普通生成 Agent 负责生成、定位代码和落实修正，但不能用自己的自检代替独立架构评审。LikeC4 校验只检查模型结构。实现与测试链接供人工复核，不证明产品语义或测试通过。

## 当前态与待办边界

LikeC4 模型只陈述当前代码、持久化约束和直接测试支持的已实现事实。部署图还需核对生产配置。未实现内容和剩余验收点记录在对应领域文档及关联 issue/PR 中，不作为 planned 节点进入生产拓扑。`finished/` 中的历史 RFC 不能单独证明当前实现。

发布迁移遵循根 [AGENTS.md](../../AGENTS.md#release-convergence-and-migrations)。

生成物受版本控制且可确定性重建，但本原型尚未接入 CI 强制新鲜度；现阶段优先验证信息层次和阅读体验。

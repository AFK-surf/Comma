# 消息搜索运行时验证（2026-09-06）

此报告记录 [消息搜索实现](../../../../../docs/salix/message-search-target.md) 的本地运行时实验，不作为当前部署状态或制品选择依据；主线发布和环境验收见对应 PR 与发布控制器。新增 group 数据域的全历史关键词/语义/混合搜索、完整媒体组件、源与发布失效协议；原消息表保留 8192 粒度，只增加同行写入 ID，两张独立搜索表使用 2048 粒度和 16 个固定 tenant 分桶。

## 测量范围

- 本地 ClickHouse 26.4.5.143 与 26.8.2.7，分别独立运行，容器限制为 **2 CPU / 4 GiB**。查询仍限制为 **128 MiB / 1 线程 / 2 秒**，没有借诊断参考查询的 512 MiB 上限提高运行时预算。
- 118,729 条消息、118,724 条 payload、118,729 条词法文档、83,145 条组件行，合计 **102,646 个 256 维向量单元**。文件组件 2,404 个，含 21,905 个单元。后续不可变 packet 重放可增加物理行数，逻辑数据不变。
- 日数量、频道数量、单条索引单元数分布来自已打包的 staging 汇总；消息正文、向量、日内时间、ID、group 分配均为合成数据。原 tenant 的 workspace 都赋给同一个合成 group，是较大的查询范围，**不是实际 group ACL 重建**。共 41 个源频道；有向量的主测试 tenant 含 39 个源频道、118,721 条消息。
- 实际路径：`Provider.call_api → MessageSearch → ClickHouse 排名 → canonical ID → PostgreSQL publication/file/pending → 当前 GroupDirectory/ProviderConnects → 片段/分页`。本地 HTTP encoder 返回合成向量，控制 owner 使用仓库 S3 Fake，PostgreSQL 为真实实例。
- 不覆盖真实 GPU、生产网络/S3 延迟、清空操作系统缓存的冷启动、语义理解质量、线上可用性 SLA。既有媒体提取/WeMM 验证是[历史证据](../../../../../docs/salix/slack-semantic-search.md)，不能移作新入口的端到端性能结果。

## 查询结果

每个模式分别做 40 个变化的 query，在并发 1 / 4 下调用整个入口；另测主 tenant 的 39 个频道过滤。每版本共 **279 个请求**，全部成功，全组请求每页均为 20 条不同来源消息。

| 版本 / P95 | keyword，C1 / C4 | semantic，C1 / C4 | hybrid，C1 / C4 |
| --- | --- | --- | --- |
| 26.4（最终 SQL） | 305 / 428 ms | 230 / 624 ms | 316 / 1019 ms |
| 26.8（最终 SQL） | 172 / 439 ms | 244 / 821 ms | 341 / 1001 ms |

最终语义排名峰值内存为 **26.4：72.6 MiB；26.8：100.0 MiB**，分别低于 128 MiB 上限。canonical 元数据单查询最多约 8.7 MiB 逻辑读量。

26.8 最终试验开始时，组件表仍有 **11 个 active parts**；没有预先 `OPTIMIZE FINAL`。原始逐请求数据和 `query_log` 统计分别见 [26.4](clickhouse-26.4.json.gz) 与 [26.8](clickhouse-26.8.json.gz)，包括开始/结束时间、物理布局和各阶段逻辑读取量。

发现并修复了一个实际容量问题：直接对多 part 的宽向量数组做 `FINAL` 时，26.8 的全部 160 个全组 semantic/hybrid 请求超出 128 MiB。现在先用窄 `FINAL` 选择当前 build ID，再读不可变完整数组并按来源归并。这个改动不依赖合并速度、不增加第二套发布权威、不提高内存上限。保留[失败记录](before-narrow-final-26.8.json.gz)，可与最终通过记录比较。

当前组件行与每个 connect 的 Top-N 预归并均保持精确排名：参考查询恢复宽向量 `FINAL`，取消每个 connect 的截断，做一次全局聚合/排序。每版取 10 个 N=100 和 10 个 N=200 的真实 SQL，逐行比较 3,000 个结果，包含定位和距离。参考单独允许 512 MiB，运行时仍是 128 MiB。见 [26.4 oracle](rank-oracle-26.4.json)、[26.8 oracle](rank-oracle-26.8.json)。这验证 SQL 等价性，不是模型检索质量或 ANN recall 评估。

## 对普通读取和写入的影响

[26.8 相邻读取实验](ordinary-reader-26.8.json)通过原 `SlackMirror.Reader.history` 连续读取同一 20 条消息：40 次基线与 40 次重叠读取的完整结果一致。重叠负载为 20 次 hybrid 搜索及 40 批 × 20 行完整索引 packet 重放，包含后台合并影响。最终一轮历史读取 P95 从 **25.8 ms 到 49.6 ms**，最大 52.8 ms，所有调用成功。它是有界单组负载，不是生产吞吐/零干扰承诺。

[正文放大实验](metadata-io-26.4.json)只复制本任务的合成 canonical 表，文本扩大十倍、payload 保持合法 JSON，其余元数据相同；比较实际 `current_sources` SQL 返回的 200 条 ID。两个表的总正文字节分别由约 261 MB 增至 2.62 GB，返回元数据完全一致，逻辑读取仍为数 MiB。正常表与复制表的 parts/mark 命中不同，**不能把两者读量差当成固定加速比**；结果只证明窄校验没有随全文大小读取正文。复制表随后删除。

源写入增加 PG admission 与 16 字节同行 UUID，因此仍有写入、锁和共享资源成本。历史零 ID mutation 在应用层不搬运正文，但 Compact part 的底层 mutation 可能重写整 part。已在实际 staging **26.4.1.2212 / SharedReplacingMergeTree** 独立临时表验证 5000 个 UUID 字面量、零值约束、已有正文/版本不变、合并后的旧 packet 无效；[原始结果](cloud-source-identity.json)。4 行临时表已删除，线上 canonical 表没有修改。

## 正确性与既有行为

- 新入口 13 项真实 PG/CH 回归：实际 ImRouter 跨频道/全历史与同 group agent、长文本延续、Unicode 字面匹配、sender、重复 connect 来源归并、500-unit 视频分页、外组 cursor、撤销、同版本迟到 payload、已知文件修改/删除、初始化、history replay 不产生 Triage、10 秒请求中断和刷新页原子提交。文件用例还确认旧向量相似度更高时仍返回当前较低相似度的新构建。
- 既有搜索/队列 43 项、普通 Analytics 读取 46 项、IM mirror/backfill/serve 78 项、Store 29 项、工具/schema/policy 73 项、发布 manifest/plan/no-downtime 62 项通过。合计 [**344 个不同用例**](validation.json)；其中搜索/队列在 26.4 与 26.8 重复验证，不重复累计。需真实 GPU 的一个可选实验未运行。
- [54 个 TLA+ 配置](models.txt)符合预期：新源、完整行、文件、初始化、group、source lane 和 worker rollout 模型，以及既有 durable outbox、分页、安装发现和调度模型。正确配置通过，去掉约束的配置仍产生预期反例。rollout 的有限历史收敛显式假设全部 worker 最终升级、依赖恢复和公平扫描/执行。
- `make test-policy`、相关 Elixir 编译/格式、迁移清单验证、Python 语法检查和 `git diff --check` 通过。没有声称运行全部 systems/client 测试。

修改原测试的原因：队列断言从旧 scalar 索引/游标转为新完整组件/游标，仍断言 live 优先、救援、重启、取消和异常媒体；outbox 保留原字段，新增固定 ID 并检查持久重读相等；普通 CH 测试只改用已有测试 URL 环境变量；发布 inventory 数量随三个 expand migration 更新。阶段 A 的原 pending-edit fixture 补上真实规范化行始终携带的 `message_ts_us`，不改变产品行为。

本次实现首次完成时的工作树相对当时 base `be72136c3` 的生产源文件（`lib`、运行配置、迁移和运行 SQL）为 **+2,530 / −85 / 净 +2,445 行**，含本任务开始前已有的读取预算修复。该历史快照不包括后续同步 main 的同期工作；当前 PR 增删量以 PR 正文为准。测试、文档、TLA、benchmark 和发布元数据均未计入生产代码；[分类记录](change-size.json)。

## 分阶段制品与回滚

阶段 A 为 [PR #1471](https://github.com/AFK-surf/Comma/pull/1471) / **`codex/message-search-source-phase-a`**。本报告的历史制品记录为 `2ebacf922` / base `49737856f`；首次独立制品验证更早，基于 `d827df448` / base `be72136c3`。这些是复现实验的历史指针，不是当前部署选择。为保留 staging 已部署的 streaming / external-runtime 修复，发布候选现已同步 `628d4d4b5`；当前 reviewed head、CI 和部署状态以 PR 记录及发布控制器为准。A 包含在线 schema expand、源 owner admission/UUID、文件事件、历史重放及对应模型/manifest，保持原搜索读取和 worker。首次独立 worktree 编译通过；原搜索的 41 项用例通过（初次 40 项通过，补正 fixture 后失败项单独重跑通过），另 1 项真实 GPU 实验跳过。[历史 commit 与文件清单](phase-a.json)。

首次上线顺序：先把阶段 A 合并到 `main`，等待主线构建并部署该正式制品；通过既有发布控制器确认两个 serving Pod 和其它旧源 writer/file-event owner 已全部退出，再部署已经合并到 `main` 并由主线构建的阶段 B（[PR #1472](https://github.com/AFK-surf/Comma/pull/1472)）。staging 新发布和手动回滚都禁止选择未合并的 PR/功能分支制品；从 `main` 调度 workflow 或覆盖 image tag 不能替代主线合并。先前分支部署仅是历史记录，不构成后续发布许可。已经完整经过 A、当前运行 B 的环境，可以核对 live writer/schema 后在线替换为包含同一 A/B 实现的正式主线制品。A/B worker 共用原 Oban 队列，重叠期可能只更新旧投影，新入口因此缺少部分结果；周期全历史扫描在全部 worker 升级后恢复符合条件的内容。没有为重叠期增加双写、fallback、第二套队列或手动启用开关。

回滚先退回主线构建的 A 入口/worker 制品，完成后再考虑回滚更早的 writer；保留展开列与持久意图。历史分支 tag 不再是手动回滚选项。既有失败事务恢复还原发布前 serving snapshot；若恢复后仍运行历史分支制品，清理尚未完成。prod/production 的既有搜索禁用策略保持不变。完整约束见[发布协议](../../../../../docs/salix/message-search-publication.md)。本报告的本地实验不证明部署已完成；实际环境版本、完成状态和验收在 PR 与既有发布系统记录。

## 复跑

依赖：Docker、仓库的 Elixir/Mix 环境、本地测试 PostgreSQL、Python venv 中的 `requirements.lock`；导入生成的 CSV 时需 PostgreSQL 官方 `psql`。以下只对新建的本地测试数据库运行，名称不要替换成产品数据库。

从仓库根目录加载数据（端口按自己新建的测试容器调整）：

```sh
python3 -m venv /tmp/comma-message-search-venv
/tmp/comma-message-search-venv/bin/pip install -r devtools/search-capacity/requirements.lock
docker run -d --name comma-message-search-example --cpus 2 --memory 4g \
  -p 127.0.0.1:18126:8123 -e CLICKHOUSE_SKIP_USER_SETUP=1 clickhouse/clickhouse-server:26.8
/tmp/comma-message-search-venv/bin/python devtools/search-capacity/runtime_shape_load.py \
  --port 18126 --database message_search_runtime_example \
  --daily devtools/search-capacity/results/2026-09-06/daily-shape-inputs \
  --directory /tmp/comma-message-search-fixture
createdb -h 127.0.0.1 -p 15432 -U postgres salix_search_bench_example
```

先建立本任务的 PG migration，再导入 CSV（`psql` 认证沿用本机测试库设置）：

```sh
cd systems
SALIX_TEST_DB_PORT=15432 SALIX_TEST_DB=salix_search_bench_example \
  SALIX_TEST_CLICKHOUSE_URL=http://127.0.0.1:18126/ SEARCH_PROBE_INIT_ONLY=1 \
  ERL_FLAGS='+S 4' MIX_ENV=test mix do --app salix_analytics run --no-start \
  ../devtools/search-capacity/runtime_shape_probe.exs
psql -h 127.0.0.1 -p 15432 -U postgres -d salix_search_bench_example \
  -f /tmp/comma-message-search-fixture/pg-seed.sql
SALIX_TEST_DB_PORT=15432 SALIX_TEST_DB=salix_search_bench_example \
  SALIX_TEST_CLICKHOUSE_URL=http://127.0.0.1:18126/ \
  SEARCH_PROBE_DIRECTORY=/tmp/comma-message-search-fixture SEARCH_PROBE_NEIGHBOR=1 \
  ERL_FLAGS='+S 4' MIX_ENV=test mix do --app salix_analytics run --no-start \
  ../devtools/search-capacity/runtime_shape_probe.exs
```

`pg-seed.sql` 的 CSV NULL 规则保留空字符串，并将全局 build sequence 移到导入数据之后。脚本只在本地构造 owner/encoder；不要将其连接到线上 PG。运行时结果保存到 fixture 目录。

从仓库根目录核对排名和正文读取：

```sh
/tmp/comma-message-search-venv/bin/python devtools/search-capacity/runtime_rank_oracle.py \
  --port 18126 --database message_search_runtime_example --output /tmp/rank-oracle.json
/tmp/comma-message-search-venv/bin/python devtools/search-capacity/runtime_metadata_probe.py \
  --port 18126 --database message_search_runtime_example --output /tmp/metadata-io.json
```

功能回归使用另一新建 PG 测试库（不要用 benchmark 库，测试会清空自己的搜索元数据）：

```sh
createdb -h 127.0.0.1 -p 15432 -U postgres salix_search_test_example
cd systems
SALIX_TEST_DB_PORT=15432 SALIX_TEST_DB=salix_search_test_example \
  SALIX_TEST_CLICKHOUSE_URL=http://127.0.0.1:18126/ \
  ERL_FLAGS='+S 4' MIX_ENV=test mix do --app salix_analytics test --no-start \
  test/slack_message_search_test.exs test/slack_semantic_index_test.exs --include clickhouse
```

TLA+ 从 `tla/salix` 运行 `check.sh`，传入 `MessageSearch*.cfg` 去除 `.cfg` 后的配置名；仓库完整 TLA gate 已登记这些模型。新增 `.tla` 的参数、故障/公平性条件及代码锚点都在模型与[发布协议](../../../../../docs/salix/message-search-publication.md)中。

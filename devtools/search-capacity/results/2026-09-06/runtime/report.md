# 消息搜索运行时验证（2026-09-06）

本地运行时实验，目标设计见 [docs/storage-search.md](../../../../../docs/storage-search.md)。不作为部署状态或制品选择依据。范围：group 数据域的全历史关键词/语义/混合搜索、完整媒体组件、源与发布失效协议。原消息表保留 8192 粒度，只增加同行写入 ID。两张独立搜索表使用 2048 粒度和 16 个固定 tenant 分桶。

## 测量范围

- 本地 ClickHouse 26.4.5.143 与 26.8.2.7，分别运行，容器 **2 CPU / 4 GiB**。查询限制 **128 MiB / 1 线程 / 2 秒**。
- 118,729 条消息、118,724 条 payload、118,729 条词法文档、83,145 条组件行，共 **102,646 个 256 维向量单元**。文件组件 2,404 个，含 21,905 个单元。
- 日数量、频道数量和单条单元数分布来自 staging 汇总。正文、向量、日内时间、ID、group 分配都是合成的。所有 workspace 赋给同一个合成 group，**不是实际 group ACL 重建**。共 41 个源频道。主测试 tenant 含 39 个频道、118,721 条消息。
- 路径：`Provider.call_api → MessageSearch → ClickHouse 排名 → canonical ID → PostgreSQL publication/file/pending → GroupDirectory/ProviderConnects → 片段/分页`。encoder 返回合成向量，S3 为仓库 Fake，PostgreSQL 为真实实例。
- 不覆盖真实 GPU、生产网络/S3 延迟、冷启动、语义质量、线上 SLA。

## 查询结果

每个模式 40 个不同 query，并发 1 / 4 调用整个入口，另测主 tenant 的 39 个频道过滤。每版本 **279 个请求**，全部成功，每页 20 条不同来源消息。

| 版本 / P95 | keyword，C1 / C4 | semantic，C1 / C4 | hybrid，C1 / C4 |
| --- | --- | --- | --- |
| 26.4（最终 SQL） | 305 / 428 ms | 230 / 624 ms | 316 / 1019 ms |
| 26.8（最终 SQL） | 172 / 439 ms | 244 / 821 ms | 341 / 1001 ms |

语义排名峰值内存 **26.4：72.6 MiB，26.8：100.0 MiB**。canonical 元数据单查询最多约 8.7 MiB 逻辑读量。26.8 开始时组件表有 **11 个 active parts**，没有预先 `OPTIMIZE FINAL`。原始数据见 [26.4](clickhouse-26.4.json.gz) 与 [26.8](clickhouse-26.8.json.gz)。

修复的容量问题：对多 part 宽向量数组直接 `FINAL` 时，26.8 的全部 160 个全组 semantic/hybrid 请求超出 128 MiB。现在先用窄 `FINAL` 选当前 build ID，再读不可变完整数组并按来源归并。不提高内存上限。[失败记录](before-narrow-final-26.8.json.gz)。

排名精确性：参考查询用宽向量 `FINAL`、不截断、一次全局排序，单独允许 512 MiB。每版 20 个真实 SQL（N=100 和 N=200 各 10 个），逐行比较 3,000 个结果，含定位和距离。见 [26.4 oracle](rank-oracle-26.4.json)、[26.8 oracle](rank-oracle-26.8.json)。这验证 SQL 等价性，不是 recall 评估。

## 对普通读取和写入的影响

- [相邻读取](ordinary-reader-26.8.json)：`SlackMirror.Reader.history` 读同一 20 条消息，40 次基线与 40 次重叠读取结果一致。重叠负载为 20 次 hybrid 搜索和 40 批 × 20 行 packet 重放。历史读取 P95 从 **25.8 ms 到 49.6 ms**，最大 52.8 ms。这不是零干扰承诺。
- [正文放大](metadata-io-26.4.json)：正文扩大十倍（约 261 MB 到 2.62 GB），`current_sources` 返回的 200 条元数据一致，逻辑读取仍为数 MiB。窄校验不随正文大小读取正文。
- 源写入增加 PG admission 与 16 字节同行 UUID。Compact part 的底层 mutation 可能重写整 part。已在 staging **26.4.1.2212 / SharedReplacingMergeTree** 独立临时表验证 5000 个 UUID 字面量、零值约束、正文/版本不变、合并后旧 packet 无效（[原始结果](cloud-source-identity.json)）。临时表已删除，线上 canonical 表未修改。

## 验证记录

用例清单见 [validation.json](validation.json)，模型清单见 [models.txt](models.txt)，变更量见 [change-size.json](change-size.json)。需真实 GPU 的可选实验未运行。

## 分阶段制品与回滚

阶段 A 为 [PR #1471](https://github.com/AFK-surf/Comma/pull/1471)（`codex/message-search-source-phase-a`），阶段 B 为 [PR #1472](https://github.com/AFK-surf/Comma/pull/1472)。[历史 commit 与文件清单](phase-a.json) 只用于复现实验，不是部署选择。当前 head、CI 和部署状态以 PR 与发布控制器为准。A 包含在线 schema expand、源 owner admission/UUID、文件事件和历史重放，保持原搜索读取和 worker。

首次上线顺序：

1. 把阶段 A 合并到 `main`，部署主线构建的制品。
2. 通过发布控制器确认两个 serving Pod 和其它旧源 writer/file-event owner 已全部退出。
3. 部署已合并到 `main` 并由主线构建的阶段 B。

staging 新发布和手动回滚都禁止使用未合并的 PR 或功能分支制品。从 `main` 调度 workflow 或覆盖 image tag 不能替代主线合并。已完整经过 A 且正在运行 B 的环境，可核对 live writer/schema 后替换为包含同一 A/B 实现的主线制品。A/B worker 共用原 Oban 队列，重叠期新入口可能缺少部分结果。全部 worker 升级后，周期全历史扫描会补回。没有双写、fallback、第二套队列或手动开关。

回滚：先退回主线构建的 A 入口/worker 制品，再考虑回滚更早的 writer。保留展开列与持久意图。历史分支 tag 不是回滚选项。失败事务恢复会还原发布前 serving snapshot。若恢复后仍运行历史分支制品，清理尚未完成。prod 的搜索禁用策略不变。完整约束见[发布协议](../../../../../docs/storage-search.md#message-search-publication)。

## 复跑

依赖：Docker、仓库的 Elixir/Mix 环境、本地测试 PostgreSQL、`requirements.lock`、PostgreSQL `psql`。只对新建的本地测试数据库运行，不要换成产品数据库。

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

先建立 PG migration，再导入 CSV：

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

脚本只在本地构造 owner/encoder。不要连接线上 PG。结果保存到 fixture 目录。

从仓库根目录核对排名和正文读取：

```sh
/tmp/comma-message-search-venv/bin/python devtools/search-capacity/runtime_rank_oracle.py \
  --port 18126 --database message_search_runtime_example --output /tmp/rank-oracle.json
/tmp/comma-message-search-venv/bin/python devtools/search-capacity/runtime_metadata_probe.py \
  --port 18126 --database message_search_runtime_example --output /tmp/metadata-io.json
```

功能回归使用另一个新建 PG 测试库。不要用 benchmark 库，测试会清空搜索元数据：

```sh
createdb -h 127.0.0.1 -p 15432 -U postgres salix_search_test_example
cd systems
SALIX_TEST_DB_PORT=15432 SALIX_TEST_DB=salix_search_test_example \
  SALIX_TEST_CLICKHOUSE_URL=http://127.0.0.1:18126/ \
  ERL_FLAGS='+S 4' MIX_ENV=test mix do --app salix_analytics test --no-start \
  test/slack_message_search_test.exs test/slack_semantic_index_test.exs --include clickhouse
```

`tla/salix` 中目前没有 `MessageSearch*` 模型，[models.txt](models.txt) 只是当时的记录。

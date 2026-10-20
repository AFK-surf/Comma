# 搜索读取行数：优化验证

2026-09-06。staging 只读诊断，物理布局对照在独立本地 ClickHouse 中完成。

**缩小物理读取粒度能显著减少读取行数。单改 CTE 没有收益。**

## staging 的成本来源

近期繁忙频道、60 天范围、同一查询向量：完整 SQL 读取 **83,575 行、180,503,807 B**，返回 20 个候选。诊断临时允许 200,000 行，应用的 65,536 行预算未改。

| 部分 | 逻辑记录 | 数据库读取行数 | 读取字节 |
| --- | ---: | ---: | ---: |
| 消息与 payload 合并、当前正文/附件引用读取 | 12,906 条消息 | 57,545 | 112,228,164 |
| 文本与附件索引扫描 | 8,305 条索引记录 | 26,218 | 67,130,890 |

约 69% 的读取行数来自原文状态读取。拆分与完整查询不在同一时刻，不是一致快照。

## 已排除的 SQL 改写

| SQL 变体 | 读取行数 | 结果与原 SQL 一致 |
| --- | ---: | --- |
| 原 SQL | 83,575 | 基准 |
| 物化原文状态 CTE | 83,576 | 是 |
| 物化索引内容 CTE | 83,576 | 是 |
| 两个 CTE 都物化 | 83,576 | 是 |
| 物化后用已有索引消息键过滤原文状态 | 108,164 | 是 |

物化语法见 [ClickHouse 26.3 发布说明](https://clickhouse.com/blog/clickhouse-release-26-03)。

## 有效对照：读取粒度

本地 ClickHouse 26.4.5.143，2 核 / 4 GiB。三套独立数据库：相同 SQL、120,000 条合成文字消息、40 个频道、66,047 条文本索引记录、60 天窗口，附件索引为空。`index_granularity_bytes=10 MiB` 不变，只改 `index_granularity`。所有变体的 20 条结果与基准相同。

### 与 staging 相同的 Compact 类型

| 创建表时的行粒度上界 | 实际读取行数 | 读取字节 | 65,536 行应用预算 |
| ---: | ---: | ---: | --- |
| 8,192 | 69,308 | 122,902,306 | 失败，Code 158 |
| 2,048 | 26,624 | 45,092,422 | 通过 |
| 1,024 | 15,360 | 26,699,204 | 通过 |

1,024 比 8,192 少读 **77.8% 的行和 78.3% 的字节**，磁盘占用增加约 1.8%。自动布局也从 69,308 行降到 15,360 行，字节从 42,245,692 B 降到 21,582,752 B。

本实验没有验证真实向量质量、写入吞吐或合并成本。

## 落地约束与建议

ClickHouse 26.4 的 `ALTER TABLE ... MODIFY SETTING index_granularity` 和 `index_granularity_bytes` 都返回 `READONLY_SETTING`。不能在线改设置让现有数据获益。

目标设计见 [docs/storage-search.md](../../../../docs/storage-search.md)。

1. 决定：采用 2,048 粒度。本实验同时调整两张 canonical 消息表和两张派生索引表。只改派生表时，不能直接沿用这里的收益。新表上线前测量写入与合并代价。
2. 检索层决定有界候选，再按[发布协议](../../../../docs/storage-search.md#message-search-publication)验证当前来源。保留版本、删除、同版本内容变化和 group/connect 授权检查。不能用未校验的前 20 个片段替代消息结果。
3. 新表和索引用在线回填与发布。不能原地停服重建。不为此向完整消息表添加检索物化列。
4. 用真实 staging 向量和完整入口验证回填后的召回、预算与并发，再重评 30/60/90 天边界。

## 复跑与证据

[原始测量](row-read-optimization-data.json)、[被测 SQL](row-read-baseline.sql)、[实验脚本](../../row_layout_probe.py)。只用全新的本地 ClickHouse 26.4 容器：

```sh
python devtools/search-capacity/row_layout_probe.py --port PORT --layout Compact \
  --query devtools/search-capacity/results/2026-09-06/row-read-baseline.sql \
  --output /tmp/row-layout-results.json
```

依赖见 [README](../../README.md)。脚本创建 `row_layout_probe_` 开头的数据库。不要指向线上服务。

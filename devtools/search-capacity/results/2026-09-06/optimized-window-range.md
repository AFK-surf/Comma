# 细粒度布局后的搜索范围

2026-09-06。建议优化后的单频道查询按 **60 天常用、90 天扩展**规划。不要据此开放半年或全年。

这是本地读取预算模拟，不是线上能力。输入是 staging 当天 16:07:47 至 16:07:48（Asia/Shanghai）的按天、按频道统计。日内时间、版本、正文、文件清单和向量值都是合成的。

决定：采用 2,048 粒度。本实验同时调整 `slack_messages`、`slack_message_payloads`、`slack_semantic_documents` 和 `slack_semantic_files` 四张表。代码中只有两张新搜索表（`slack_message_search_components`、`slack_message_search_documents`）使用 2,048，这四张表未改。所以不能直接沿用这里的通过范围。选择该粒度不等于上线 60/90 天的产品窗口。

## 窗口结果

对 37 个已有语义索引的频道重放相同 SQL。预算：65,536 行、256 MiB 读取、128 MiB 查询内存、1 线程、2 秒，最多 20 个候选。每条件单次、顺序执行，不是生产 P95。

| 时间跨度 | 2,048 粒度：预算通过频道数 | 1,024 粒度：预算通过频道数 |
| --- | ---: | ---: |
| 30 天 | 37 / 37 | 37 / 37 |
| 60 天 | 37 / 37 | 37 / 37 |
| 90 天 | 37 / 37 | 37 / 37 |
| 180 天 | 34 / 37 | 36 / 37 |
| 365 天，覆盖当前约 328 天历史 | 30 / 37 | 35 / 37 |

失败都是读取行数超限。1,024 的全年失败点是历史最多的两个频道（约 26,853 和 21,222 条消息）。

| 范围 | 2,048 最大读取行数 | 1,024 最大读取行数 |
| --- | ---: | ---: |
| 30 天 | 36,100 | 31,087 |
| 60 天 | 53,315 | 44,666 |
| 90 天 | 63,218 | 52,545 |

90 天时，2,048 用了约 96.5% 的行预算，1,024 约 80.2%。若需稳定覆盖 90 天，优先考虑 1,024。若以 60 天为主，2,048 留有约 18.6% 余量，维护开销更低。这些是规划建议，仍需真实新表验证。

## 数据与模拟边界

输入：118,729 条源记录（含删除）、118,724 条 payload、65,447 条文本索引记录、2,404 条文件索引记录。已索引单元为文本 80,741 加附件 21,905，共 102,646。这与当天较早的 91,541 单元快照不是同一时刻。

模型保留每个租户/工作区/频道/日期的记录数和每种向量数量的记录数。分区布局、正文大小、版本历史、文件复用和向量质量都没有复制。不能据此承诺线上延迟。

**索引覆盖尚未完成。** 索引补齐和数据增长后，必须重新验收读取范围。

本轮只测单频道读取，不是 group 跨频道搜索。跨频道、全历史能力见[目标设计](../../../../docs/storage-search.md)，需用真实向量和完整授权、发布链路验证。

## 证据与复跑

[逐请求结果](shape-window-results.json)、[聚合输入及时间基准](daily-shape-inputs/manifest.json)、[模拟脚本](../../shape_window_probe.py)。聚合输入的四个 `.json.gz` 为 JSONCompactEachRow：源表是 `[tenant, workspace, channel, date, count, deleted_count]`，payload 表去掉最后一项，索引表是 `[tenant, workspace, channel, date, units_per_record, record_count]`。

先用[粒度对照脚本](../../row_layout_probe.py)在同一全新本地容器中准备 Compact 模板表，再运行：

```sh
python devtools/search-capacity/shape_window_probe.py --port PORT --daily \
  --metadata devtools/search-capacity/results/2026-09-06/daily-shape-inputs \
  --query devtools/search-capacity/results/2026-09-06/row-read-baseline.sql \
  --granularity 2048 --output /tmp/window-2048.json
```

1,024 另建本地数据库，替换粒度和输出文件名。只指向独立本地测试实例。

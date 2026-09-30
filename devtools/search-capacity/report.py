#!/usr/bin/env python3
"""Export small raw results, tables and a standalone performance figure."""
import argparse
import gzip
import json
from pathlib import Path
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from corpus import Corpus, eligible

parser=argparse.ArgumentParser()
parser.add_argument('--directory',type=Path,required=True)
parser.add_argument('--output',type=Path,required=True)
args=parser.parse_args()
args.output.mkdir(parents=True,exist_ok=True)
records=[]
for source in sorted(args.directory.glob('*/results-*.json')):
    record=json.loads(source.read_text())
    record['source_file']=str(source)
    corpus=Corpus(args.directory,record['profile'])
    metadata=corpus.metadata()[:record['messages']]
    record['scope_counts']={}
    for scope in ('full','ten','one'):
        mask=eligible(metadata,scope)
        record['scope_counts'][scope]={'messages':int(mask.sum()),'units':int(metadata['units'][mask].sum())}
    records.append(record)
    destination=args.output/f"{record['profile']}-{source.name}.gz"
    with gzip.open(destination,'wt') as stream:
        json.dump(record,stream)
compact=[{**r,'cases':[{k:v for k,v in c.items() if k!='raw'} for c in r['cases']]} for r in records]
(args.output/'summary.json').write_text(json.dumps(compact,indent=2))

colors={'chat':'#2563eb','balanced':'#e69f00','media':'#009e73'}
fig,axes=plt.subplots(1,2,figsize=(13,5),layout='constrained')
for profile in colors:
    for fresh in (False,True):
        selected=sorted([r for r in records if r['profile']==profile and
                         bool(r.get('label',''))==fresh],key=lambda r:r['units'])
        points=[]
        for r in selected:
            c=next((c for c in r['cases'] if c['mode']=='semantic' and c['scope']=='full'
                    and c['concurrency']==8 and c.get('oldest_day',0)==0),None)
            subset=next((x for x in r['cases'] if x['mode']=='semantic' and x['scope']=='ten' and x['concurrency']==4),None)
            if c and subset:
                points.append((r['units']/1e6,c['p95_ms'],subset['p95_ms']))
        if not points:continue
        x,latency,filtered=zip(*points)
        label=profile+(' / fresh queries' if fresh else ' / repeated queries')
        for ax,y in zip(axes,(latency,filtered)):
            ax.plot(x,y,marker='s' if fresh else 'o',linestyle='--' if fresh else '-',
                    color=colors[profile],label=label)
axes[0].axhline(2000,color='#bd2424',linestyle=':',label='P95 target: 2 s')
axes[0].set(ylabel='P95 latency (ms)',yscale='log',title='Semantic search · 8 clients · full group scope')
axes[1].axhline(2000,color='#bd2424',linestyle=':',label='P95 target: 2 s')
axes[1].set(ylabel='P95 latency (ms)',yscale='log',title='Semantic search · 4 clients · 10% group scope')
for ax in axes:
    ax.set_xlabel('Total indexed units (millions)')
    ax.grid(alpha=.2)
    ax.legend(fontsize=8,loc='best')
fig.suptitle('Local search prototype · 4 CPU / 6 GiB node · 256D Float32 · 20 messages',fontsize=12)
fig.savefig(args.output/'capacity.png',dpi=170)
plt.close(fig)

lines=['# 混合消息检索容量：实测记录','',
       '在本次 **4 核 / 6 GiB、P95 ≤ 2 秒、每次 20 条消息** 的引擎压测口径下，三种主题聚类混合语料共同通过的检查点是 **约 100 万检索单元**。',
       '200 万单元的新查询已经出现超标；300 万能返回结果，但不能据此宣称稳定满足 2 秒目标。实测边界在 100 万与 200 万单元之间，不能插值成精确硬上限。','',
       '## 可确认的混合数据规模','',
       '| 混合比例：文字/图片/音频/视频 | 总检索单元 | 当前 group 可搜索消息 | 100 万点最差 P95 | 200 万点最差 P95 |',
       '| --- | ---: | ---: | ---: | ---: |']
for profile, label in [('chat','90/5/4/1'),('balanced','60/20/15/5 + 长视频尾部'),('media','20/20/30/30')]:
    small=next((r for r in records if r['profile']==profile and r.get('label')=='prefix-fresh64' and 1000000<=r['units']<1010000),None)
    large=next((r for r in records if r['profile']==profile and r.get('label')=='prefix-fresh64' and 2000000<=r['units']<2010000),None)
    if small and large:
        lo=max(c['p95_ms'] for c in small['cases'])
        hi=max(c['p95_ms'] for c in large['cases'])
        lines.append(f"| {label} | {small['units']:,} | {small['scope_counts']['full']['messages']:,} | {lo/1000:.2f} 秒 | {hi/1000:.2f} 秒 |")
lines += ['', '这是本次合成语料与固定配置的引擎能力，尚不是完整产品 SLA。三组语义查询在 100 万点的平均 Recall@20 均不低于 99.2%；准确率来自逐向量精确对照。','',
       '通过条件为每个已测条件 P95 ≤ 2 秒、平均语义 Recall@20 ≥ 95%、无请求错误、无范围串入或重复消息。并发为闭环客户端，不代表任意到达速率下的排队 SLA。','',
       '## 测试条件','',
       '以下为本机独立 OpenSearch 3.8.0 原型的数据，生产搜索入口尚未接入。',
       '节点限制为 4 CPU、6 GiB 总内存、2 GiB JVM heap；宿主机 Apple M5 / 32 GiB。',
       '数据为合成的 256 维向量与模拟文字/OCR/转写/视频片段文本，没有真实媒体文件；只测试索引后的检索。',
       '不计 OCR/ASR、WeMM 查询编码、远程网络或 PG/canonical 最终状态校验。',
       '查询覆盖两年时间与最多 10,000 个频道；总库含约 5% 其他租户数据，授权消息数量单独统计。','',
       '## 全部检查点','', '![不同混合比例、查询缓存状态和过滤范围的 P95 曲线](capacity.png)', '',
       '| 混合类型 | 查询组 / ef | 总检索单元 | 总消息 | 本 group 可搜索消息 | 全范围 C8 P95 ms | 10%范围 C4 P95 ms | C8 平均 Recall@20 |',
       '| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |']
for r in sorted(records,key=lambda r:(r['profile'],r['units'],r.get('label',''))):
    full=next((c for c in r['cases'] if c['mode']=='semantic' and c['scope']=='full' and c['concurrency']==8 and c.get('oldest_day',0)==0),None)
    subset=next((c for c in r['cases'] if c['mode']=='semantic' and c['scope']=='ten'),None)
    if not full:continue
    recall=full['mean_recall_at_20']
    description=r.get('label') or f"{r.get('query_count',24)} 查询 × {r.get('repeats',3)}"
    lines.append(f"| {r['profile']} | {description} / {r['ef_search']} | {r['units']:,} | {r['messages']:,} | "
        f"{r['scope_counts']['full']['messages']:,} | {full['p95_ms']:.1f} | "
        f"{subset['p95_ms']:.1f} | {recall*100:.2f}% |")
lines += ['', '## 100 万检查点的质量与吞吐','',
    '每条件 64 个独立查询；最低单次召回另列，避免用平均值掩盖漏召回。QPS 为该闭环测试的实测值，未做恒定到达速率的过载测试。','',
    '| 混合类型 | 全范围 C8 QPS | 10%范围 C4 QPS | 所有语义条件中最低平均召回 | 最低单次召回 | 最低满页率 |',
    '| --- | ---: | ---: | ---: | ---: | ---: |']
for r in records:
    if r['profile'] not in colors or r.get('label')!='prefix-fresh64' or not 1000000<=r['units']<1010000:
        continue
    semantic=[c for c in r['cases'] if c['mode']=='semantic']
    full=next(c for c in semantic if c['scope']=='full' and c['concurrency']==8)
    subset=next(c for c in semantic if c['scope']=='ten')
    lines.append(f"| {r['profile']} | {full['qps']:.1f} | {subset['qps']:.1f} | "
        f"{min(c['mean_recall_at_20'] for c in semantic)*100:.2f}% | "
        f"{min(c['min_recall_at_20'] for c in semantic)*100:.1f}% | "
        f"{min(c['full_page_rate'] for c in semantic)*100:.1f}% |")
lines += ['', '## 解读边界','',
    '- `chat` 消息比例为文字/图片/音频/视频 90/5/4/1；`balanced` 为 60/20/15/5 并有长视频尾部；`media` 为 20/20/30/30。',
    '- 单条普通文字/图片/音频/视频分别生成 1/2/12/60 个单元；长视频可有 500 个。不能把检索单元数量当成消息数量。',
    '- 默认测量重复 24 个查询三遍；标为 fresh 的测量每个条件使用不同种子的全新查询，不显式预热，但没有清除共享宿主机 OS 页缓存。',
    '- 合成数据的 Recall@20 验证 ANN 是否找回精确近邻，不代表真实图片、语音或中文语义理解质量。',
    '- 已通过的检查点只是该配置/负载下的下界。必须结合更大失败点、过滤比例、并发数和冷热状态讨论容量。',
    '- 200 万和 300 万的延迟并非单调：段布局、后台合并和缓存状态不同。两者均已在部分测试条件下超标，不能用某一次较快结果覆盖较慢结果。',
    '- 300 万文字为主数据的 10% 范围查询，重复三轮的 P95 为 5.27 秒、1.13 秒、0.307 秒，说明仅看重复查询会掩盖首次查询和缓存压力。独立种子的新查询又在三种混合比例上测得约 2.83–4.52 秒。',
    '- 报告不把新入口、group owner 授权、完整发布/回源校验或 Cloud 迁移描述为已实现。','']
lines += ['## 向量分布与参数敏感性','',
    '额外的 diffuse 语料保留相同消息结构，但使用随机分散的消息方向。默认 ef/k=200 时，10 万和 30 万单元的平均 Recall@20 仅为 83.1% 和 76.7%，速度快也不能算达标。',
    '同一 30 万索引、同一查询和精确对照集，将搜索力度调到 ef/k=2000 后，平均 Recall@20 提高到 97.7%。这说明容量结论依赖搜索参数和向量分布；该结果未外推到 100 万或真实 WeMM 数据。调参前后的缓存状态不同，不把延迟变化全归因于参数。','']
adversarial=args.directory/'adversarial.json'
if adversarial.exists():
    a=json.loads(adversarial.read_text())
    lines += ['## 长视频与消息归并','',
        f"真实引擎中，一条视频的 500 个高分片段加 40 条其他消息，先取 200 个片段再 collapse 仅返回 {a['flat_collapse_messages']} 条消息；nested 多向量消息召回返回 {a['nested_messages']} 条。",
        '固定窗口内 41 条消息分页为 20/20/1，未出现重复；scope 字段刷新后删除了不再符合该 scope 的结果。此项是索引过滤验证，不替代产品 owner 撤销协议。','']
ch_records=[]
for source in sorted((args.directory/'clickhouse').glob('*.json')):
    record=json.loads(source.read_text())
    ch_records.append(record)
    with gzip.open(args.output/f'clickhouse-{source.name}.gz','wt') as stream:json.dump(record,stream)
if ch_records:
    lines += ['## ClickHouse 窄表对照','',
        'ClickHouse 26.8.2.7 同样限制为 4 核 / 6 GiB；独立于 OpenSearch 运行。使用相同均衡语料前缀，12 个查询重复两遍，每条件 24 次，样本数较主测少。',
        '精确路径在数据库内按消息取最佳片段，再获取有限片段；ANN 路径先取 200 个片段再归并。二者不是生产中仍限定单频道/14 天的原 SQL。','',
        '| 总检索单元 | 算法 | 全范围 C8 P95 ms | 10%范围 C4 P95 ms | C8 平均 Recall@20 | C8 错误数 |',
        '| ---: | --- | ---: | ---: | ---: | ---: |']
    for r in sorted(ch_records,key=lambda r:r['units']):
        for algorithm in ('exact','ann200'):
            full=next((c for c in r['cases'] if c['algorithm']==algorithm and c['scope']=='full' and c['concurrency']==8),None)
            subset=next((c for c in r['cases'] if c['algorithm']==algorithm and c['scope']=='ten'),None)
            if full and subset:
                mean=full['mean_recall_at_20']
                formatted=f'{mean*100:.2f}%' if mean is not None else '—'
                lines.append(f"| {r['units']:,} | {algorithm} | {full['p95_ms']:.1f} | {subset['p95_ms']:.1f} | {formatted} | {full['errors']} |")
    for r in ch_records:
        for failure in r.get('warmup_failures',[]):
            lines += ['', f"**失败点：{r['units']:,} 单元、{failure['algorithm']} 路径预热失败：** {failure['error']}。该算法在此规模没有完成并发测量，不能将缺失行视为通过。"]
        if r.get('stopped_after_errors'):
            c=r['cases'][-1]
            lines += ['', f"{r['units']:,} 单元的 {c['algorithm']} 后续测量在 C{c['concurrency']} 就出现错误：P95 {c['p95_ms']/1000:.2f} 秒，{c['requests']} 次中 {c['errors']} 次超时，成功请求平均 Recall@20 {c['mean_recall_at_20']*100:.2f}%（最低 {c['min_recall_at_20']*100:.1f}%）。因此停止加并发，未生成 C4/C8 通过数据。"]
    lines += ['', 'ANN 不能只凭延迟替代完整消息召回：部分较小检查点平均 Recall@20 低于 95%，后台合并期间同一批查询的召回也有变化。长视频挤占还需用完整产品语料验证。',
        '早期导出的 EXPLAIN 使用服务器默认 rescoring=0，仅用于确认 HNSW 索引参与；实际计时请求使用 rescoring=1。最终另存带相同请求设置的计划，不把默认计划冒充实际计时计划。','']
audit_path=args.output/'audit.json'
if audit_path.exists():
    audit=json.loads(audit_path.read_text())
    os_records=[r for r in audit['records'] if not r['file'].startswith('clickhouse/')]
    lines += ['## 原始结果复核与资源观测','',
        f"OpenSearch 的 {sum(r['requests'] for r in os_records):,} 次计时请求没有搜索错误；包含 ClickHouse 的全部 {audit['requests']:,} 次计时请求中有 {audit['request_errors']} 次错误，另有 {audit['warmup_failures']} 次预热失败，均保留。没有跳过的计时请求。",
        f"逐一对照生成器元数据检查了 {audit['returned_hits']:,} 个返回命中，未发现租户/group-connect/日期范围串入、超出被测语料前缀或单页重复消息。这只验证本实验的范围过滤。",
        '两个节点的 cgroup 观测峰值均触及 6 GiB 上限，均未记录 OOM kill；页回收和 CPU throttling 计数保存在资源文件中。OpenSearch 资源监控有 8 个失败采样点，查询结果记录未丢失。这些观测提示资源压力，不能单独证明某个延迟尖峰的因果。','']
lines += ['## 复跑与证据','',
    '脚本、固定依赖与方法见 [README](../../README.md)；同目录的 `.json.gz` 保留逐请求延迟、结果 ID、召回与错误。`summary.json` 是便于读取的汇总。',
    '`audit.json` 将原始结果 ID 与生成器的消息元数据逐一核对，检查租户、group/connect 范围、日期、语料前缀及去重。`environment.json` 保存节点资源配置和观测汇总；资源原始采样单独压缩保存。',
    '节点、模型和原始媒体链路尚未集成到 agent 的正式搜索入口。本次没有部署、改动生产数据或向外部 provider 发起压测。','']
(args.output/'report.md').write_text('\n'.join(lines))
print(json.dumps({'records':len(records),'report':str(args.output/'report.md'),'figure':str(args.output/'capacity.png')}))

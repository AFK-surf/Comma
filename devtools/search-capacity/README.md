# Message-search runtime and capacity experiments

The implemented ClickHouse/PG/Provider path and its reproducible measurements
are documented in the [runtime report](results/2026-09-06/runtime/report.md).
Use `runtime_shape_load.py`, `runtime_shape_probe.exs`, `runtime_rank_oracle.py`
and `runtime_metadata_probe.py` for that implementation. The remaining drivers
below are the earlier engine-selection prototype, with different scope and data.

This is an executable search-engine prototype and capacity experiment for
[`message-search-target.md`](../../docs/storage-search.md).
It uses the official `opensearch-py` client, a real OpenSearch node and a
deterministic corpus. It does not call production, Slack, WeMM, OCR or ASR.
Canonical PG/ClickHouse publication checks and the production
`GroupDirectory`/`ProviderConnects` entry point are not wired into this driver.
The harness supplies trusted synthetic group/connect scopes; indexed scope
filtering here must not be described as the completed product authorization API.

Recorded experiment: [2026-09-06 report](results/2026-09-06/report.md), including
the measured 1M-pass / 2M-fail bracket, raw results, resource observations and
the separate ClickHouse comparison. Acceptance for that experiment is P95 <= 2s,
mean semantic Recall@20 >= 95%, no request errors, and no scope/duplicate errors
at every measured condition. It is not a guarantee for arbitrary vector data.

The separate [staging time-window assessment](results/2026-09-06/staging-window-assessment.md)
uses actual staging counts and bounded SQL replays. Its current-query recommendation
is conditional on the 256 MiB read-budget fix and must not be confused with the
independent-index prototype's capacity.

[Row-read optimization experiments](results/2026-09-06/row-read-optimization.md)
compare equivalent staging SQL shapes and local physical granularities. They
preserve source checks and the application row budget; the local table-layout
results are not a completed online migration or a production capacity claim.

[Optimized window ranges](results/2026-09-06/optimized-window-range.md) replay
staging's daily/channel counts and vector-count histograms through local 2,048
and 1,024 layouts. The bodies, vectors and within-day keys are synthetic. This
is a row-budget planning experiment, not real-content or end-to-end validation.

## What is measured

- 256-dimensional normalized, dense float32 vectors, matching the current WeMM
  output dimension. Vectors have 1,024 topic clusters, per-message variation and
  independent per-unit noise. They are generated, not actual WeMM embeddings;
  the recall measurement assesses ANN accuracy, not language/media understanding.
- Full-text snippets and image/OCR, audio/ASR and video-frame/transcript units
  with locators. Source media extraction, query embedding, network travel to the
  production cluster and final source-state verification are excluded.
- One message contains multiple independently locatable nested units. OpenSearch
  Lucene HNSW ranks parent messages by their best matching unit. This is an engine
  layout candidate; integrating independently published components still requires
  the source/publication protocol. It is not a declaration that nested parent
  writes solve that protocol.
- HNSW uses M=16, ef_construction=100 and ef_search=200 initially. Changes must be
  recorded per run; low recall is never silently accepted as higher capacity.
- One index shard, no replica, no manual force merge. Indexing is paused at each
  checkpoint but ordinary segment merges may continue. Warm-up requests are
  excluded. OS page cache is not forcibly cleared on the shared Docker host.
- Single-request/4-client/8-client closed-loop latency and throughput, plus
  approximately 10% and 1% group scope filtering. P95 is measured across 72
  requests (24 fixed queries, three repetitions) per ordinary case; it is an
  experiment, not certification of a production SLO.
- `verify_current.py` uses 64 previously unused queries per case, with a different
  seed for each concurrency/scope condition. It starts with the 10% filter and
  includes a 14-day query over the two-year corpus. `verify_prefix.py` builds
  independent, real indexes of the exact same data prefix to refine a failing
  size; it does not simulate a smaller index by filtering a larger one.
- Keyword retrieval and an explicit hybrid strategy: one `_msearch` returns
  100 lexical + 100 semantic messages, then bounded reciprocal-rank fusion returns 20. RRF never compares all vectors in the application. Keyword/hybrid timings
  are reported separately from semantic Recall@20.
- Exact oracle scans every vector, computes float32 cosine, takes the best unit
  per message and ranks all eligible messages. It runs separately from timed
  search requests. No topic filter, planted-ID shortcut or ANN result is used as
  the truth set.

## Mixtures

Percentages are **message** proportions; actual observed counts are saved.

| Profile  | Text | Image | Audio | Video | Approx. units/message |
| -------- | ---: | ----: | ----: | ----: | --------------------: |
| chat     |  90% |    5% |    4% |    1% |                  2.08 |
| balanced |  60% |   20% |   15% |    5% |       5.8 + long tail |
| media    |  20% |   20% |   30% |   30% |                  22.2 |

Ordinary text/image/audio/video messages produce 1/2/12/60 units. Every 997th
balanced message is a 500-unit video, replacing its originally sampled kind.
Messages span up to 10,000 channels and 730 days. Five percent belong to a
different tenant. Synthetic group scopes represent separate group-owned
connect occurrences over all, ten or one of 100 installation/source domains.
Every response is checked for tenant/scope/date leakage and duplicate messages.

The optional `diffuse` profile uses the balanced proportions with independent
random message directions instead of shared semantic topics. It is a harder
ANN sensitivity case, not a claim about actual WeMM data. Report its results
separately if run.

## Run

Use an isolated local instance. The recorded run uses OpenSearch 3.8.0 on
Apple M5 / 32 GiB host RAM, with Docker exposing about 16 GiB. The test container
has **4 CPU cores and 6 GiB total memory**, with a **2 GiB JVM heap**. It binds
only to loopback; disabled demo security is limited to this synthetic test node.

```sh
python3 -m venv /tmp/comma-search-capacity-venv
/tmp/comma-search-capacity-venv/bin/pip install -r devtools/search-capacity/requirements.lock
docker run -d --name comma-search-capacity-os --cpus=4 --memory=6g --memory-swap=6g \
  --ulimit nofile=65536:65536 --ulimit memlock=-1:-1 -p 127.0.0.1::9200 \
  -e discovery.type=single-node -e DISABLE_INSTALL_DEMO_CONFIG=true \
  -e DISABLE_SECURITY_PLUGIN=true -e 'OPENSEARCH_JAVA_OPTS=-Xms2g -Xmx2g' \
  opensearchproject/opensearch:3.8.0
docker port comma-search-capacity-os
OPENBLAS_NUM_THREADS=4 VECLIB_MAXIMUM_THREADS=4 /tmp/comma-search-capacity-venv/bin/python \
  devtools/search-capacity/run.py --port PORT --directory /tmp/comma-capacity-corpus \
  --prefix comma-capacity-main --profiles chat,balanced,media \
  --stages 100000,300000,1000000,3000000
```

Repeat with distinct queries, then refine the bracket with real smaller indexes:

```sh
OPENBLAS_NUM_THREADS=4 VECLIB_MAXIMUM_THREADS=4 /tmp/comma-search-capacity-venv/bin/python \
  devtools/search-capacity/verify_current.py --port PORT \
  --directory /tmp/comma-capacity-corpus --query-count 64 --label fresh64
OPENBLAS_NUM_THREADS=4 VECLIB_MAXIMUM_THREADS=4 /tmp/comma-search-capacity-venv/bin/python \
  devtools/search-capacity/verify_prefix.py --port PORT \
  --directory /tmp/comma-capacity-corpus --query-count 64 --stages 1000000,2000000
/tmp/comma-search-capacity-venv/bin/python devtools/search-capacity/report.py \
  --directory /tmp/comma-capacity-corpus --output /tmp/comma-capacity-report
```

`run_clickhouse.py` replays the same generated corpus into an isolated ClickHouse
node (recorded server version 26.8.2.7, HTTP port supplied with `--port`). The
recorded comparison uses `--profiles balanced --stages 100000,300000,1000000,3000000
--query-count 12 --repeats 2`. Stop the OpenSearch node before its timed runs.
Use a fresh ClickHouse database/container for a full replay; an already larger
table cannot be benchmarked as a smaller corpus.

The generator saves a vector memory map, source-message metadata, RNG state and
the last successful bulk boundary. Incomplete bulk results are errors. A resumed
experiment replays only the uncommitted range using the same document IDs/content.
It may stop after single-client P95 exceeds twice the default 2-second target or
the node fails. A 35 GiB free-disk floor prevents the benchmark from filling the
shared machine; reaching that floor is a test-environment limit, not a search
capacity result. `--keep-going` only bypasses the latency stop, not that disk floor.

Index readers close after a profile; indexes/corpus stay available for follow-up.
`--benchmark-current` reopens and measures the currently loaded size. Raw request
latencies, query IDs, errors, exact recall, source counts and engine statistics
are retained in each `results-*.json`. Export small results to the repository;
keep large regenerated vectors outside the checkout. Stop the owned test
container after the experiment; never stop unrelated developer containers.

Each case stops admitting requests after three errors or 120 seconds. Skipped
requests are explicitly counted and excluded from latency/QPS calculations;
they never become successful zero-latency samples. Administrative index open/
close operations allow 180 seconds because closing an index can wait for an
in-progress merge. This does not change the timed search SLO or hide search
failures.

`monitor.py` reads only the owned test container's cgroup every five seconds,
for a bounded duration. It records memory, page faults and CPU throttling;
observation does not affect query outcomes. `adversarial.py` checks a 500-unit
video against 40 other messages and a fixed, duplicate-free message window.

`run_clickhouse.py` is an independent narrow-table reference, not the old
single-channel SQL: it compares exact per-message ranking with HNSW top-200
unit candidates followed by grouping, including bounded snippet fetch. It uses
`clickhouse-connect`, the official ClickHouse Python client. Compare resource
caps and algorithm/recall, not just timings; do not run its timed cases alongside
the OpenSearch load test. Query plans are exported to show whether HNSW was used.

An observed passing size is a lower bound. Report a failing larger checkpoint
and its failure class before calling a range a measured capacity boundary.
Do not equate vector units with messages, storage capacity with query capacity,
or this engine-only latency with a fully integrated product response time.

Primary capability references: [nested vector retrieval](https://docs.opensearch.org/latest/vector-search/specialized-operations/nested-search-knn/),
[bulk item outcomes](https://docs.opensearch.org/latest/api-reference/document-apis/bulk/),
[field collapse limits](https://docs.opensearch.org/latest/search-plugins/searching-data/collapse-search/).

# Message-search runtime and capacity experiments

Reports:

- [Runtime report](results/2026-09-06/runtime/report.md): the implemented ClickHouse/PG/Provider path. Drivers: `runtime_shape_load.py`, `runtime_shape_probe.exs`, `runtime_rank_oracle.py`, `runtime_metadata_probe.py`.
- [2026-09-06 capacity report](results/2026-09-06/report.md): earlier engine-selection prototype (OpenSearch, with a ClickHouse comparison). The measured bracket is 1M units pass, 2M units fail.
- [Staging time-window assessment](results/2026-09-06/staging-window-assessment.md): real staging counts and bounded SQL replays of the old query path. Its recommendation depends on the 256 MiB read-budget fix. It is not the prototype's capacity.
- [Row-read optimization](results/2026-09-06/row-read-optimization.md): SQL shapes and local granularity comparisons. Not a production capacity claim.
- [Optimized window ranges](results/2026-09-06/optimized-window-range.md): staging daily counts replayed through local 2,048 and 1,024 layouts. Synthetic content. Row-budget planning only.

The target design is in [docs/storage-search.md](../../docs/storage-search.md).

## Prototype scope

The prototype uses `opensearch-py`, a real OpenSearch node and a deterministic synthetic corpus. It does not call production, Slack, WeMM, OCR or ASR. It is not wired to PG/ClickHouse publication checks or to `GroupDirectory`/`ProviderConnects`. The harness supplies trusted synthetic group/connect scopes. Do not describe its scope filtering as the product authorization API.

Acceptance: P95 <= 2s, mean semantic Recall@20 >= 95%, no request errors, and no scope or duplicate errors at every measured condition. This is not a guarantee for arbitrary vector data.

- Vectors are 256-dimensional synthetic float32 (WeMM output dimension), clustered by topic. Recall measures ANN accuracy, not media or language understanding.
- Excluded: media extraction, query embedding, network to production, final source-state checks.
- One message holds many nested units. Lucene HNSW ranks parents by best unit. This does not solve the publication protocol.
- Record every HNSW parameter change per run. Never accept low recall as higher capacity.
- The exact oracle scans every vector and ranks all eligible messages. It runs apart from timed requests.
- Hybrid search: one `_msearch` returns 100 lexical and 100 semantic messages, then bounded RRF returns 20. Keyword and hybrid timings are reported apart from Recall@20.
- `verify_current.py` uses unused queries with a new seed per condition. `verify_prefix.py` builds real indexes of a data prefix. It does not filter a larger index.

## Mixtures

Percentages are message proportions.

| Profile  | Text | Image | Audio | Video | Approx. units/message |
| -------- | ---: | ----: | ----: | ----: | --------------------: |
| chat     |  90% |    5% |    4% |    1% |                  2.08 |
| balanced |  60% |   20% |   15% |    5% |       5.8 + long tail |
| media    |  20% |   20% |   30% |   30% |                  22.2 |

Text, image, audio and video messages produce 1, 2, 12 and 60 units. Some balanced messages are 500-unit videos. The `diffuse` profile uses random message directions. It is a harder ANN case. Report it separately.

## Run

Use an isolated local instance. The recorded run used OpenSearch 3.8.0 on an Apple M5 / 32 GiB host. The container had 4 CPU, 6 GiB memory and a 2 GiB JVM heap. It binds only to loopback. Disabled demo security is only for this synthetic node.

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

Repeat with new queries, then refine the bracket with real smaller indexes:

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

`run_clickhouse.py` replays the same corpus into an isolated ClickHouse node (recorded 26.8.2.7, HTTP port in `--port`). The recorded comparison used `--profiles balanced --stages 100000,300000,1000000,3000000 --query-count 12 --repeats 2`. Stop the OpenSearch node before its timed runs. Never run both timed loads together. Use a fresh ClickHouse database or container for a full replay. A larger table cannot be benchmarked as a smaller corpus.

Rules:

- A resumed run replays only the uncommitted range with the same IDs and content.
- A disk floor stops the run. Reaching it is an environment limit, not a capacity result. `--keep-going` bypasses only the latency stop.
- Skipped requests are counted and excluded from latency and QPS.
- Export small results to the repository. Keep large vectors outside the checkout.
- Stop the owned test container afterwards. Never stop unrelated developer containers.
- `monitor.py` reads only the owned container's cgroup.

## Reading results

A passing size is a lower bound. Report a failing larger checkpoint and its failure class before you call a range a capacity boundary. Do not equate vector units with messages, storage capacity with query capacity, or engine latency with product response time.

References: [nested vector retrieval](https://docs.opensearch.org/latest/vector-search/specialized-operations/nested-search-knn/), [bulk item outcomes](https://docs.opensearch.org/latest/api-reference/document-apis/bulk/), [field collapse limits](https://docs.opensearch.org/latest/search-plugins/searching-data/collapse-search/).

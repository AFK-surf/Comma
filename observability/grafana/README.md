# Comma Grafana dashboards and staging alerting

`src/` is the only editable Dashboard semantic source. The JSON files under
`dashboards/` are deterministic generated projections consumed by the single
read-only Grafana Git Sync repository. Do not edit generated JSON or publish it
through the Grafana Dashboard API.

This is an independent `pnpm@10.25.0` package and is intentionally not part of
the clients workspace.

```sh
corepack pnpm@10.25.0 --dir observability/grafana install --frozen-lockfile
corepack pnpm@10.25.0 --dir observability/grafana typecheck
corepack pnpm@10.25.0 --dir observability/grafana test
corepack pnpm@10.25.0 --dir observability/grafana generate
observability/grafana/test/promql-recovery-test.sh
terraform -chdir=observability/grafana/terraform init -backend=false
terraform -chdir=observability/grafana/terraform validate
observability/grafana/test/terraform-workspace-guard-test.sh
```

Pull requests run those checks in `.github/workflows/grafana-dashboards.yml`
and fail when committed JSON differs from a clean regeneration. The PR job has
read-only repository access and no cloud identity. Manual and scheduled runs
also execute `pnpm smoke` with the existing staging GitHub OIDC identity; that
job only queries the Managed Prometheus API and reports query identity, status,
and result count. It never calls Grafana APIs or reads the datasource key.

Dashboard, panel, and query identities are explicitly assigned and stable.
Each environment also generates `_folder.json` from its configured stable
folder UID/title so Git Sync never relies on an auto-generated folder identity.
Required health panels preserve No data because missing telemetry is abnormal.
Lazy event panels describe the empty-window semantics and retain scrape or
traffic context. Current metric names are used without historical fallbacks.

Platform Overview and Salix Runtime contain the reviewed IM 5xx, logical LLM
error, and LLM TTFT shadow queries. The two LLM expressions feed the two
staging-only Grafana P2 rules; the IM 5xx shadow query remains a
dashboard-only companion view since 2026-08-12, when IM ingress alerting moved
to the Cloud Monitoring policy `comma_alerting:im_ingress_5xx`
(docs/observability.md). The Grafana rules are bounded
business-degradation notifications, not production SLOs or platform P1
incidents. Cloud Monitoring remains the platform invariant and availability
incident authority.

The Slack template and alert rule builders are versioned under `alerting/` and
`src/alerting/`. Generation writes the exact rule data to
`terraform/alerting-rules.json`; the official Grafana Terraform provider owns
template group `comma-slack` and the dedicated `comma-business-slo-1m` rule group.
The first rollout imported both live resources with all three rules paused,
and the reviewed activation revision enabled all three. The 2026-08-12
revision shrinks the repo projection to the two LLM rules; the live group
keeps the retired `comma-stg-im-5xx` rule until the next admin `terraform
apply`, a documented transitional state.
Terraform does not own the Cloud Monitoring datasource, the `Comma Alerts` folder, the encrypted
`comma-app-alerts` contact point, or the existing `team=comma, source=grafana`
route. Their live routing preview is a required activation check.

Grafana Cloud 13.2 currently misclassifies a Cloud Monitoring request that
contains only `promQLQuery` as a legacy metrics query. Every PromQL target
therefore includes the Foundation SDK's empty `TimeSeriesListBuilder` output as
a compatibility marker; it is present only to bypass that migration branch and
is not executed. Remove the marker and its validation only after a live
`/api/ds/query` request without `timeSeriesList` succeeds on the deployed
Grafana stack.

Generated dashboards name neither the datasource nor the project. Each dashboard
declares two hidden variables: `gcm_datasource` (a `stackdriver` datasource
variable) and `gcp_project` (a Cloud Monitoring `projects` query variable).
Grafana resolves them to the installed datasource and its project when it loads
the dashboard. The alert rules cannot use dashboard variables, so
`terraform/alerting-rules.json` carries `${GCP_PROJECT_ID}` and
`${GCM_DATASOURCE_UID}` tokens. Terraform substitutes them from the variables
`gcp_project_id` and `gcm_datasource_uid`. `terraform init` receives the state
bucket with `-backend-config="bucket=..."`, and `pnpm smoke` reads
`GCP_PROJECT_ID_STAGING`. The `projects` query variable is not yet verified against
the live stack; check that the dashboards resolve after the first Git Sync.

Only staging is generated and managed. Production application telemetry is
present in GCP, but production remains disabled here until a separate decision,
datasource installation, and required query smoke gates pass. See
[`grafana-installation.md`](../../docs/observability.md)
for external datasource/Git Sync ownership and future production steps.

The staging inventory contains six stable dashboards: Platform Overview,
Telemetry Pipeline, BFT Operations, Comma Product Operations, Salix Runtime, and
Billing Operations. Domain dashboards link to Platform Overview for shared
runtime/dependency root cause rather than duplicating those panels. The
[metric consumer inventory](../../docs/observability.md)
records the owner for all 58 application metrics.

import { readFileSync } from "node:fs";

import { businessAlertShadowContracts } from "../shadow-contracts.js";

export const grafanaAlertingContract = {
  url: "https://afksurf.grafana.net",
  environment: "staging",
  // Live names are Terraform template tokens (see terraform/main.tf), never literals.
  project: "${GCP_PROJECT_ID}",
  datasourceUid: "${GCM_DATASOURCE_UID}",
  alertFolderUid: "fcvt5g",
  alertFolderTitle: "Comma Alerts",
  ruleGroup: "comma-business-slo-1m",
  intervalSeconds: 60,
  templateGroupTitle: "comma-slack",
  receiverTitle: "comma-app-alerts",
} as const;

interface AlertRuleDefinition {
  readonly uid: string;
  readonly title: string;
  readonly domain: "可用性" | "容量";
  readonly policyId: string;
  readonly expression: string;
  readonly dashboardUid: string;
  readonly panelId: number;
  readonly summary: string;
  readonly impact: string;
  readonly evidence: string;
  readonly unknown: string;
  readonly action: string;
  readonly criteria: string;
}

export interface TerraformAlertRule {
  readonly uid: string;
  readonly name: string;
  readonly condition: string;
  readonly for: string;
  readonly no_data_state: "OK";
  readonly exec_err_state: "KeepLast";
  readonly is_paused: false;
  readonly labels: Readonly<Record<string, string>>;
  readonly annotations: Readonly<Record<string, string>>;
  readonly data: readonly TerraformAlertQuery[];
}

interface TerraformAlertQuery {
  readonly ref_id: string;
  readonly query_type: string;
  readonly datasource_uid: string;
  readonly relative_time_range: {
    readonly from: number;
    readonly to: number;
  };
  readonly model: Readonly<Record<string, unknown>>;
}

const templateContent = readFileSync(
  new URL("../../alerting/comma-slack.tmpl", import.meta.url),
  "utf8",
).trimEnd();

const logsUrl =
  "https://console.cloud.google.com/logs/query;query=resource.type%3D%22k8s_container%22%0Aresource.labels.namespace_name%3D%22comma%22?project=${GCP_PROJECT_ID}";
const deploymentUrl =
  "https://github.com/AFK-surf/Comma/actions/workflows/comma-deployment.yml?query=branch%3Amain";

// The IM ingress 5xx condition moved engines on 2026-08-12: it is now the
// two-environment Cloud Monitoring policy `comma_alerting:im_ingress_5xx`
// (k8s/comma/cloud-monitoring/policies/im-ingress-5xx.v1.json.tmpl). The shadow
// contract stays for the Platform Overview panel; Grafana no longer owns an
// alert rule for it, keeping one engine per condition.
const definitions: readonly AlertRuleDefinition[] = [
  {
    uid: "comma-stg-llm-error",
    title: "[P2][STG][可用性] LLM 最终请求错误率持续过高",
    domain: "可用性",
    policyId: "comma_grafana:stg_llm_logical_error",
    expression:
      businessAlertShadowContracts.llmLogicalRequestError.breachExpression,
    dashboardUid: "comma-staging-salix-runtime",
    panelId: 561,
    summary: "Staging 的 LLM logical request 最终错误率持续偏高。",
    impact:
      "部分 LLM logical request 可能在重试后仍失败，但不表示所有 provider 或模型不可用。",
    evidence:
      "Grafana 在满足最低请求量后，持续观察到最终 outcome=error 的比例超过阈值。",
    unknown: "尚未确认具体 provider、model、surface、受影响用户与根因。",
    action:
      "先看 Grafana Panel，再在 Salix Runtime 对照 logical request、attempt 与 workload 维度。",
    criteria:
      "15 分钟 logical request 数 >= 10 且最终错误率 > 10%，条件连续成立 15 分钟。",
  },
  {
    uid: "bfsralwg6q1hcd",
    title: "[P2][STG][容量] LLM TTFT p95 持续过高",
    domain: "容量",
    policyId: "comma_grafana:stg_llm_ttft",
    expression: businessAlertShadowContracts.llmTtft.breachExpression,
    dashboardUid: "comma-staging-salix-runtime",
    panelId: 562,
    summary: "Staging 的 LLM 首 token 延迟持续偏高。",
    impact:
      "部分 LLM 请求的首 token 等待可能明显变长；该指标不等同于端到端用户等待时间。",
    evidence:
      "Grafana 在满足最低样本量后，持续观察到 provider attempt TTFT p95 超过阈值。",
    unknown: "尚未确认具体 provider、model、surface、受影响用户与根因。",
    action:
      "先看 Grafana Panel，再在 Salix Runtime 对照 provider、model、attempt latency 与 workload。",
    criteria:
      "15 分钟 TTFT 样本数 >= 20 且 p95 > 30 秒，条件连续成立 15 分钟。",
  },
  {
    uid: "comma-stg-meeting-runtime-lost",
    title: "[P2][STG][可用性] 会议因运行时失联被判为记录不完整",
    domain: "可用性",
    policyId: "comma_grafana:stg_meeting_runtime_lost",
    expression:
      businessAlertShadowContracts.meetingRuntimeLost.breachExpression,
    dashboardUid: "comma-staging-salix-runtime",
    panelId: 590,
    summary: "有会议在拖堂上限内始终没有收到运行时的结束事件，被判定终态。",
    impact:
      "这些会议的参会者收到的是「记录不完整」说明而不是总结；即使真实总结随后抵达也不会再发布。",
    evidence:
      "总结 watchdog 在超过拖堂 cutoff 后仍拿不到确定的活会话答案，将会议置为 failed(runtime_lost)。",
    unknown: "尚未确认是运行时进程失联、连接器掉线，还是会议确实超长。",
    action:
      "先看该会议的 join_dispatch 与最后一次运行时事件时间，再确认对应连接器是否在线。",
    criteria:
      "30 分钟内出现至少一次 runtime_lost 终态化，条件连续成立 15 分钟。",
  },
  {
    uid: "comma-stg-meeting-stuck",
    title: "[P2][STG][可用性] 会议卡在非终态且没有时间锚点",
    domain: "可用性",
    policyId: "comma_grafana:stg_meeting_stuck_nonterminal",
    expression:
      businessAlertShadowContracts.meetingStuckNonterminal.breachExpression,
    dashboardUid: "comma-staging-salix-runtime",
    panelId: 591,
    summary:
      "有会议确实派发过入会、未被日历放弃，但缺少任何时间戳锚点，watchdog 无法安全终态化。",
    impact:
      "这些会议既不会产出总结，也不会被自动终态化，属于需要人工兜底的静默滞留。",
    evidence:
      "投递巡检对该会议求值出 no_anchor：end_at、left_at、joined_at、last_seen_live_at 全缺。",
    unknown: "尚未确认锚点缺失是入会写入不完整，还是运行时事件从未抵达。",
    action:
      "按 meeting_id 读该会议文档，确认它是如何在缺少全部时间戳的情况下完成派发的。",
    criteria: "30 分钟内出现至少一次无锚点滞留，条件连续成立 15 分钟。",
  },
  {
    uid: "comma-stg-meeting-delivery-error",
    title: "[P2][STG][可用性] 会议总结投递持续报错",
    domain: "可用性",
    policyId: "comma_grafana:stg_meeting_delivery_error",
    expression:
      businessAlertShadowContracts.meetingDeliveryError.breachExpression,
    dashboardUid: "comma-staging-salix-runtime",
    panelId: 592,
    summary: "会议总结投递在持续失败重试，尚未收敛为已发布或终态失败。",
    impact:
      "受影响会议的总结暂时没有送达；有界重试仍在进行，尚未到达终态化门槛。",
    evidence:
      "meeting_delivery 的 error 结局持续非零。等待连接被重新启用的投递不计入本条件，因此这里只反映真实失败。",
    unknown: "尚未确认是 provider 侧拒绝、存储故障，还是准备阶段的失败。",
    action:
      "读该会议 delivery 记录的 status、attempt_count 与 error，判断它会收敛还是需要介入。",
    criteria: "30 分钟内投递 error 结局非零，条件连续成立 15 分钟。",
  },
];

export const businessAlertRules: readonly TerraformAlertRule[] =
  definitions.map(buildAlertRule);

export const terraformAlertingProjection = {
  schema_version: 1,
  folder_uid: grafanaAlertingContract.alertFolderUid,
  rule_group_name: grafanaAlertingContract.ruleGroup,
  interval_seconds: grafanaAlertingContract.intervalSeconds,
  rules: businessAlertRules,
} as const;

export function renderTerraformAlertingProjection(): string {
  return `${JSON.stringify(terraformAlertingProjection, null, 2)}\n`;
}

export function validateTerraformAlertingProjection(): readonly string[] {
  const errors: string[] = [];
  const names = new Set<string>();

  if (!templateContent.includes('{{ define "comma.slack.title"')) {
    errors.push("Slack template must define comma.slack.title");
  }
  if (!templateContent.includes('{{ define "comma.slack.message"')) {
    errors.push("Slack template must define comma.slack.message");
  }
  for (const section of [
    "当前状态",
    "影响",
    "证据",
    "尚未确认",
    "立即检查",
    "判定口径",
  ]) {
    if (!templateContent.includes(section)) {
      errors.push(`Slack template is missing section ${section}`);
    }
  }

  if (businessAlertRules.length !== 5) {
    errors.push("exactly five staging business alert rules are required");
  }

  for (const rule of businessAlertRules) {
    if (names.has(rule.uid)) {
      errors.push(`duplicate managed rule UID ${rule.uid}`);
    }
    names.add(rule.uid);

    if (!/^\[P2\]\[STG\]\[(可用性|容量)\] .+/.test(rule.name)) {
      errors.push(
        `${rule.uid}: title must use the staging P2 four-part contract`,
      );
    }
    if (
      rule.labels.environment !== "staging" ||
      rule.labels.source !== "grafana" ||
      rule.labels.team !== "comma"
    ) {
      errors.push(
        `${rule.uid}: routing labels must be team=comma, source=grafana, environment=staging`,
      );
    }
    if (
      rule.for !== "15m" ||
      rule.no_data_state !== "OK" ||
      rule.exec_err_state !== "KeepLast" ||
      rule.is_paused
    ) {
      errors.push(`${rule.uid}: active rollout lifecycle contract drift`);
    }
    if (JSON.stringify(rule).includes("production")) {
      errors.push(`${rule.uid}: production is outside this rollout`);
    }
  }

  return errors;
}

function buildAlertRule(definition: AlertRuleDefinition): TerraformAlertRule {
  return {
    uid: definition.uid,
    name: definition.title,
    condition: "C",
    for: "15m",
    no_data_state: "OK",
    exec_err_state: "KeepLast",
    is_paused: false,
    labels: {
      domain: definition.domain,
      environment: grafanaAlertingContract.environment,
      priority: "P2",
      source: "grafana",
      team: "comma",
    },
    annotations: {
      __dashboardUid__: definition.dashboardUid,
      __panelId__: String(definition.panelId),
      summary: definition.summary,
      description: `告警语义：${definition.impact} 判定口径：${definition.criteria}`,
      impact: definition.impact,
      evidence: definition.evidence,
      unknown: definition.unknown,
      action: definition.action,
      criteria: definition.criteria,
      policy_id: definition.policyId,
      logs_url: logsUrl,
      deployment_url: deploymentUrl,
    },
    data: alertQueries(definition.expression),
  };
}

function alertQueries(expression: string): readonly TerraformAlertQuery[] {
  return [
    {
      ref_id: "A",
      query_type: "promQL",
      relative_time_range: { from: 1_200, to: 0 },
      datasource_uid: grafanaAlertingContract.datasourceUid,
      model: {
        datasource: {
          type: "stackdriver",
          uid: grafanaAlertingContract.datasourceUid,
        },
        hide: false,
        instant: true,
        intervalMs: 1_000,
        maxDataPoints: 43_200,
        promQLQuery: {
          expr: expression,
          projectName: grafanaAlertingContract.project,
          step: "10s",
        },
        queryType: "promQL",
        refId: "A",
        timeSeriesList: {
          filters: [],
          instant: true,
          projectName: grafanaAlertingContract.project,
          view: "FULL",
        },
      },
    },
    {
      ref_id: "reducer",
      query_type: "expression",
      relative_time_range: { from: 0, to: 0 },
      datasource_uid: "-100",
      model: {
        conditions: [
          {
            evaluator: { params: [0, 0], type: "gt" },
            operator: { type: "and" },
            query: { params: [] },
            reducer: { params: [], type: "avg" },
            type: "query",
          },
        ],
        datasource: {
          name: "Expression",
          type: "__expr__",
          uid: "-100",
        },
        expression: "A",
        intervalMs: 1_000,
        maxDataPoints: 43_200,
        reducer: "last",
        refId: "reducer",
        type: "reduce",
      },
    },
    {
      ref_id: "C",
      query_type: "expression",
      relative_time_range: { from: 0, to: 0 },
      datasource_uid: "-100",
      model: {
        conditions: [
          {
            evaluator: { params: [0], type: "gt" },
            operator: { type: "and" },
            query: { params: ["C"] },
            reducer: { params: [], type: "last" },
            type: "query",
          },
        ],
        datasource: { type: "__expr__", uid: "-100" },
        expression: "reducer",
        intervalMs: 1_000,
        maxDataPoints: 43_200,
        refId: "C",
        type: "threshold",
      },
    },
  ];
}

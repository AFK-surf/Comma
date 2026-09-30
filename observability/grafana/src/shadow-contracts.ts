const evaluationWindow = "15m";
const commaWorkloads = 'namespace="comma",workload="comma"';

function ratioExpression(numerator: string, volume: string): string {
  return `((${numerator}) or on(workload) (0 * (${volume}))) / (${volume})`;
}

function thresholdBreachExpression(
  signal: string,
  volume: string,
  threshold: number,
  minimumVolume: number,
): string {
  const breached = `((${signal}) > ${threshold}) and on(workload) ((${volume}) >= ${minimumVolume})`;

  // Grafana asks Cloud Monitoring for a range and reduces the last returned
  // sample. PromQL comparisons without `bool` omit false samples, so a prior
  // positive sample would otherwise remain the last value after recovery.
  // Preserve the workload label and emit an explicit zero while volume exists.
  return `(${breached}) or on(workload) (0 * (${volume}))`;
}

const imIngressVolume = `sum by (workload) (increase(comma_system_http_requests_total{${commaWorkloads},route="/v1/im/*"}[${evaluationWindow}]))`;
const imIngress5xx = `sum by (workload) (increase(comma_system_http_requests_total{${commaWorkloads},route="/v1/im/*",status_class="5xx"}[${evaluationWindow}]))`;
const imIngress5xxRatio = ratioExpression(imIngress5xx, imIngressVolume);

const llmLogicalRequestVolume = `sum by (workload) (increase(salix_llm_requests_total{${commaWorkloads}}[${evaluationWindow}]))`;
const llmLogicalRequestErrors = `sum by (workload) (increase(salix_llm_requests_total{${commaWorkloads},outcome="error"}[${evaluationWindow}]))`;
const llmLogicalRequestErrorRatio = ratioExpression(
  llmLogicalRequestErrors,
  llmLogicalRequestVolume,
);

// Meeting-reliability conditions are counts of a rare event, not ratios: one
// occurrence is already worth a look, so there is no minimum-volume gate. The
// window is deliberately wider than the rule's 15m `for`, so a single
// occurrence stays positive long enough to be observed for the full pending
// period instead of racing the evaluation clock.
const meetingWindow = "30m";

function countBreachExpression(signal: string): string {
  // Same recovery reasoning as thresholdBreachExpression: a comparison alone
  // omits false samples, so the last positive sample would stick after the
  // condition clears. Emit an explicit zero from the same series instead.
  return `((${signal}) > 0) or on(workload) (0 * (${signal}))`;
}

const meetingOperation = (operation: string, outcome?: string) => {
  const selector = outcome
    ? `${commaWorkloads},component="salix_meet",operation="${operation}",outcome="${outcome}"`
    : `${commaWorkloads},component="salix_meet",operation="${operation}"`;

  return `sum by (workload) (increase(salix_operations_total{${selector}}[${meetingWindow}]))`;
};

const meetingRuntimeLost = meetingOperation("meeting_watchdog", "ok");
const meetingStuckNonterminal = meetingOperation("meeting_stuck_nonterminal");
const meetingDeliveryErrors = meetingOperation("meeting_delivery", "error");

const llmTtftSampleVolume = `sum by (workload) (increase(salix_llm_ttft_seconds_count{${commaWorkloads}}[${evaluationWindow}]))`;
const llmTtftP95 = `histogram_quantile(0.95, sum by (workload, le) (rate(salix_llm_ttft_seconds_bucket{${commaWorkloads}}[${evaluationWindow}])))`;

export const businessAlertShadowContracts = {
  evaluationWindow,
  imIngress5xx: {
    ratioThreshold: 0.05,
    minimumVolume: 20,
    ratioExpression: imIngress5xxRatio,
    volumeExpression: imIngressVolume,
    breachExpression: thresholdBreachExpression(
      imIngress5xxRatio,
      imIngressVolume,
      0.05,
      20,
    ),
  },
  llmLogicalRequestError: {
    ratioThreshold: 0.1,
    minimumVolume: 10,
    ratioExpression: llmLogicalRequestErrorRatio,
    volumeExpression: llmLogicalRequestVolume,
    breachExpression: thresholdBreachExpression(
      llmLogicalRequestErrorRatio,
      llmLogicalRequestVolume,
      0.1,
      10,
    ),
  },
  meetingRuntimeLost: {
    window: meetingWindow,
    signalExpression: meetingRuntimeLost,
    breachExpression: countBreachExpression(meetingRuntimeLost),
  },
  meetingStuckNonterminal: {
    window: meetingWindow,
    signalExpression: meetingStuckNonterminal,
    breachExpression: countBreachExpression(meetingStuckNonterminal),
  },
  meetingDeliveryError: {
    window: meetingWindow,
    signalExpression: meetingDeliveryErrors,
    breachExpression: countBreachExpression(meetingDeliveryErrors),
  },
  llmTtft: {
    p95ThresholdSeconds: 30,
    minimumVolume: 20,
    p95Expression: llmTtftP95,
    volumeExpression: llmTtftSampleVolume,
    breachExpression: thresholdBreachExpression(
      llmTtftP95,
      llmTtftSampleVolume,
      30,
      20,
    ),
  },
} as const;

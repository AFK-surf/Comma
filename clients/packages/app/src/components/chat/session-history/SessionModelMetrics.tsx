import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import type { SessionHistoryRecord } from "../../../runtime-chat/sessionHistoryBridge";
import { formatSessionDuration } from "./model/sessionHistoryPresentation";
import { sessionModelMetrics } from "./model/sessionHistoryModelMetrics";

export function SessionModelMetrics({
  record,
  detail = false,
}: {
  record: SessionHistoryRecord;
  detail?: boolean;
}) {
  const m = useCommaMessages();
  const locale = useCommaLocale();
  const metrics = sessionModelMetrics(record);
  const formatTokens = (value: number) =>
    new Intl.NumberFormat(
      locale,
      detail ? {} : { notation: "compact", maximumFractionDigits: 1 }
    ).format(value);
  const values: { label: string; value: string; title?: string }[] = [
    ...(!detail && metrics.ttft !== undefined
      ? [{ label: "TTFT", value: formatSessionDuration(metrics.ttft) ?? "0ms" }]
      : []),
    ...(metrics.input !== undefined
      ? [
          {
            label: m.session_model_input(),
            value: formatTokens(metrics.input),
            title: `${metrics.input} token`,
          },
        ]
      : []),
    ...(metrics.output !== undefined
      ? [
          {
            label: m.session_model_output(),
            value: formatTokens(metrics.output),
            title: `${metrics.output} token`,
          },
        ]
      : []),
    ...(metrics.cacheRate !== undefined
      ? [
          {
            label: m.session_model_cache(),
            value: new Intl.NumberFormat(locale, {
              style: "percent",
              maximumFractionDigits: 1,
            }).format(metrics.cacheRate),
          },
        ]
      : []),
    ...(detail && metrics.cacheRead !== undefined
      ? [
          {
            label: m.session_model_cache_read(),
            value: formatTokens(metrics.cacheRead),
          },
        ]
      : []),
    ...(detail && metrics.cacheWrite !== undefined
      ? [
          {
            label: m.session_model_cache_write(),
            value: formatTokens(metrics.cacheWrite),
          },
        ]
      : []),
  ];
  if (!values.length && !metrics.model) return null;
  return (
    <span
      className="comma-session-model-metrics"
      data-detail={detail || undefined}
      data-testid="session-model-metrics"
    >
      {metrics.model && (
        <span className="comma-session-model-name">{metrics.model}</span>
      )}
      {values.map(({ label, value, title }) => (
        <span key={label} title={title}>
          <span>{label}</span> <strong>{value}</strong>
        </span>
      ))}
    </span>
  );
}

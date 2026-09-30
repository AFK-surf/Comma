import type { JobSnapshot } from "../../shared/schema";

const statusLabels = {
  queued: "排队中",
  running: "运行中",
  succeeded: "已完成",
  failed: "需要处理",
} as const;

function duration(job: JobSnapshot): string {
  if (!job.startedAt) return "—";
  const end = job.finishedAt ? Date.parse(job.finishedAt) : Date.now();
  const seconds = Math.max(0, Math.round((end - Date.parse(job.startedAt)) / 1_000));
  if (seconds < 60) return `${seconds}s`;
  return `${Math.floor(seconds / 60)}m ${seconds % 60}s`;
}

export function JobPanel({ job }: { job: JobSnapshot | null }) {
  if (!job) return null;
  return (
    <section className={`job-panel job-panel--${job.status}`} aria-live="polite">
      <div className="job-panel__summary">
        <span className="status-dot" aria-hidden="true" />
        <strong>{job.kind === "apply" ? "Save & Apply" : "全量提取"}</strong>
        <span>{statusLabels[job.status]}</span>
        <span>{job.stage}</span>
        <span className="tabular">{duration(job)}</span>
      </div>
      {job.error ? <div className="job-panel__error">{job.error}</div> : null}
      {job.logs.length ? (
        <details className="job-panel__logs">
          <summary>精简日志（{job.logs.length}）</summary>
          <ol>
            {job.logs.map((line, index) => (
              <li key={`${index}:${line}`}>{line}</li>
            ))}
          </ol>
        </details>
      ) : null}
    </section>
  );
}

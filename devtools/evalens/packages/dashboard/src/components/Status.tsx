import type { LifecycleStatus } from "../data/types";
import { useMessages } from "../i18n/locale";

export function Status({ value }: { value: LifecycleStatus | "reindexing" }) {
  const m = useMessages();
  const label =
    value === "finished"
      ? m.status_finished()
      : value === "running"
        ? m.status_running()
        : value === "error"
          ? m.status_error()
          : m.status_reindexing();
  return <span className={`status status-${value}`}>{label}</span>;
}

export function StatePanel({
  title,
  detail,
  action,
}: {
  title: string;
  detail: string;
  action?: React.ReactNode;
}) {
  return (
    <div className="state-panel" role="status">
      <strong>{title}</strong>
      <span>{detail}</span>
      {action}
    </div>
  );
}

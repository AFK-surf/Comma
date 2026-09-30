import { useMemo } from "react";
import type { SessionHistorySnapshot } from "../../../../runtime-chat/sessionHistoryBridge";

/** Durable terminal measurements dominate observational overlays. An absent
 * completion never implies a live request; only the owner supplies `live`. */
export function useHistoryRecords(
  snapshot: SessionHistorySnapshot | null | undefined,
  recent = false
) {
  return useMemo(() => {
    const records = recent
      ? (snapshot?.recentRecords ?? [])
      : (snapshot?.records ?? []);
    const source = recent && !records.length ? (snapshot?.records ?? []) : records;
    const completed = new Set(
      [...(snapshot?.records ?? []), ...(snapshot?.recentRecords ?? [])]
        .filter((r) => r.execution?.completed_at_ms != null)
        .map((r) => `${r.execution!.lane}:${r.execution!.id}`)
    );
    const overlays = (snapshot?.liveRecords ?? [])
      .filter((r) => !completed.has(`${r.execution!.lane}:${r.execution!.id}`))
      .map((r) =>
        snapshot?.streamStatus === "live"
          ? r
          : { ...r, execution: { ...r.execution!, live: false } }
      );
    // Without overlays, keep the snapshot's array so a status-only change does
    // not rebuild the projections of every loaded record.
    if (!overlays.length) return source;
    return [
      ...source,
      ...overlays.toSorted(
        (a, b) => a.execution!.started_at_ms - b.execution!.started_at_ms
      ),
    ];
  }, [
    snapshot?.records,
    snapshot?.recentRecords,
    snapshot?.liveRecords,
    snapshot?.streamStatus,
    recent,
  ]);
}

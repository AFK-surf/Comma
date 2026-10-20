import { CoreClient } from "@comma/core-client";

/**
 * A core for browser fixtures that keeps only the reader's marks, in memory: `marks` topics and the
 * `marks.mark` / `marks.unmark` calls, as the client core answers them.
 */
export function marksCore(): CoreClient {
  const kept = new Map<string, Record<string, number>>();
  const subscribers = new Map<number, string>();
  let deliver: ((data: unknown) => void) | undefined;
  const send = (kind: string) => {
    for (const [id, subscribed] of subscribers)
      if (subscribed === kind)
        deliver?.({ id, value: { marks: kept.get(kind) ?? {} } });
  };
  return new CoreClient(
    (onMessage) => {
      deliver = (data) => queueMicrotask(() => onMessage(structuredClone(data)));
      return {
        post(raw) {
          const message = raw as {
            id: number;
            call?: string;
            params?: { kind: string; entries?: [string, number][]; ids?: string[] };
            subscribe?: { topic: string; kind?: string };
            unsubscribe?: boolean;
          };
          if (message.subscribe?.topic === "marks") {
            subscribers.set(message.id, message.subscribe.kind ?? "");
            send(message.subscribe.kind ?? "");
          } else if (message.unsubscribe) subscribers.delete(message.id);
          else if (message.call && message.params) {
            const { kind, entries = [], ids = [] } = message.params;
            const next = { ...kept.get(kind) };
            if (message.call === "marks.mark")
              for (const [id, revision] of entries)
                if ((next[id] ?? -Infinity) < revision) next[id] = revision;
            if (message.call === "marks.unmark") for (const id of ids) delete next[id];
            kept.set(kind, next);
            deliver?.({ id: message.id, ok: null });
            send(kind);
          }
        },
        close() {
          deliver = undefined;
        },
      };
    },
    { schedule: () => undefined }
  );
}

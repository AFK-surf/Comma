import {
  type SessionHistoryDemand,
  sessionHistoryDemandSchema,
  sessionHistoryInputSchema,
  sessionHistoryLoadSchema,
  sessionHistoryPageSchema,
  type SessionHistoryInput,
  type SessionHistoryLoad,
  type SessionHistoryEnvelope,
  type SessionHistoryRecord,
  type SessionHistoryStreamFrame,
} from "@comma/native-bridge";
import { readHistoryStream } from "./stream";
import { reuseSessionHistoryRecords } from "./records";
import {
  sameSessionProductLease,
  type SessionPresenceExpectation,
} from "@comma/session-contract";

type Credential = {
  audience: string;
  token: string;
  signal: AbortSignal;
  request?: {
    credentials: RequestCredentials;
    headers: Readonly<Record<string, string>>;
  };
};
export interface HistoryAuthority {
  acquireProductCredential(expected: SessionPresenceExpectation): Credential | null;
  isCurrentProductCredential(credential: Credential): boolean;
}
type Entry = {
  consumers: Set<string>;
  envelope: SessionHistoryEnvelope;
  pending?: Promise<SessionHistoryEnvelope> | undefined;
  controller: AbortController;
  stream?: Promise<void> | undefined;
  checkpoint: string | null;
  ledgerHead: string | null;
};

/**
 * Shared owner for Electron Main and Web SharedWorker. UI only projects these
 * snapshots. One in-flight page per target; no polling or background fan-out.
 * SessionHistoryPaging.tla models stale completion, shared demand and paging.
 */
export class SessionHistoryRuntime {
  readonly #entries = new Map<string, Entry>();
  readonly #listeners = new Set<(envelope: SessionHistoryEnvelope) => void>();
  constructor(
    private readonly options: {
      authority: HistoryAuthority;
      fetch?: typeof fetch;
      stream?: typeof readHistoryStream;
    }
  ) {}

  subscribe(listener: (envelope: SessionHistoryEnvelope) => void) {
    this.#listeners.add(listener);
    return () => {
      this.#listeners.delete(listener);
    };
  }
  state(input: SessionHistoryInput): SessionHistoryEnvelope {
    sessionHistoryInputSchema.parse(input);
    this.#credential(input);
    return this.#entry(input).envelope;
  }
  retain(input: SessionHistoryDemand) {
    sessionHistoryDemandSchema.parse(input);
    this.#credential(input);
    const entry = this.#entry(input);
    entry.consumers.add(input.consumerId);
    if (!entry.stream) entry.stream = this.#stream(input, entry);
    return entry.envelope;
  }
  release(input: SessionHistoryDemand) {
    const key = JSON.stringify([
      input.groupId,
      input.conversationId,
      input.participantId,
    ]);
    const entry = this.#entries.get(key);
    if (!entry || !sameSessionProductLease(entry.envelope.session, input.session))
      return false;
    const removed = entry.consumers.delete(input.consumerId);
    if (removed && entry.consumers.size === 0) {
      entry.controller.abort();
      this.#entries.delete(key);
    }
    return removed;
  }
  releaseAll(prefix: string) {
    for (const [key, entry] of this.#entries) {
      for (const consumer of entry.consumers)
        if (consumer.startsWith(prefix)) entry.consumers.delete(consumer);
      if (entry.consumers.size === 0) {
        entry.controller.abort();
        this.#entries.delete(key);
      }
    }
  }
  async load(input: SessionHistoryLoad): Promise<SessionHistoryEnvelope> {
    sessionHistoryLoadSchema.parse(input);
    const credential = this.#credential(input);
    const entry = this.#entry(input);
    if (entry.pending) {
      await entry.pending;
      this.#credential(input);
      // Concurrent older demands share the same page. Detail demand after a
      // three-record preview still needs its initial fifty-record window.
      if (input.mode !== "latest" || entry.envelope.snapshot.loaded === "detail")
        return entry.envelope;
      return this.load(input);
    }
    const snapshot = entry.envelope.snapshot;
    if (input.mode === "preview" && snapshot.loaded !== "none") return entry.envelope;
    if (input.mode === "older" && (!snapshot.hasMore || snapshot.loaded !== "detail"))
      return entry.envelope;
    const before = input.mode === "older" ? snapshot.nextBefore : null;
    this.#publish(entry, { status: "loading", error: null });
    const run = async () => {
      try {
        const parts = [input.groupId, input.conversationId, input.participantId].map(
          encodeURIComponent
        );
        const url = new URL(
          `/v1/comma/groups/${parts[0]}/conversations/${parts[1]}/participants/${parts[2]}/history`,
          credential.audience
        );
        url.searchParams.set("limit", input.mode === "preview" ? "3" : "50");
        if (before) url.searchParams.set("before", before);
        const response = await (this.options.fetch ?? fetch)(url, {
          method: "GET",
          redirect: "error",
          cache: "no-store",
          credentials: credential.request?.credentials ?? "omit",
          headers: {
            ...credential.request?.headers,
            ...(credential.token
              ? { authorization: `Bearer ${credential.token}` }
              : {}),
          },
          signal: AbortSignal.any([
            credential.signal,
            entry.controller.signal,
            AbortSignal.timeout(30_000),
          ]),
        });
        if (!response.ok)
          throw new Error(response.status === 403 ? "forbidden" : "unavailable");
        const page = sessionHistoryPageSchema.parse(await response.json());
        if (
          page.conversation_id !== input.conversationId ||
          page.participant_id !== input.participantId ||
          (page.has_more &&
            (!page.next_before ||
              page.next_before === before ||
              page.records.length === 0))
        )
          throw new Error("unavailable");
        if (
          !this.options.authority.isCurrentProductCredential(credential) ||
          entry.controller.signal.aborted
        )
          return entry.envelope;
        const current = entry.envelope.snapshot;
        entry.ledgerHead ??= page.records.at(-1)?.id ?? "0";
        const preserveOlderCursor = !before && current.loaded === "detail";
        this.#publish(entry, {
          records: mergeRecords(
            mergeRecords(current.records, page.records),
            current.recentRecords.filter(
              (record) => compareIds(record.id, entry.ledgerHead!) > 0
            )
          ),
          loaded: input.mode === "preview" ? "preview" : "detail",
          hasMore: preserveOlderCursor ? current.hasMore : page.has_more,
          nextBefore: preserveOlderCursor
            ? current.nextBefore
            : (page.next_before ?? null),
          status: "ready",
          error: null,
        });
      } catch (error) {
        if (
          this.options.authority.isCurrentProductCredential(credential) &&
          !entry.controller.signal.aborted
        ) {
          this.#publish(entry, {
            status: "error",
            error:
              error instanceof Error && error.message === "forbidden"
                ? "forbidden"
                : "unavailable",
          });
        }
      }
      return entry.envelope;
    };
    entry.pending = run();
    try {
      return await entry.pending;
    } finally {
      entry.pending = undefined;
    }
  }
  close() {
    for (const entry of this.#entries.values()) entry.controller.abort();
    this.#entries.clear();
    this.#listeners.clear();
  }
  /** One authenticated stream per retained target, shared by all host consumers.
   * Reconnect replays from the last completed checkpoint; partial cycles never
   * advance it. SessionHistoryLive.tla models page/stream interleaving and fences. */
  async #stream(input: SessionHistoryInput, entry: Entry) {
    let attempt = 0;
    while (!entry.controller.signal.aborted) {
      const credential = this.#credential(input);
      const signal = AbortSignal.any([credential.signal, entry.controller.signal]);
      const connection = new AbortController();
      const connectionSignal = AbortSignal.any([
        signal,
        connection.signal,
        AbortSignal.timeout(65_000),
      ]);
      this.#publish(entry, { streamStatus: attempt ? "reconnecting" : "connecting" });
      try {
        const path = [input.groupId, input.conversationId, input.participantId].map(
          encodeURIComponent
        );
        const url = new URL(
          `/v1/comma/groups/${path[0]}/conversations/${path[1]}/participants/${path[2]}/history/events`,
          credential.audience
        );
        if (entry.checkpoint) url.searchParams.set("after", entry.checkpoint);
        await (this.options.stream ?? readHistoryStream)(
          this.options.fetch ?? fetch,
          url,
          {
            method: "GET",
            redirect: "error",
            cache: "no-store",
            credentials: credential.request?.credentials ?? "omit",
            headers: {
              ...credential.request?.headers,
              accept: "text/event-stream",
              ...(credential.token
                ? { authorization: `Bearer ${credential.token}` }
                : {}),
            },
            signal: connectionSignal,
          },
          (frame) => {
            if (
              connectionSignal.aborted ||
              !this.options.authority.isCurrentProductCredential(credential)
            )
              return;
            if (
              frame.conversation_id !== input.conversationId ||
              frame.participant_id !== input.participantId
            )
              throw new Error("Incorrect Session history stream target.");
            attempt = 0;
            this.#applyFrame(entry, frame);
          }
        );
      } catch {
        if (signal.aborted) return;
      } finally {
        connection.abort();
      }
      if (signal.aborted) return;
      this.#publish(entry, { streamStatus: "reconnecting" });
      // At most 24 retained targets. Retry traffic is capped per target at
      // one attempt/second initially, backing off to one every ten seconds.
      await waitForRetry(Math.min(10_000, 1000 * 2 ** attempt++), signal);
      if (signal.aborted) return;
    }
  }
  #applyFrame(entry: Entry, frame: SessionHistoryStreamFrame) {
    const current = entry.envelope.snapshot;
    if (frame.phase === "checkpoint") entry.checkpoint = frame.checkpoint;
    this.#publish(entry, {
      records: mergeRecords(
        current.records,
        frame.phase === "update"
          ? frame.records
          : entry.ledgerHead === null
            ? []
            : frame.records.filter(
                (record) => compareIds(record.id, entry.ledgerHead!) > 0
              )
      ),
      recentRecords: reuseSessionHistoryRecords(
        current.recentRecords,
        mergeRecords(current.recentRecords, frame.records).filter(
          (record) =>
            (record.execution?.observed_at_ms ?? record.timestamp_ms ?? 0) >=
            frame.server_time_ms - 180_000
        )
      ),
      liveRecords: reuseSessionHistoryRecords(current.liveRecords, frame.live_records),
      // Keep one clock anchor per connection; network jitter between heartbeats
      // must not move a fixed three-minute axis backwards and forwards.
      clockOffsetMs:
        current.streamStatus === "live"
          ? current.clockOffsetMs
          : frame.server_time_ms - Date.now(),
      streamStatus: "live",
    });
  }
  #credential(input: SessionHistoryInput) {
    const session = input.session;
    const credential = this.options.authority.acquireProductCredential({
      authorityInstanceId: session.authorityInstanceId,
      expectedAudience: session.audience,
      expectedSessionId: session.sessionId,
      generation: session.generation,
    });
    if (!credential) throw new Error("Session history session is no longer active.");
    return credential;
  }
  #entry(input: SessionHistoryInput): Entry {
    const { session, groupId, conversationId, participantId } = input;
    for (const [key, entry] of this.#entries) {
      if (!sameSessionProductLease(entry.envelope.session, session)) {
        entry.controller.abort();
        this.#entries.delete(key);
      }
    }
    const key = JSON.stringify([groupId, conversationId, participantId]);
    let entry = this.#entries.get(key);
    if (!entry) {
      // Bound retained targets per signed-in runtime; pages load only on demand.
      if (this.#entries.size >= 24) {
        const victim = [...this.#entries].find(
          ([, item]) => !item.pending && item.consumers.size === 0
        );
        if (!victim) throw new Error("Session history is busy.");
        victim[1].controller.abort();
        this.#entries.delete(victim[0]);
      }
      entry = {
        consumers: new Set(),
        controller: new AbortController(),
        checkpoint: null,
        ledgerHead: null,
        envelope: {
          session,
          snapshot: {
            groupId,
            conversationId,
            participantId,
            records: [],
            recentRecords: [],
            liveRecords: [],
            clockOffsetMs: 0,
            streamStatus: "closed",
            status: "idle",
            loaded: "none",
            error: null,
            hasMore: false,
            nextBefore: null,
            revision: 0,
          },
        },
      };
      this.#entries.set(key, entry);
    }
    return entry;
  }
  #publish(entry: Entry, patch: Partial<SessionHistoryEnvelope["snapshot"]>) {
    // Every publish sends the whole snapshot to each window, which projects it
    // again. A heartbeat that changes nothing must not cost the UI that work.
    const current = entry.envelope.snapshot;
    if (
      (Object.keys(patch) as (keyof typeof patch)[]).every((key) =>
        Object.is(patch[key], current[key])
      )
    )
      return;
    entry.envelope = {
      ...entry.envelope,
      snapshot: {
        ...entry.envelope.snapshot,
        ...patch,
        revision: entry.envelope.snapshot.revision + 1,
      },
    };
    for (const listener of this.#listeners) listener(entry.envelope);
  }
}

// Canonical internal transcript sequence IDs and external ULIDs are each
// monotonic within their fixed Participant target; no timestamps order pages.
function mergeRecords(
  current: SessionHistoryRecord[],
  incoming: readonly SessionHistoryRecord[]
) {
  const records = new Map(current.map((record) => [record.id, record]));
  for (const record of incoming) records.set(record.id, record);
  return reuseSessionHistoryRecords(
    current,
    [...records.values()].toSorted((a, b) => compareIds(a.id, b.id))
  );
}
const recordOrderKey = (id: string) =>
  /^\d{1,20}$/.test(id) ? id.padStart(32, "0") : id;
function compareIds(a: string, b: string) {
  return recordOrderKey(a) < recordOrderKey(b)
    ? -1
    : recordOrderKey(a) > recordOrderKey(b)
      ? 1
      : 0;
}
function waitForRetry(milliseconds: number, signal: AbortSignal) {
  return new Promise<void>((resolve) => {
    const finish = () => {
      clearTimeout(timer);
      signal.removeEventListener("abort", finish);
      resolve();
    };
    const timer = setTimeout(finish, milliseconds);
    signal.addEventListener("abort", finish, { once: true });
  });
}

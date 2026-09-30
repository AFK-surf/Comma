import {
  createContext,
  useContext,
  useCallback,
  useRef,
  useEffect,
  useMemo,
  useState,
  useId,
  type ReactNode,
} from "react";
import {
  getNativeBridge,
  type CommaNativeBridge,
  type SessionHistoryEnvelope,
  type SessionHistoryInput,
} from "@comma/native-bridge";
import { sameSessionProductLease } from "@comma/session-contract";
import { reuseSessionHistoryRecords } from "@comma/session-history-runtime/records";
export type {
  SessionHistoryInput,
  SessionHistoryRecord,
  SessionHistorySnapshot,
} from "@comma/native-bridge";

type Bridge = CommaNativeBridge["sessionHistory"];
const Context = createContext<Bridge | null>(null);
export function SessionHistoryBridgeProvider({
  bridge,
  children,
}: {
  bridge: Bridge;
  children: ReactNode;
}) {
  return <Context.Provider value={bridge}>{children}</Context.Provider>;
}

/** Keeps the newer envelope. Hosts deliver each snapshot as a structured clone,
 * so a record that did not change keeps its previous object and memoized
 * projections skip it. */
function nextEnvelope(
  previous: SessionHistoryEnvelope | undefined,
  value: SessionHistoryEnvelope,
  matches: (value: SessionHistoryEnvelope) => boolean
): SessionHistoryEnvelope {
  if (!previous || !matches(previous)) return value;
  if (previous.snapshot.revision > value.snapshot.revision) return previous;
  const { records, recentRecords, liveRecords } = previous.snapshot;
  return {
    ...value,
    snapshot: {
      ...value.snapshot,
      records: reuseSessionHistoryRecords(records, value.snapshot.records),
      recentRecords: reuseSessionHistoryRecords(
        recentRecords,
        value.snapshot.recentRecords
      ),
      liveRecords: reuseSessionHistoryRecords(liveRecords, value.snapshot.liveRecords),
    },
  };
}

/** Read-only projection: data, pagination and request state belong to the host. */
export function useSessionHistory(
  input: SessionHistoryInput,
  mode: "preview" | "latest"
) {
  const consumerId = useId();
  const override = useContext(Context);
  const bridge = override ?? getNativeBridge().sessionHistory;
  const [envelope, setEnvelope] = useState<SessionHistoryEnvelope>();
  const [transportError, setTransportError] = useState(false);
  const { session, groupId, conversationId, participantId } = input;
  const target = useMemo(
    () => ({ session, groupId, conversationId, participantId }),
    [session, groupId, conversationId, participantId]
  );
  const matches = useCallback(
    (value: SessionHistoryEnvelope) =>
      sameSessionProductLease(value.session, target.session) &&
      value.snapshot.groupId === target.groupId &&
      value.snapshot.conversationId === target.conversationId &&
      value.snapshot.participantId === target.participantId,
    [target]
  );
  const liveTarget = useRef<SessionHistoryInput | undefined>(undefined);
  useEffect(() => {
    let active = true;
    liveTarget.current = target;
    const apply = (value: SessionHistoryEnvelope) => {
      if (!active || !matches(value)) return;
      setTransportError(false);
      setEnvelope((previous) => nextEnvelope(previous, value, matches));
    };
    const stop = bridge.state.subscribe(apply, target);
    void bridge
      .retain({ ...target, consumerId })
      .then(() => (active ? bridge.load({ ...target, mode }) : undefined))
      .then(
        (value) => {
          if (value) apply(value);
        },
        () => {
          if (active) setTransportError(true);
        }
      );
    return () => {
      active = false;
      if (liveTarget.current === target) liveTarget.current = undefined;
      stop();
      void bridge.release({ ...target, consumerId }).catch(() => {});
    };
  }, [bridge, target, mode, consumerId, matches]);
  const load = (nextMode: "latest" | "older" | "preview") => {
    setTransportError(false);
    void bridge.load({ ...target, mode: nextMode }).then(
      (value) => {
        if (liveTarget.current === target && matches(value))
          setEnvelope((previous) => nextEnvelope(previous, value, matches));
      },
      () => {
        if (liveTarget.current === target) setTransportError(true);
      }
    );
  };
  return {
    snapshot: envelope && matches(envelope) ? envelope.snapshot : undefined,
    transportError,
    load,
  };
}

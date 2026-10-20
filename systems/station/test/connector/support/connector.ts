// A connector with a claimed connection, as the Go tests build one (`claimConnection`, `setIdentity`,
// `dispatchSession`): frames it sends go to `onFrame`, and a stream chunk is acknowledged unless `onFrame` says not.
import { Effect, Exit } from "effect";
import { type Connector, type ConnectorConfig, type Message, type Session, makeConnector } from "../../../src/connector/connector.ts";

export type Identity = {
  runId: string;
  deviceId: string;
  connectorId: string;
  ownerUserId: string;
  generation: number;
};

export const EXACT: Identity = {
  runId: "run_exact",
  deviceId: "dev_exact",
  connectorId: "connector_exact",
  ownerUserId: "user_exact",
  generation: 17,
};

export function connectorWith(cfg: Partial<ConnectorConfig>): Connector {
  return makeConnector(cfg);
}

/** Claims a connection whose frames go to `onFrame`. */
export function claim(c: Connector, onFrame: (frame: Message, session: Session) => void = () => {}): Session {
  let session: Session | undefined;
  session = c.claimConnection((frame) => Effect.sync(() => onFrame(frame, session!)));
  return session;
}

/** Acknowledges every data chunk, as Salix does. */
export function acking(onFrame: (frame: Message, session: Session) => void = () => {}) {
  return (frame: Message, session: Session) => {
    onFrame(frame, session);
    if (frame.stream?.data) session.completePendingAck(frame.id!, frame.stream.seq ?? 0, "");
  };
}

export function bind(c: Connector, session: Session, identity: Identity = EXACT): boolean {
  return c.setIdentity(session, identity);
}

/** A request's outcome: its result, or the error it failed with. */
export async function dispatch(
  c: Connector,
  session: Session,
  id: string,
  method: string,
  params: Record<string, unknown>,
): Promise<{ ok: true; result: unknown } | { ok: false; error: unknown }> {
  const exit = await Effect.runPromiseExit(c.dispatchSession(session, id, method, params));
  return Exit.isSuccess(exit) ? { ok: true, result: exit.value } : { ok: false, error: exit.cause };
}

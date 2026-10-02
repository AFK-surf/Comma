import { getNativeBridge } from "@comma/native-bridge";
import { useCallback, useContext, useEffect, useRef, useState } from "react";
import { CommaAuthContext } from "../auth-context";

export type TokenDanceConnectState =
  | { status: "idle" }
  | { status: "pending" }
  | { status: "saving" }
  | { status: "failed"; error: string };

/** TokenDance signs in through the desktop app, which keeps the key in Main. */
export const tokenDanceAvailable = () => getNativeBridge().platform === "electron";

/**
 * One-click TokenDance: the browser authorizes, the desktop app receives the
 * key and saves it as one profile serving every chat model TokenDance lists.
 * `onSaved` runs once the profile exists.
 */
export function useTokenDanceConnect(
  workspace: string | undefined,
  name: string,
  onSaved: () => void | Promise<void>
) {
  const session = useContext(CommaAuthContext)?.productLease;
  const [state, setState] = useState<TokenDanceConnectState>({ status: "idle" });
  const active = useRef<string | undefined>(undefined);
  const saved = useRef(onSaved);
  saved.current = onSaved;

  const reset = useCallback(() => {
    const id = active.current;
    active.current = undefined;
    setState({ status: "idle" });
    if (id && session)
      void getNativeBridge()
        .tokenDanceAuthorization.cancel({ session, requestId: id })
        .catch(() => undefined);
  }, [session]);

  useEffect(() => reset, [reset, workspace]);

  const save = useCallback(
    async (requestId: string) => {
      if (!session || active.current !== requestId) return;
      setState({ status: "saving" });
      const result = await getNativeBridge().tokenDanceAuthorization.save({
        session,
        requestId,
        name,
      });
      if (active.current !== requestId) return;
      if (!result.ok) throw new Error("model_save_failed");
      active.current = undefined;
      setState({ status: "idle" });
      await saved.current();
    },
    [name, session]
  );

  const start = useCallback(() => {
    if (!workspace || !session || active.current) return;
    const requestId = crypto.randomUUID();
    active.current = requestId;
    setState({ status: "pending" });
    const fail = (error: string) => {
      if (active.current !== requestId) return;
      active.current = undefined;
      setState({ status: "failed", error });
    };
    void (async () => {
      const bridge = getNativeBridge();
      let result = await bridge.tokenDanceAuthorization.start({
        session,
        requestId,
        workspaceId: workspace,
      });
      // One local status read per second, for one attempt and at most ten
      // minutes; Main makes no provider requests while it waits.
      const deadline = Date.now() + 600_000;
      while (result.status === "pending") {
        if (Date.now() >= deadline) throw new Error("authorization_expired");
        await new Promise((resolve) => setTimeout(resolve, 1000));
        if (active.current !== requestId) return;
        result = await bridge.tokenDanceAuthorization.status({ session, requestId });
      }
      if (active.current !== requestId) return;
      if (result.status === "failed")
        throw new Error(result.error ?? "authorization_failed");
      await save(requestId);
    })().catch((reason: unknown) =>
      fail(reason instanceof Error ? reason.message : "authorization_failed")
    );
  }, [save, session, workspace]);

  return { state, start, reset };
}

import { useCall, type ModelProfile } from "@comma/core-client";
import { getNativeBridge } from "@comma/native-bridge";
import { useCallback, useEffect, useRef, useState } from "react";

export type TokenDanceConnectState =
  | { status: "idle" }
  | { status: "pending" }
  | { status: "failed"; error: string };

/** TokenDance signs in through the desktop app: the browser returns to its client core, which keeps the key. */
export const tokenDanceAvailable = () => getNativeBridge().platform === "electron";

/**
 * One-click TokenDance: the browser authorizes, the client core receives the
 * key and saves it as one profile serving every chat model TokenDance lists
 * (`models.tokenDance.connect`). `onSaved` receives the profile once it exists.
 */
export function useTokenDanceConnect(
  workspace: string | undefined,
  name: string,
  onSaved: (profile: ModelProfile) => void | Promise<void>
) {
  const call = useCall();
  const [state, setState] = useState<TokenDanceConnectState>({ status: "idle" });
  const active = useRef<AbortController | undefined>(undefined);
  const saved = useRef(onSaved);
  saved.current = onSaved;

  const reset = useCallback(() => {
    active.current?.abort();
    active.current = undefined;
    setState({ status: "idle" });
  }, []);

  useEffect(() => reset, [reset, workspace]);

  const start = useCallback(() => {
    if (!workspace || active.current) return;
    const controller = new AbortController();
    active.current = controller;
    setState({ status: "pending" });
    call("models.tokenDance.connect", { workspace, name }, controller.signal).then(
      async (profile) => {
        if (active.current !== controller) return;
        active.current = undefined;
        setState({ status: "idle" });
        await saved.current(profile);
      },
      (reason: unknown) => {
        if (active.current !== controller) return;
        active.current = undefined;
        const code = (reason as { code?: unknown } | null)?.code;
        setState({
          status: "failed",
          error: typeof code === "string" ? code : "authorization_failed",
        });
      }
    );
  }, [call, name, workspace]);

  return { state, start, reset };
}

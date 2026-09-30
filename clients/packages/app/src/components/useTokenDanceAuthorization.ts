import { useCallback, useContext, useEffect, useRef, useState } from "react";
import {
  getNativeBridge,
  type TokenDanceAuthorizationStatus,
} from "@comma/native-bridge";
import { CommaAuthContext } from "./auth-context";

export function useTokenDanceAuthorization(
  workspaceId: string | undefined,
  enabled: boolean
) {
  const session = useContext(CommaAuthContext)?.productLease;
  const [requestId, setRequestId] = useState<string>();
  const [result, setResult] = useState<TokenDanceAuthorizationStatus>();
  const active = useRef<string | undefined>(undefined);
  const reset = useCallback(() => {
    const id = active.current;
    active.current = undefined;
    setRequestId(undefined);
    setResult(undefined);
    if (id && session)
      void getNativeBridge()
        .tokenDanceAuthorization.cancel({ session, requestId: id })
        .catch(() => undefined);
  }, [session]);

  useEffect(() => {
    reset();
    return reset;
  }, [workspaceId, enabled, reset]);

  const start = async () => {
    if (!workspaceId || !session || !enabled || active.current) return;
    const id = crypto.randomUUID();
    active.current = id;
    setRequestId(id);
    setResult({ status: "pending" });
    try {
      const next = await getNativeBridge().tokenDanceAuthorization.start({
        session,
        requestId: id,
        workspaceId,
      });
      if (active.current === id) setResult(next);
    } catch {
      if (active.current === id)
        setResult({ status: "failed", error: "authorization_failed" });
    }
  };

  // One local status read per second, for one attempt and at most ten minutes.
  // No provider or per-model requests occur during polling.
  useEffect(() => {
    if (!requestId || !session || result?.status !== "pending") return;
    let stopped = false;
    let timer: ReturnType<typeof setTimeout>;
    const deadline = Date.now() + 600_000;
    const poll = async () => {
      try {
        if (Date.now() >= deadline) throw new Error("authorization_expired");
        const next = await getNativeBridge().tokenDanceAuthorization.status({
          session,
          requestId,
        });
        if (stopped || active.current !== requestId) return;
        if (next.status === "pending") timer = setTimeout(poll, 1000);
        else setResult(next);
      } catch {
        if (!stopped && active.current === requestId)
          setResult({ status: "failed", error: "authorization_expired" });
      }
    };
    timer = setTimeout(poll, 1000);
    return () => {
      stopped = true;
      clearTimeout(timer);
    };
  }, [requestId, result?.status, session]);

  const save = async (input: {
    model: string;
    name: string;
    maxTokens: number;
    contextTokens: number;
  }) => {
    if (!requestId || !session) throw new Error("authorization_unavailable");
    const saved = await getNativeBridge().tokenDanceAuthorization.save({
      ...input,
      session,
      requestId,
    });
    if (!saved.ok) throw new Error("model_save_failed");
  };
  return { requestId, result, start, reset, save };
}

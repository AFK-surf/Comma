import { useEffect, useState } from "react";
import { workerMeshGradientStyle } from "./workerAvatar";

/** Match the public actor identity used by Task participants, without changing message authorship. */
async function publicWorkerIdentity(agentId: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(agentId)
  );
  const encoded = btoa(String.fromCharCode(...new Uint8Array(digest)))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
  return `actor_${encoded}`;
}

export function useMessageWorkerAvatar(agentId: string | undefined) {
  const [identity, setIdentity] = useState<{ agentId: string; actorId: string }>();
  useEffect(() => {
    if (!agentId) return;
    let active = true;
    void publicWorkerIdentity(agentId).then(
      (actorId) => {
        if (active) setIdentity({ agentId, actorId });
      },
      () => {
        if (active) setIdentity(undefined);
      }
    );
    return () => {
      active = false;
    };
  }, [agentId]);
  return agentId && identity?.agentId === agentId
    ? workerMeshGradientStyle(identity.actorId)
    : undefined;
}

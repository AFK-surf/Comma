import { useCall } from "@comma/core-client";
import { useCallback, useEffect, useState } from "react";
import { useActiveWorkspace } from "../activeWorkspace";

type Held = { group: string; content: string; hash: string | undefined };

/**
 * Settings › General › System prompt: the instructions the active
 * workspace's Router follows on top of its own, the same text Drive's System
 * Files show as `Instructions.md`. Only the owner reaches them. A save or a
 * reset names the text it started from: one made meanwhile elsewhere (Drive)
 * refuses it with `changed` and the text now held shows.
 */
export function useRouterInstructions(enabled: boolean) {
  const call = useCall();
  const groupId = useActiveWorkspace(enabled)?.workspace?.groupId;
  const [held, setHeld] = useState<Held>();
  const [busy, setBusy] = useState(false);
  const [failure, setFailure] = useState<"load" | "save" | "changed">();

  const load = useCallback(
    async (group: string) => {
      try {
        const read = (await call("systemFiles.instructions", { group })) as {
          content: string;
          hash?: string | null;
        };
        setHeld({ group, content: read.content, hash: read.hash ?? undefined });
      } catch {
        setFailure("load");
      }
    },
    [call]
  );

  useEffect(() => {
    if (!enabled || !groupId) return;
    setFailure(undefined);
    void load(groupId);
  }, [enabled, groupId, load]);

  const current = held && held.group === groupId ? held : undefined;

  /** Resolves true once saved; empty `content` clears them. */
  const save = useCallback(
    async (content: string) => {
      if (!current) return false;
      setBusy(true);
      setFailure(undefined);
      try {
        const saved = (await call("systemFiles.writeInstructions", {
          group: current.group,
          content,
          ...(current.hash ? { expectedHash: current.hash } : {}),
        })) as { content: string; hash?: string | null };
        setHeld({
          group: current.group,
          content: saved.content,
          hash: saved.hash ?? undefined,
        });
        return true;
      } catch (error) {
        const changed = (error as { status?: unknown } | null)?.status === 409;
        if (changed) await load(current.group);
        setFailure(changed ? "changed" : "save");
        return false;
      } finally {
        setBusy(false);
      }
    },
    [call, current, load]
  );

  return {
    /** Undefined until read. */
    content: current?.content,
    busy,
    failure,
    clearFailure: () => setFailure(undefined),
    save,
  };
}

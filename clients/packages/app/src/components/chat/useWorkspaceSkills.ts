import { useCall, useTopic } from "@comma/core-client";
import { useCallback, useEffect, useRef } from "react";
import type { CommaSkill } from "@comma/core/api-schemas";

const none: CommaSkill[] = [];

/** A workspace's skills, as the core keeps them (an empty list while they load). */
export function useWorkspaceSkills(workspaceId: string) {
  return useWorkspaceSkillsState(workspaceId).skills;
}

/** Catalog consumers need errors and retry; chat mentions keep the array API. */
export function useWorkspaceSkillsState(workspaceId: string) {
  const call = useCall();
  const { value } = useTopic(
    workspaceId ? { topic: "skills", workspace: workspaceId } : null
  );
  const retry = useCallback(() => {
    if (workspaceId)
      void call("skills.refresh", { workspace: workspaceId }).catch(() => undefined);
  }, [call, workspaceId]);
  // A surface opening on a catalog whose last read already failed reads it again at once.
  const opened = useRef<{ workspaceId: string; failed: boolean }>(undefined);
  if (opened.current?.workspaceId !== workspaceId)
    opened.current = { workspaceId, failed: value?.status === "error" };
  useEffect(() => {
    if (opened.current?.failed) retry();
  }, [retry]);
  if (!workspaceId) return { status: "ready" as const, skills: none, retry };
  return {
    status: value?.status ?? ("loading" as const),
    skills: (value?.skills ?? none) as CommaSkill[],
    retry,
  };
}

import { useCallback, useEffect, useState } from "react";
import type { CommaApiClient, CommaSkill } from "../../api";

const skillsCacheTtlMs = 5 * 60 * 1000;
type SkillsCacheEntry =
  | { state: "loading"; promise: Promise<CommaSkill[]> }
  | { state: "ready"; fetchedAt: number; skills: CommaSkill[] };
let skillsCaches = new WeakMap<CommaApiClient, Map<string, SkillsCacheEntry>>();

type SkillsState = {
  status: "loading" | "ready" | "error";
  skills: CommaSkill[];
};

export function useWorkspaceSkills(api: CommaApiClient, workspaceId: string) {
  return useWorkspaceSkillsState(api, workspaceId).skills;
}

/** Catalog consumers need errors and retry; chat mentions keep the array API. */
export function useWorkspaceSkillsState(api: CommaApiClient, workspaceId: string) {
  const [revision, setRevision] = useState(0);
  const [result, setResult] = useState(() => ({
    api,
    workspaceId,
    ...initialState(api, workspaceId),
  }));
  const retry = useCallback(() => setRevision((value) => value + 1), []);

  useEffect(() => {
    const update = (state: SkillsState) => setResult({ api, workspaceId, ...state });
    if (!workspaceId) {
      update({ status: "ready", skills: [] });
      return undefined;
    }

    const cached = freshSkillsCacheEntry(api, workspaceId);
    if (cached) {
      update({ status: "ready", skills: cached.skills });
      return undefined;
    }

    let cancelled = false;
    update({ status: "loading", skills: [] });
    void loadWorkspaceSkills(api, workspaceId)
      .then((skills) => {
        if (!cancelled) update({ status: "ready", skills });
      })
      .catch(() => {
        if (!cancelled) update({ status: "error", skills: [] });
      });

    return () => {
      cancelled = true;
    };
  }, [api, workspaceId, revision]);

  const state =
    result.api === api && result.workspaceId === workspaceId
      ? result
      : initialState(api, workspaceId);
  return { status: state.status, skills: state.skills, retry };
}

function initialState(api: CommaApiClient, workspaceId: string): SkillsState {
  const cached = freshSkillsCacheEntry(api, workspaceId);
  return {
    status: !workspaceId || cached ? "ready" : "loading",
    skills: cached?.skills ?? [],
  };
}

export function resetWorkspaceSkillsCacheForTest() {
  skillsCaches = new WeakMap();
}

function sessionSkillsCache(api: CommaApiClient) {
  let cache = skillsCaches.get(api);
  if (!cache) {
    cache = new Map();
    skillsCaches.set(api, cache);
  }
  return cache;
}

function freshSkillsCacheEntry(api: CommaApiClient, workspaceId: string) {
  const cached = skillsCaches.get(api)?.get(workspaceId);
  return cached?.state === "ready" && Date.now() - cached.fetchedAt < skillsCacheTtlMs
    ? cached
    : undefined;
}

function loadWorkspaceSkills(api: CommaApiClient, workspaceId: string) {
  const cache = sessionSkillsCache(api);
  const cached = freshSkillsCacheEntry(api, workspaceId);
  if (cached) {
    return Promise.resolve(cached.skills);
  }

  const current = cache.get(workspaceId);
  if (current?.state === "loading") {
    return current.promise;
  }

  const promise = api
    .listWorkspaceSkills(workspaceId)
    .then((skills) => {
      cache.set(workspaceId, {
        fetchedAt: Date.now(),
        skills,
        state: "ready",
      });
      return skills;
    })
    .catch((error: unknown) => {
      // Failed requests are not successful empty catalogs. Allow immediate retry.
      cache.delete(workspaceId);
      throw error;
    });
  cache.set(workspaceId, { promise, state: "loading" });
  return promise;
}

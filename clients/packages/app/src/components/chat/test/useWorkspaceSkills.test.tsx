import { act, render, screen, waitFor } from "@comma/test-utils/render";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { CommaApiClient, CommaSkill } from "../../../api";
import { testProductLease } from "../../../test/productInboxProjectionHarness";
import { ChatProvider, useChatApi } from "../ChatProvider";
import {
  resetWorkspaceSkillsCacheForTest,
  useWorkspaceSkills,
} from "../useWorkspaceSkills";

describe("useWorkspaceSkills", () => {
  afterEach(() => {
    resetWorkspaceSkillsCacheForTest();
    vi.useRealTimers();
  });

  it("fetches skills once per workspace and serves the cache", async () => {
    const api = createApi([skill("weekly-summary")]);

    const { rerender } = render(<SkillsProbe api={api} workspaceId="wsp_1" />);
    await screen.findByText("weekly-summary");
    rerender(<SkillsProbe api={api} workspaceId="wsp_1" />);

    expect(api.listWorkspaceSkills).toHaveBeenCalledTimes(1);
  });

  it("coalesces concurrent consumers for the same workspace", async () => {
    const pending = deferred<CommaSkill[]>();
    const api = createApi([]);
    vi.mocked(api.listWorkspaceSkills).mockReturnValue(pending.promise);

    render(
      <>
        <SkillsProbe api={api} workspaceId="wsp_shared" />
        <SkillsProbe api={api} workspaceId="wsp_shared" />
      </>
    );

    await waitFor(() => expect(api.listWorkspaceSkills).toHaveBeenCalledTimes(1));
    await act(async () => {
      pending.resolve([skill("shared-skill")]);
      await pending.promise;
    });

    expect(screen.getAllByText("shared-skill")).toHaveLength(2);
  });

  it("does not cache failures and retries on the next mount", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-07-10T00:00:00Z"));

    const api = createApi([skill("later")]);
    vi.mocked(api.listWorkspaceSkills).mockRejectedValueOnce(new Error("forbidden"));

    render(<SkillsProbe api={api} workspaceId="wsp_2" />);
    await flushPromises();
    expect(screen.getByText("none")).toBeInTheDocument();

    render(<SkillsProbe api={api} workspaceId="wsp_2" />);
    await flushPromises();
    expect(api.listWorkspaceSkills).toHaveBeenCalledTimes(2);
    expect(screen.getByText("later")).toBeInTheDocument();
  });

  it("caches successful empty lists until the ttl expires", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-07-10T00:00:00Z"));
    const api = createApi([]);
    const first = render(<SkillsProbe api={api} workspaceId="wsp_empty" />);
    await flushPromises();
    first.unmount();
    const second = render(<SkillsProbe api={api} workspaceId="wsp_empty" />);
    await flushPromises();
    expect(api.listWorkspaceSkills).toHaveBeenCalledTimes(1);
    second.unmount();
    vi.setSystemTime(new Date("2026-07-10T00:06:00Z"));
    render(<SkillsProbe api={api} workspaceId="wsp_empty" />);
    await flushPromises();
    expect(api.listWorkspaceSkills).toHaveBeenCalledTimes(2);
  });

  it("does not let a revoked session seed the replacement session cache", async () => {
    const sessionA = new AbortController();
    const sessionB = new AbortController();
    const staleSkills = deferred<CommaSkill[]>();
    const apiA = createApi([]);
    const apiB = createApi([skill("account-b-skill")]);
    vi.mocked(apiA.listWorkspaceSkills).mockReturnValue(staleSkills.promise);

    const accountA = render(
      <ChatProvider
        api={apiA}
        productLease={testProductLease}
        sessionSignal={sessionA.signal}
      >
        <SessionSkillsProbe workspaceId="shared-workspace" />
      </ChatProvider>
    );
    await waitFor(() =>
      expect(apiA.listWorkspaceSkills).toHaveBeenCalledWith("shared-workspace")
    );

    sessionA.abort();
    accountA.unmount();
    await act(async () => {
      staleSkills.resolve([skill("account-a-skill")]);
      await staleSkills.promise;
      await Promise.resolve();
    });

    render(
      <ChatProvider
        api={apiB}
        productLease={testProductLease}
        sessionSignal={sessionB.signal}
      >
        <SessionSkillsProbe workspaceId="shared-workspace" />
      </ChatProvider>
    );

    await waitFor(() =>
      expect(apiB.listWorkspaceSkills).toHaveBeenCalledWith("shared-workspace")
    );
    expect(await screen.findByText("account-b-skill")).toBeInTheDocument();
  });
});

async function flushPromises() {
  await act(async () => {
    await Promise.resolve();
  });
}

function SkillsProbe({
  api,
  workspaceId,
}: {
  api: CommaApiClient;
  workspaceId: string;
}) {
  const skills = useWorkspaceSkills(api, workspaceId);
  return <div>{skills.map((item) => item.skill_id).join(",") || "none"}</div>;
}

function SessionSkillsProbe({ workspaceId }: { workspaceId: string }) {
  return <SkillsProbe api={useChatApi()} workspaceId={workspaceId} />;
}

function createApi(skills: CommaSkill[]) {
  return {
    listWorkspaceSkills: vi.fn(async () => skills),
  } as Partial<CommaApiClient> as CommaApiClient;
}

function skill(skillId: string): CommaSkill {
  return {
    skill_id: skillId,
    name: skillId,
    location: `/.runtime/skills/${skillId}/SKILL.md`,
  };
}

function deferred<T>() {
  let resolve!: (value: T | PromiseLike<T>) => void;
  const promise = new Promise<T>((nextResolve) => {
    resolve = nextResolve;
  });
  return { promise, resolve };
}

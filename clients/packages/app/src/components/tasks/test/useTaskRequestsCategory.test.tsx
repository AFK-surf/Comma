import { act } from "react";
import { flush } from "@comma/test-utils/fake-clock";
import { renderHook } from "@comma/test-utils/render";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import type { ReactNode } from "react";
import { expect, it } from "vitest";
import { useTaskRequestsCategory } from "../useTaskRequestsCategory";

const workspace = { id: "ws-a", groupId: "grp-a", name: "Workspace A" };
const sender = { id: "u2", name: "Sam", email: "sam@example.com" };

it("reviews a waiting request and accepts it with the owner's title", async () => {
  const core = createScriptedCore({
    values: (topic) =>
      topic.topic === "workspace"
        ? { status: "ready", workspace, selected: true }
        : topic.topic === "taskRequests"
          ? {
              workspace: workspace.id,
              incoming: [
                {
                  id: "trq_1",
                  sender,
                  title: "Summarize Q3",
                  content: "Summarize Q3 from the sheet",
                  status: "pending",
                  decline_reason: null,
                  task: null,
                  created_at: 1_790_200_000,
                  expires_at: 1_790_800_000,
                },
              ],
              grants: [],
              targets: [],
              sent: [],
              error: false,
            }
          : undefined,
    calls: (name) => (name === "taskRequests.accept" ? { task: null } : null),
  });
  const { result } = renderHook(() => useTaskRequestsCategory(true), {
    wrapper: ({ children }: { children: ReactNode }) => core.wrap(children),
  });
  await flush();
  const incoming = result.current.sections[0]!.items;
  expect(incoming.map((item) => item.id)).toEqual(["task-requests.incoming.trq_1"]);

  const review = incoming[0]!.control;
  if (review?.type !== "button") throw new Error("no review button");
  act(() => review.onPress?.());
  expect(result.current.detail).toMatchObject({
    id: "task-requests.review",
  });

  await act(async () => {
    result.current.detail?.onSubmit?.();
    await flush();
  });
  expect(core.sentTo("taskRequests.accept")).toEqual([
    { workspace: workspace.id, request: "trq_1", to: "task", title: "Summarize Q3" },
  ]);
  expect(result.current.detail).toBeUndefined();
});

it("shows which chat account is linked and switches how the owner's own requests are taken", async () => {
  const core = createScriptedCore({
    values: (topic) =>
      topic.topic === "workspace"
        ? { status: "ready", workspace, selected: true }
        : topic.topic === "taskRequests"
          ? {
              workspace: workspace.id,
              incoming: [],
              grants: [],
              targets: [],
              sent: [],
              links: [
                {
                  id: "pul_1",
                  provider: "slack",
                  name: "Sam",
                  email: "sam@example.com",
                  workspace: "Acme",
                  bot: "acme-bot",
                  linked_at: 1,
                },
                {
                  id: "pul_2",
                  provider: "lark",
                  name: "Sam",
                  email: null,
                  workspace: "Globex",
                  bot: "globex-bot",
                  linked_at: 2,
                },
              ],
              own: "review",
              error: false,
            }
          : undefined,
    calls: () => null,
  });
  const { result } = renderHook(() => useTaskRequestsCategory(true), {
    wrapper: ({ children }: { children: ReactNode }) => core.wrap(children),
  });
  await flush();
  const links = result.current.sections.at(-1)!.items;
  expect(links.map((item) => item.id)).toEqual([
    "task-requests.link.pul_1",
    "task-requests.link.pul_2",
    "task-requests.own",
  ]);
  expect(links[0]!.description).toContain("sam@example.com · Acme · acme-bot");
  expect(links[0]!.icon).toBeTruthy();
  expect(links[1]!.description).toContain("Lark");
  expect(links[1]!.description).toContain("Globex · globex-bot");
  expect(links[1]!.icon).toBeTruthy();

  const own = links[2]!.control;
  if (own?.type !== "toggle") throw new Error("no switch");
  expect(own.checked).toBe(false);
  await act(async () => {
    own.onChange?.({ target: { checked: true } } as never);
    await flush();
  });
  expect(core.sentTo("taskRequests.setOwnMode")).toEqual([
    { workspace: workspace.id, mode: "auto_accept" },
  ]);
});

const inviteTopic = (topic: Record<string, unknown>) =>
  topic.topic === "workspace"
    ? { status: "ready", workspace, selected: true }
    : topic.topic === "taskRequests"
      ? {
          workspace: workspace.id,
          incoming: [],
          grants: [],
          targets: [],
          sent: [],
          error: false,
        }
      : undefined;
const inviteToken = "a".repeat(43);
const inviteFrom = {
  workspace: { id: "ws-b", name: "Sam's", owner: sender },
  own: false,
  back: { workspace: { id: "ws-mine", name: "Mine" }, mode: "review" },
  expiresAt: 1_790_800_000,
};

it("says what an invite gives the inviter and accepts it in the workspace it named", async () => {
  const core = createScriptedCore({
    values: inviteTopic,
    calls: (name) =>
      name === "taskRequests.invitePreview"
        ? inviteFrom
        : name === "taskRequests.acceptInvite"
          ? { reciprocal: true }
          : null,
  });
  const { result } = renderHook(() => useTaskRequestsCategory(true, inviteToken), {
    wrapper: ({ children }: { children: ReactNode }) => core.wrap(children),
  });
  await flush();
  expect(core.sentTo("taskRequests.invitePreview")).toEqual([
    { invite: inviteToken, workspace: workspace.id },
  ]);
  expect(result.current.detail).toMatchObject({
    id: "task-requests.invite",
    description: expect.stringMatching(/Mine.*wait for your approval/),
  });

  await act(async () => {
    result.current.detail?.onSubmit?.();
    await flush();
  });
  expect(core.sentTo("taskRequests.acceptInvite")).toEqual([
    { invite: inviteToken, workspace: "ws-mine" },
  ]);
  expect(result.current.detail).toBeUndefined();
});

it.each([
  [
    "a kept auto-accept grant",
    { ...inviteFrom, back: { ...inviteFrom.back, mode: "auto_accept" } },
    /without your approval/,
  ],
  [
    "no way back",
    { ...inviteFrom, back: null },
    /won't be able to send requests to you/,
  ],
])("says so with %s", async (_case, preview, words) => {
  const core = createScriptedCore({
    values: inviteTopic,
    calls: (name) => (name === "taskRequests.invitePreview" ? preview : null),
  });
  const { result } = renderHook(() => useTaskRequestsCategory(true, inviteToken), {
    wrapper: ({ children }: { children: ReactNode }) => core.wrap(children),
  });
  await flush();
  expect(result.current.detail?.description).toEqual(expect.stringMatching(words));
});

it.each([
  ["a link that is gone", { status: 404 }, /expired or was already used/],
  ["a read that failed", { status: 503 }, /Couldn't read this invite/],
])("accepts nothing for %s", async (_case, failure, words) => {
  const core = createScriptedCore({
    values: inviteTopic,
    calls: (name) => {
      if (name === "taskRequests.invitePreview") throw failure;
      return null;
    },
  });
  const { result } = renderHook(() => useTaskRequestsCategory(true, inviteToken), {
    wrapper: ({ children }: { children: ReactNode }) => core.wrap(children),
  });
  await flush();
  expect(result.current.detail?.description).toEqual(expect.stringMatching(words));
  await act(async () => {
    result.current.detail?.onSubmit?.();
    await flush();
  });
  expect(core.sentTo("taskRequests.acceptInvite")).toEqual([]);
});

it("accepts nothing for the person's own invite", async () => {
  const core = createScriptedCore({
    values: inviteTopic,
    calls: (name) =>
      name === "taskRequests.invitePreview"
        ? { ...inviteFrom, own: true, back: null }
        : null,
  });
  const { result } = renderHook(() => useTaskRequestsCategory(true, inviteToken), {
    wrapper: ({ children }: { children: ReactNode }) => core.wrap(children),
  });
  await flush();
  await act(async () => {
    result.current.detail?.onSubmit?.();
    await flush();
  });
  expect(core.sentTo("taskRequests.acceptInvite")).toEqual([]);
});

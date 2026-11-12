import { act, renderHook, waitFor } from "@comma/test-utils/render";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import type { MentionTask } from "@comma/core/contract";
import type { ReactNode } from "react";
import { describe, expect, it, vi } from "vitest";
import {
  driveMentionItems,
  driveMentionSections,
  useComposerMentionSources,
} from "../useComposerMentionSources";
import { resetDriveStoreForTest, type DriveFile } from "../../../drive/driveStore";

function task(id: string, title: string): MentionTask {
  return { id, status: "in_progress", title, updatedAt: 1 };
}

describe("useComposerMentionSources", () => {
  it("reads Slack's directory once the menu opens, and asks for a new read each time the menu is used after", async () => {
    const subscribed: unknown[] = [];
    const rereads: unknown[] = [];
    const core = createScriptedCore({
      values: (topic) => {
        if (topic.topic === "plugins")
          return {
            status: "ready",
            plugins: [{ id: "slack", name: "Slack", installed: true }],
          };
        if (topic.topic === "slackDirectory") {
          subscribed.push(topic.workspace);
          return { channels: [], people: [] };
        }
        return undefined;
      },
      calls: (name, params) => {
        if (name === "slackDirectory.reread") rereads.push(params);
        return null;
      },
    });
    const { result } = renderHook(
      () => useComposerMentionSources({ groupId: "group", workspaceId: "workspace" }),
      { wrapper: ({ children }: { children: ReactNode }) => core.wrap(children) }
    );
    await waitFor(() => expect(result.current.plugins.items).toHaveLength(1));
    expect(subscribed).toEqual([]);

    act(() => result.current.drive.onMenuQueryChange?.(""));
    await waitFor(() => expect(subscribed).toContain("workspace"));
    expect(rereads).toEqual([]);

    act(() => result.current.drive.onMenuQueryChange?.(null));
    act(() => result.current.drive.onMenuQueryChange?.(""));
    await waitFor(() => expect(rereads).toEqual([{ workspace: "workspace" }]));
  });

  it("does not expose the previous group's tasks while the next group loads", async () => {
    // What the core has read of each Group's Tasks; none yet is loading.
    const read = new Map<string, MentionTask[]>();
    const core = createScriptedCore({
      values: (topic) =>
        topic.topic === "mentionTasks"
          ? (read.get(String(topic.group)) ?? null)
          : undefined,
    });
    const { rerender, result } = renderHook(
      ({ groupId }: { groupId: string }) =>
        useComposerMentionSources({ groupId, workspaceId: undefined }),
      {
        initialProps: { groupId: "group-a" },
        wrapper: ({ children }: { children: ReactNode }) => core.wrap(children),
      }
    );
    await waitFor(() => expect(result.current.tasks.status).toBe("loading"));

    act(() => {
      read.set("group-a", [task("task-a", "Task from A")]);
      core.changed("mentionTasks");
    });
    await waitFor(() => expect(result.current.tasks.status).toBe("ready"));
    expect(result.current.tasks.items.map((item) => item.title)).toEqual([
      "Task from A",
    ]);

    rerender({ groupId: "group-b" });

    await waitFor(() => expect(result.current.tasks.status).toBe("loading"));
    expect(result.current.tasks.items).toEqual([]);

    act(() => {
      read.set("group-b", [task("task-b", "Task from B")]);
      core.changed("mentionTasks");
    });
    await waitFor(() =>
      expect(result.current.tasks.items.map((item) => item.title)).toEqual([
        "Task from B",
      ])
    );
  });
});

/** A request target's owner as the core lists them. */
const owner = (name: string) => ({ id: name, name, email: null });

describe("request mentions", () => {
  it("offer, in the Router chat, the people the person may ask, once the @ menu first opens", async () => {
    const core = createScriptedCore({
      values: (topic) =>
        topic.topic === "taskRequests"
          ? {
              workspace: "w1",
              targets: [
                {
                  grant_id: "trg_cat",
                  workspace: { id: "w_cat", name: "Cats", owner: owner("CatsJuice") },
                  mode: "review",
                  daily_limit: 20,
                  pending_limit: 10,
                  sent_today: 1,
                  pending: 0,
                },
                {
                  grant_id: "trg_bo",
                  workspace: { id: "w_bo", name: "Bo's", owner: owner("Bo") },
                  mode: "review",
                  daily_limit: 5,
                  pending_limit: 10,
                  sent_today: 5,
                  pending: 0,
                },
              ],
            }
          : undefined,
    });
    const { result } = renderHook(
      ({ models }: { models: boolean }) =>
        useComposerMentionSources({ groupId: "g1", models, workspaceId: "w1" }),
      {
        initialProps: { models: true },
        wrapper: ({ children }: { children: ReactNode }) => core.wrap(children),
      }
    );
    // Nothing is read until the menu opens.
    expect(result.current.requests).toEqual({ items: [], status: "ready" });
    act(() => result.current.drive.onMenuQueryChange?.(""));
    await waitFor(() => expect(result.current.requests.status).toBe("ready"));
    expect(result.current.requests.items).toEqual([
      {
        grantId: "trg_cat",
        name: "CatsJuice",
        workspace: "Cats",
        full: false,
        email: null,
      },
      // Their day's requests are spent: offered, but it cannot be chosen.
      { grantId: "trg_bo", name: "Bo", workspace: "Bo's", full: true, email: null },
    ]);
  });
});

function driveFile(
  id: string,
  name: string,
  modifiedAt: number,
  extra: Partial<DriveFile> = {}
): DriveFile {
  return {
    contentsHash: `hash-${id}`,
    deviceId: "this-mac",
    id,
    modifiedAt,
    name,
    sizeBytes: 1,
    spaceId: "space-a",
    ...extra,
  };
}

describe("Drive mention items", () => {
  const spaces = [
    { id: "space-a", name: "Folder A" },
    { id: "space-b", name: "Recordings" },
  ];
  const files = [
    driveFile("old", "old.pdf", 10, { blob: new Blob(["o"]) }),
    driveFile("new", "new.png", 30, { folderPath: "drafts/q3" }),
    driveFile("mid", "mid.wav", 20, { blob: new Blob(["m"]), spaceId: "space-b" }),
    driveFile("also-new", "also-new.txt", 30, { folderPath: "drafts/q3" }),
  ];

  it("lists files newest first with where they live, reading through the core", async () => {
    const readFile = vi.fn((file: DriveFile) => Promise.resolve(new Blob([file.name])));
    const items = driveMentionItems({ files, spaces }, readFile);
    expect(items.map((item) => [item.file.id, item.location])).toEqual([
      ["new", "Folder A / drafts / q3"],
      ["also-new", "Folder A / drafts / q3"],
      ["mid", "Recordings"],
      ["old", "Folder A"],
    ]);
    await expect(items[0]!.read().then((blob) => blob.size)).resolves.toBe(7);
    expect(readFile).toHaveBeenCalledWith(files[1]);
  });

  it("groups the browse sections by folder, newest folder first", () => {
    const sections = driveMentionSections(
      driveMentionItems({ files, spaces }, (file) =>
        Promise.resolve(new Blob([file.name]))
      )
    );
    expect(
      sections.map((section) => [
        section.label,
        section.items.map((item) => item.file.id),
      ])
    ).toEqual([
      ["Folder A / drafts / q3", ["new", "also-new"]],
      ["Recordings", ["mid"]],
      ["Folder A", ["old"]],
    ]);
  });

  it("reads the core's Drive once the @ menu opens when the client has no node", async () => {
    // The window's Drive store is built on first use; build it for this window.
    resetDriveStoreForTest();
    const subscribed: unknown[] = [];
    const core = createScriptedCore({
      onSubscribe: (topic) => subscribed.push(topic.topic),
      values: (topic) =>
        topic.topic === "drive"
          ? {
              node: { status: "off" },
              devices: [],
              spaces,
              files,
              originDeviceId: "",
              versionPolicy: "newest",
              localSyncEnabled: false,
              localSyncRoot: "",
              syncHistory: [],
              transfers: [],
            }
          : undefined,
    });
    const { result } = renderHook(
      () => useComposerMentionSources({ groupId: undefined, workspaceId: undefined }),
      { wrapper: ({ children }) => core.wrap(children) }
    );
    // A composer shown without its menu reads no Drive.
    expect(subscribed).not.toContain("drive");
    expect(result.current.drive.items).toEqual([]);
    act(() => result.current.drive.onMenuQueryChange?.(""));
    await waitFor(() =>
      expect(result.current.drive.items.map((item) => item.file.id)).toEqual([
        "new",
        "also-new",
        "mid",
        "old",
      ])
    );
    expect(subscribed).toContain("drive");
  });
});

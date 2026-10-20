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

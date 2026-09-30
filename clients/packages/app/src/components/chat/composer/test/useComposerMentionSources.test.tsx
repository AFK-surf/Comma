import { act, renderHook, waitFor } from "@comma/test-utils/render";
import type { CommaApiClient, CommaConversation } from "../../../../api";
import { beforeEach, describe, expect, it, vi } from "vitest";
import {
  driveMentionItems,
  driveMentionSections,
  resetComposerMentionSourcesCacheForTest,
  useComposerMentionSources,
} from "../useComposerMentionSources";
import type { DriveFile } from "../../../drive/driveStore";

function deferred<Value>() {
  let resolve!: (value: Value) => void;
  const promise = new Promise<Value>((next) => {
    resolve = next;
  });
  return { promise, resolve };
}

function task(groupId: string, id: string, title: string): CommaConversation {
  return {
    group_id: groupId,
    id,
    kind: "agent_task",
    status: "in_progress",
    title,
    updated_at: 1,
  };
}

describe("useComposerMentionSources", () => {
  beforeEach(() => {
    resetComposerMentionSourcesCacheForTest();
  });

  it("does not expose the previous group's tasks while the next group loads", async () => {
    const groupA = deferred<CommaConversation[]>();
    const groupB = deferred<CommaConversation[]>();
    const listConversations = vi.fn((groupId: string) =>
      groupId === "group-a" ? groupA.promise : groupB.promise
    );
    const api = { listConversations } as Partial<CommaApiClient> as CommaApiClient;

    const { rerender, result } = renderHook(
      ({ groupId }: { groupId: string }) =>
        useComposerMentionSources({
          api,
          groupId,
          workspaceId: undefined,
        }),
      { initialProps: { groupId: "group-a" } }
    );

    await act(async () => {
      groupA.resolve([task("group-a", "task-a", "Task from A")]);
      await groupA.promise;
    });
    await waitFor(() => expect(result.current.tasks.status).toBe("ready"));
    expect(result.current.tasks.items.map((item) => item.title)).toEqual([
      "Task from A",
    ]);

    rerender({ groupId: "group-b" });

    await waitFor(() => expect(result.current.tasks.status).toBe("loading"));
    expect(result.current.tasks.items).toEqual([]);

    await act(async () => {
      groupB.resolve([task("group-b", "task-b", "Task from B")]);
      await groupB.promise;
    });
    await waitFor(() =>
      expect(result.current.tasks.items.map((item) => item.title)).toEqual([
        "Task from B",
      ])
    );
    expect(listConversations).toHaveBeenCalledWith("group-a");
    expect(listConversations).toHaveBeenCalledWith("group-b");
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

  it("lists files newest first with where they live, reading through the node", async () => {
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

  it("keeps only files whose bytes are here when there is no node", async () => {
    const items = driveMentionItems({ files, spaces }, undefined);
    expect(items.map((item) => item.file.id)).toEqual(["mid", "old"]);
    await expect(items[1]!.read().then((blob) => blob.size)).resolves.toBe(1);
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

  it("serves the demo store's attachable files when the client has no node", async () => {
    const { result } = renderHook(() =>
      useComposerMentionSources({
        api: undefined,
        groupId: undefined,
        workspaceId: undefined,
      })
    );
    await waitFor(() => expect(result.current.drive.status).toBe("ready"));
    expect(result.current.drive.items.map((item) => item.file.name)).toEqual([
      "Screenshot 2026-08-29 at 10.47.png",
      "logo-mark.svg",
      "sound.wav",
    ]);
  });
});

import { describe, expect, it, vi } from "vitest";
import { getNativeBridge } from "@comma/native-bridge";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import type { CallFn } from "@comma/core-client";
import {
  createFileOpenInAction,
  createResolvedFileOpenInAction,
} from "../runtime-files/fileOpenActions";
import type { ConversationFileSource } from "../runtime-files/fileSources";

const applicationId = `fap1_${"b".repeat(43)}`;
const source: ConversationFileSource = {
  groupId: "group",
  conversationId: "conversation",
  messageId: "message",
  attachmentIndex: 0,
  fileName: "report.pdf",
};
const saved = {
  fileName: "report.pdf",
  downloadRef: `dnl1_${"a".repeat(43)}`,
};
type Save = (name: string, params: unknown) => Promise<unknown>;
const callWith = (save: Save = vi.fn(async () => saved)) => save as unknown as CallFn;
const attempt =
  (controller = new AbortController()) =>
  () => ({
    signal: controller.signal,
    isCurrent: () => !controller.signal.aborted,
    release: vi.fn(),
  });
const deferred = <T>() => {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => {
    resolve = done;
  });
  return { promise, resolve };
};

function setup(call = callWith(), file = source, beginAttempt = attempt()) {
  const saveDownload = vi.fn(async () => ({ status: "saved" as const, ...saved }));
  const openDownload = vi.fn(async () => ({ status: "opened" as const }));
  const revealDownload = vi.fn(async () => ({ status: "revealed" as const }));
  const listOpenApplications = vi.fn(async () => ({
    status: "available" as const,
    applications: [{ id: applicationId, name: "Preview", isDefault: true }],
  }));
  installNativeBridgeMock({
    platform: "electron",
    os: "macos",
    files: { saveDownload, openDownload, revealDownload, listOpenApplications },
  });
  const bridge = getNativeBridge();
  const action = createFileOpenInAction({
    call,
    source: file,
    bridge,
    locale: "en",
    beginAttempt,
  })!;
  return {
    action,
    beginAttempt,
    call,
    bridge,
    saveDownload,
    openDownload,
    revealDownload,
    listOpenApplications,
  };
}

describe("file open actions", () => {
  it("discovers applications without saving, and reuses the file the core saved for open and reveal", async () => {
    const { action, call, saveDownload, openDownload, revealDownload } = setup();
    expect(await action.listApplications()).toHaveLength(1);
    expect(call).not.toHaveBeenCalled();
    await action.openApplication(applicationId);
    await action.reveal!.run();
    expect(call).toHaveBeenCalledTimes(1);
    expect(call).toHaveBeenCalledWith("files.save", {
      source: {
        source: "attachment",
        group: "group",
        conversation: "conversation",
        message: "message",
        index: 0,
      },
      name: "report.pdf",
    });
    // Main writes the file as it arrives: no bytes cross into the window.
    expect(saveDownload).not.toHaveBeenCalled();
    expect(openDownload).toHaveBeenCalledWith({
      downloadRef: saved.downloadRef,
      applicationId: applicationId,
    });
    expect(revealDownload).toHaveBeenCalledWith({ downloadRef: saved.downloadRef });
  });

  it("never reuses a same-name receipt across source addresses or Sessions", async () => {
    const { action, beginAttempt, call, bridge } = setup();
    await action.openApplication(applicationId);
    await createFileOpenInAction({
      call,
      bridge,
      source: { ...source, conversationId: "other" },
      locale: "en",
      beginAttempt,
    })!.openApplication(applicationId);
    // Another Session's attempts: its saved files are its own.
    await createFileOpenInAction({
      call,
      bridge,
      source,
      locale: "en",
      beginAttempt: attempt(),
    })!.openApplication(applicationId);
    expect(call).toHaveBeenCalledTimes(3);
  });

  it("does not open a file saved after cancellation, and reuses it on the next action", async () => {
    const save = deferred<typeof saved>();
    const call = vi.fn<Save>(() => save.promise);
    const { action, openDownload } = setup(callWith(call));
    const cancelled = new AbortController();
    const result = action.openApplication(applicationId, cancelled.signal);
    const failure = expect(result).rejects.toMatchObject({ name: "AbortError" });
    await vi.waitFor(() => expect(call).toHaveBeenCalledTimes(1));
    cancelled.abort();
    save.resolve(saved);
    await failure;
    expect(openDownload).not.toHaveBeenCalled();
    await action.openApplication(applicationId);
    expect(call).toHaveBeenCalledTimes(1);
    expect(openDownload).toHaveBeenCalledTimes(1);
  });

  it("never opens after Session revocation, including when a receipt was already cached", async () => {
    const session = new AbortController();
    const { action, openDownload } = setup(callWith(), source, attempt(session));
    await action.openApplication(applicationId);
    session.abort();
    await expect(action.openApplication(applicationId)).rejects.toMatchObject({
      name: "AbortError",
    });
    expect(openDownload).toHaveBeenCalledTimes(1);
  });

  it("does not open a file the core could not save", async () => {
    const call = vi.fn<Save>(async () => saved);
    const { action, openDownload } = setup(callWith(call));
    call.mockRejectedValueOnce(new Error("404"));
    await expect(action.openApplication(applicationId)).rejects.toThrow("404");
    call.mockResolvedValueOnce(null);
    await expect(action.openApplication(applicationId)).rejects.toThrow();
    expect(openDownload).not.toHaveBeenCalled();
  });

  it("does not expose native applications on web or other operating systems", () => {
    const { call, bridge } = setup();
    expect(
      createFileOpenInAction({
        call,
        bridge: { ...bridge, platform: "web" },
        source,
        locale: "en",
        beginAttempt: attempt(),
      })
    ).toBeUndefined();
    expect(
      createFileOpenInAction({
        call,
        bridge: { ...bridge, os: "windows" },
        source,
        locale: "en",
        beginAttempt: attempt(),
      })
    ).toBeUndefined();
  });

  it("retires an unavailable saved file and saves again only after the next user action", async () => {
    const { action, call, openDownload } = setup();
    await action.openApplication(applicationId);
    openDownload.mockResolvedValueOnce({ status: "unavailable" } as never);
    await expect(action.openApplication(applicationId)).rejects.toThrow();
    expect(openDownload).toHaveBeenCalledTimes(2);
    expect(call).toHaveBeenCalledTimes(1);
    await action.openApplication(applicationId);
    expect(call).toHaveBeenCalledTimes(2);
    expect(openDownload).toHaveBeenCalledTimes(3);
  });

  it("bounds completed receipts", async () => {
    const { action, beginAttempt, call, bridge } = setup();
    await action.openApplication(applicationId);
    for (let index = 0; index < 32; index += 1) {
      await createFileOpenInAction({
        call,
        bridge,
        source: { ...source, messageId: `message-${index}` },
        locale: "en",
        beginAttempt,
      })!.openApplication(applicationId);
    }
    await action.openApplication(applicationId);
    expect(call).toHaveBeenCalledTimes(34);
  });

  it("rejects bytes an adapter read above the native save's bound before saving", async () => {
    const { bridge, saveDownload } = setup();
    const action = createResolvedFileOpenInAction({
      owner: {},
      sourceKey: "drive-file",
      fileName: "big.bin",
      resolveBytes: async () => new Blob([new Uint8Array(10_000_001)]),
      bridge,
      locale: "en",
      beginAttempt: attempt(),
    })!;
    await expect(action.openApplication(applicationId)).rejects.toThrow();
    expect(saveDownload).not.toHaveBeenCalled();
  });
});

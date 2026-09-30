import { describe, expect, it, vi } from "vitest";
import { getNativeBridge } from "@comma/native-bridge";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import type { CommaApiClient } from "../api";
import { createFileOpenInAction } from "../runtime-files/fileOpenActions";
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
  status: "saved" as const,
  fileName: "report.pdf",
  downloadRef: `dnl1_${"a".repeat(43)}`,
};
const apiWith = (read = vi.fn(async () => new Blob(["pdf bytes"]))) =>
  ({ fetchConversationAttachment: read }) as unknown as CommaApiClient;
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

function setup(api = apiWith(), file = source, beginAttempt = attempt()) {
  const saveDownload = vi.fn(async () => saved);
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
    api,
    source: file,
    bridge,
    locale: "en",
    beginAttempt,
  })!;
  return {
    action,
    api,
    bridge,
    saveDownload,
    openDownload,
    revealDownload,
    listOpenApplications,
  };
}

describe("file open actions", () => {
  it("discovers applications without retrieving bytes and reuses a completed save for open and reveal", async () => {
    const { action, api, saveDownload, openDownload, revealDownload } = setup();
    expect(await action.listApplications()).toHaveLength(1);
    expect(api.fetchConversationAttachment).not.toHaveBeenCalled();
    await action.openApplication(applicationId);
    await action.reveal!.run();
    expect(saveDownload).toHaveBeenCalledTimes(1);
    expect(openDownload).toHaveBeenCalledWith({
      downloadRef: saved.downloadRef,
      applicationId: applicationId,
    });
    expect(revealDownload).toHaveBeenCalledWith({ downloadRef: saved.downloadRef });
  });

  it("never reuses a same-name receipt across source addresses or API generations", async () => {
    const { action, api, bridge, saveDownload } = setup();
    await action.openApplication(applicationId);
    await createFileOpenInAction({
      api,
      bridge,
      source: { ...source, conversationId: "other" },
      locale: "en",
      beginAttempt: attempt(),
    })!.openApplication(applicationId);
    await createFileOpenInAction({
      api: apiWith(),
      bridge,
      source,
      locale: "en",
      beginAttempt: attempt(),
    })!.openApplication(applicationId);
    expect(saveDownload).toHaveBeenCalledTimes(3);
  });

  it("aborts the HTTP request and does not save or open late bytes after cancellation", async () => {
    const bytes = deferred<Blob>();
    const read = vi.fn(() => bytes.promise);
    const { action, saveDownload, openDownload } = setup(apiWith(read));
    const cancelled = new AbortController();
    const result = action.openApplication(applicationId, cancelled.signal);
    const failure = expect(result).rejects.toMatchObject({ name: "AbortError" });
    cancelled.abort();
    expect(
      (
        read.mock.calls[0] as unknown as [
          string,
          string,
          string,
          number,
          { signal: AbortSignal },
        ]
      )[4].signal.aborted
    ).toBe(true);
    bytes.resolve(new Blob(["late"]));
    await failure;
    expect(saveDownload).not.toHaveBeenCalled();
    expect(openDownload).not.toHaveBeenCalled();
  });

  it("does not dispatch open when an already dispatched save finishes after cancellation", async () => {
    const save = deferred<typeof saved>();
    const { action, saveDownload, openDownload } = setup();
    saveDownload.mockReturnValueOnce(save.promise);
    const cancelled = new AbortController();
    const result = action.openApplication(applicationId, cancelled.signal);
    const failure = expect(result).rejects.toMatchObject({ name: "AbortError" });
    await vi.waitFor(() => expect(saveDownload).toHaveBeenCalledTimes(1));
    cancelled.abort();
    save.resolve(saved);
    await failure;
    expect(openDownload).not.toHaveBeenCalled();
    await action.openApplication(applicationId);
    expect(saveDownload).toHaveBeenCalledTimes(1);
    expect(openDownload).toHaveBeenCalledTimes(1);
  });

  it("never opens after Session revocation, including when a receipt was already cached", async () => {
    const session = new AbortController();
    const { action, openDownload } = setup(apiWith(), source, attempt(session));
    await action.openApplication(applicationId);
    session.abort();
    await expect(action.openApplication(applicationId)).rejects.toMatchObject({
      name: "AbortError",
    });
    expect(openDownload).toHaveBeenCalledTimes(1);
  });

  it("does not open a file after retrieval or native save failure", async () => {
    const { action, api, saveDownload, openDownload } = setup();
    vi.mocked(api.fetchConversationAttachment).mockRejectedValueOnce(new Error("404"));
    await expect(action.openApplication(applicationId)).rejects.toThrow("404");
    expect(saveDownload).not.toHaveBeenCalled();
    saveDownload.mockRejectedValueOnce(new Error("disk full"));
    await expect(action.openApplication(applicationId)).rejects.toThrow("disk full");
    expect(openDownload).not.toHaveBeenCalled();
  });

  it("does not expose native applications on web or other operating systems", () => {
    const { api, bridge } = setup();
    expect(
      createFileOpenInAction({
        api,
        bridge: { ...bridge, platform: "web" },
        source,
        locale: "en",
        beginAttempt: attempt(),
      })
    ).toBeUndefined();
    expect(
      createFileOpenInAction({
        api,
        bridge: { ...bridge, os: "windows" },
        source,
        locale: "en",
        beginAttempt: attempt(),
      })
    ).toBeUndefined();
  });

  it("retires an unavailable saved file and re-saves only after the next user action", async () => {
    const { action, saveDownload, openDownload } = setup();
    await action.openApplication(applicationId);
    openDownload.mockResolvedValueOnce({ status: "unavailable" } as never);
    await expect(action.openApplication(applicationId)).rejects.toThrow();
    expect(openDownload).toHaveBeenCalledTimes(2);
    expect(saveDownload).toHaveBeenCalledTimes(1);
    await action.openApplication(applicationId);
    expect(saveDownload).toHaveBeenCalledTimes(2);
    expect(openDownload).toHaveBeenCalledTimes(3);
  });
  it("bounds completed receipts and rejects files above the existing byte limit before saving", async () => {
    const { action, api, bridge, saveDownload } = setup();
    await action.openApplication(applicationId);
    for (let index = 0; index < 32; index += 1) {
      await createFileOpenInAction({
        api,
        bridge,
        source: { ...source, messageId: `message-${index}` },
        locale: "en",
        beginAttempt: attempt(),
      })!.openApplication(applicationId);
    }
    await action.openApplication(applicationId);
    expect(saveDownload).toHaveBeenCalledTimes(34);
    const large = setup(
      apiWith(vi.fn(async () => new Blob([new Uint8Array(10_000_001)])))
    );
    await expect(large.action.openApplication(applicationId)).rejects.toThrow();
    expect(large.saveDownload).not.toHaveBeenCalled();
  });
});

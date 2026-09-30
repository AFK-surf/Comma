import { act, render, screen, waitFor } from "@comma/test-utils/render";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { CommaApiClient } from "../api";
import { FilePreviewPanel } from "../components/chat-sidebar/FilePreviewPanel";
import type { ConversationFileSource } from "../runtime-files/fileSources";

const registry = vi.hoisted(() => ({ beginAttempt: vi.fn() }));
vi.mock("../components/chat/ChatProvider", () => ({ useChatRegistry: () => registry }));

const file: ConversationFileSource = {
  groupId: "group",
  conversationId: "worker-conversation",
  messageId: "message",
  attachmentIndex: 2,
  fileName: "report.txt",
  mimeType: "text/plain",
};
const deferred = <T,>() => {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => {
    resolve = done;
  });
  return { promise, resolve };
};
const apiWith = (read: (...args: unknown[]) => Promise<Blob>) =>
  ({ fetchConversationAttachment: read }) as unknown as CommaApiClient;
const onOpenBrowser = vi.fn();
const panel = (api: CommaApiClient, source = file) => (
  <FilePreviewPanel
    api={api}
    source={source}
    panelId="file-panel"
    onOpenBrowser={onOpenBrowser}
  />
);
let session: AbortController;

beforeEach(() => {
  session = new AbortController();
  registry.beginAttempt.mockImplementation(() => ({
    signal: session.signal,
    isCurrent: () => !session.signal.aborted,
    release: vi.fn(),
  }));
  installNativeBridgeMock({ platform: "web", os: "macos" });
});
afterEach(() => {
  vi.restoreAllMocks();
});

describe("selected file preview ownership", () => {
  it("centers the shared Greeting shimmer until the selected document is readable", async () => {
    const read = deferred<Blob>();
    const decoded = deferred<string>();
    const blob = new Blob(["Readable document"]);
    const prefix = blob.slice();
    vi.spyOn(prefix, "text").mockReturnValue(decoded.promise);
    vi.spyOn(blob, "slice").mockReturnValue(prefix);
    render(panel(apiWith(() => read.promise)));

    const loading = screen.getByTestId("file-preview-loading");
    expect(loading).toHaveRole("status");
    expect(screen.getByRole("status", { name: "Loading preview…" })).toHaveAttribute(
      "aria-busy",
      "true"
    );

    await act(async () => read.resolve(blob));
    expect(screen.getByTestId("file-preview-loading")).toBeVisible();
    expect(screen.queryByText("Readable document")).not.toBeInTheDocument();
    await act(async () => decoded.resolve("Readable document"));
    expect(await screen.findByText("Readable document")).toBeVisible();
    expect(screen.queryByTestId("file-preview-loading")).not.toBeInTheDocument();
  });

  it("addresses the original worker attachment and drops late data when selection changes", async () => {
    const first = deferred<Blob>();
    const second = deferred<Blob>();
    const read = vi
      .fn()
      .mockReturnValueOnce(first.promise)
      .mockReturnValueOnce(second.promise);
    const api = apiWith(read);
    const { rerender } = render(panel(api));
    await waitFor(() => expect(read).toHaveBeenCalledTimes(1));
    expect(read).toHaveBeenNthCalledWith(
      1,
      "group",
      "worker-conversation",
      "message",
      2,
      { signal: expect.any(AbortSignal) }
    );
    const firstSignal = read.mock.calls[0]![4].signal as AbortSignal;
    rerender(
      panel(api, {
        ...file,
        messageId: "second-message",
        attachmentIndex: 0,
        fileName: "second.txt",
      })
    );
    expect(firstSignal.aborted).toBe(true);
    await act(async () => second.resolve(new Blob(["Second file content"])));
    expect(await screen.findByText("Second file content")).toBeVisible();
    await act(async () => first.resolve(new Blob(["Old file content"])));
    expect(screen.queryByText("Old file content")).not.toBeInTheDocument();
    expect(screen.getByText("Second file content")).toBeVisible();
  });

  it("hides the previous API owner's content while a same-address file is loading", async () => {
    const next = deferred<Blob>();
    const previousApi = apiWith(
      vi.fn().mockResolvedValue(new Blob(["Previous account content"]))
    );
    const nextApi = apiWith(vi.fn().mockReturnValue(next.promise));
    const { rerender } = render(panel(previousApi));
    expect(await screen.findByText("Previous account content")).toBeVisible();
    rerender(panel(nextApi));
    expect(screen.queryByText("Previous account content")).not.toBeInTheDocument();
    await act(async () => next.resolve(new Blob(["Current account content"])));
    expect(await screen.findByText("Current account content")).toBeVisible();
  });

  it("aborts a closed preview and never publishes its late response into a new selection", async () => {
    const result = deferred<Blob>();
    const read = vi.fn().mockReturnValue(result.promise);
    const { unmount } = render(panel(apiWith(read)));
    await waitFor(() => expect(read).toHaveBeenCalledOnce());
    const signal = read.mock.calls[0]![4].signal as AbortSignal;
    unmount();
    expect(signal.aborted).toBe(true);
    await act(async () => result.resolve(new Blob(["Closed content"])));
    expect(screen.queryByTestId("file-preview-panel")).not.toBeInTheDocument();
  });

  it("retires a displayed object URL when the Session is revoked", async () => {
    const createUrl = vi
      .spyOn(URL, "createObjectURL")
      .mockReturnValue("blob:preview-owned");
    const revokeUrl = vi
      .spyOn(URL, "revokeObjectURL")
      .mockImplementation(() => undefined);
    const api = apiWith(
      vi.fn().mockResolvedValue(new Blob(["image"], { type: "image/png" }))
    );
    render(panel(api, { ...file, fileName: "picture.png", mimeType: "image/png" }));
    expect(await screen.findByRole("img", { name: "picture.png" })).toHaveAttribute(
      "src",
      "blob:preview-owned"
    );
    expect(createUrl).toHaveBeenCalledOnce();
    await act(async () => session.abort());
    expect(screen.queryByRole("img", { name: "picture.png" })).not.toBeInTheDocument();
    expect(revokeUrl).toHaveBeenCalledWith("blob:preview-owned");
  });
});

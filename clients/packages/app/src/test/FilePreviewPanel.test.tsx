import { act, render, screen, waitFor } from "@comma/test-utils/render";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { FilePreviewPanel } from "../components/chat-sidebar/FilePreviewPanel";
import { textPreviewLimit } from "../components/file-preview/FilePreviewContent";
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
type FileBytes = { bytes: Uint8Array; type: string };
const text = (value: string, type = "text/plain"): FileBytes => ({
  bytes: new TextEncoder().encode(value),
  type,
});
/**
 * A core whose reads answer what `read` gives for each call: the head a text preview asks for (`files.readRange`, the
 * whole file being that head), or a whole file. It cannot stream (`fileStream` unsupported), so an image is read whole.
 */
const coreWith = (read: (params: unknown) => Promise<FileBytes> | FileBytes) =>
  createScriptedCore({
    values: (topic) =>
      topic.topic === "fileStream" ? { status: "unsupported" } : undefined,
    calls: (name, params) =>
      name === "files.readRange"
        ? Promise.resolve(read(params)).then((span) => ({
            ...span,
            size: span.bytes.byteLength,
          }))
        : name === "files.read"
          ? read(params)
          : null,
  });
const onOpenBrowser = vi.fn();
const panel = (core: ReturnType<typeof coreWith>, source = file) =>
  core.wrap(
    <FilePreviewPanel
      source={source}
      panelId="file-panel"
      onOpenBrowser={onOpenBrowser}
    />
  );
const attemptFor = (signal: AbortSignal) => () => ({
  signal,
  isCurrent: () => !signal.aborted,
  release: vi.fn(),
});
let session: AbortController;

beforeEach(() => {
  session = new AbortController();
  registry.beginAttempt = vi.fn(attemptFor(session.signal));
  installNativeBridgeMock({ platform: "web", os: "macos" });
});
afterEach(() => {
  vi.restoreAllMocks();
});

describe("selected file preview ownership", () => {
  it("centers the shared Greeting shimmer until the selected document is readable", async () => {
    const read = deferred<FileBytes>();
    const decoded = deferred<string>();
    vi.spyOn(Blob.prototype, "text").mockReturnValue(decoded.promise);
    render(panel(coreWith(() => read.promise)));

    const loading = await screen.findByTestId("file-preview-loading");
    expect(loading).toHaveRole("status");
    expect(screen.getByRole("status", { name: "Loading preview…" })).toHaveAttribute(
      "aria-busy",
      "true"
    );

    await act(async () => read.resolve(text("Readable document")));
    expect(screen.getByTestId("file-preview-loading")).toBeVisible();
    expect(screen.queryByText("Readable document")).not.toBeInTheDocument();
    await act(async () => decoded.resolve("Readable document"));
    expect(await screen.findByText("Readable document")).toBeVisible();
    expect(screen.queryByTestId("file-preview-loading")).not.toBeInTheDocument();
  });

  it("reads the head of a text file it shows, addressed to the original worker attachment, and drops late data when selection changes", async () => {
    const first = deferred<FileBytes>();
    const second = deferred<FileBytes>();
    const read = vi
      .fn()
      .mockReturnValueOnce(first.promise)
      .mockReturnValueOnce(second.promise);
    const core = coreWith(read);
    const { rerender } = render(panel(core));
    await waitFor(() => expect(read).toHaveBeenCalledTimes(1));
    expect(read).toHaveBeenNthCalledWith(1, {
      source: {
        source: "attachment",
        group: "group",
        conversation: "worker-conversation",
        message: "message",
        index: 2,
      },
      offset: 0,
      length: textPreviewLimit + 1,
    });
    rerender(
      panel(core, {
        ...file,
        messageId: "second-message",
        attachmentIndex: 0,
        fileName: "second.txt",
      })
    );
    await waitFor(() =>
      expect(core.cancelledTo("files.readRange")).toEqual([read.mock.calls[0]![0]])
    );
    await act(async () => second.resolve(text("Second file content")));
    expect(await screen.findByText("Second file content")).toBeVisible();
    await act(async () => first.resolve(text("Old file content")));
    expect(screen.queryByText("Old file content")).not.toBeInTheDocument();
    expect(screen.getByText("Second file content")).toBeVisible();
  });

  it("hides the previous Session's content while a same-address file is loading", async () => {
    const next = deferred<FileBytes>();
    const read = vi
      .fn()
      .mockResolvedValueOnce(text("Previous account content"))
      .mockReturnValueOnce(next.promise);
    const core = coreWith(read);
    const { rerender } = render(panel(core));
    expect(await screen.findByText("Previous account content")).toBeVisible();
    // Another Session: its registry begins its own attempts.
    registry.beginAttempt = vi.fn(attemptFor(new AbortController().signal));
    rerender(panel(core));
    expect(screen.queryByText("Previous account content")).not.toBeInTheDocument();
    await act(async () => next.resolve(text("Current account content")));
    expect(await screen.findByText("Current account content")).toBeVisible();
  });

  it("lets a closed preview's read go and never publishes its late response", async () => {
    const result = deferred<FileBytes>();
    const read = vi.fn().mockReturnValue(result.promise);
    const core = coreWith(read);
    const { unmount } = render(panel(core));
    await waitFor(() => expect(read).toHaveBeenCalledOnce());
    unmount();
    await waitFor(() => expect(core.cancelledTo("files.readRange")).toHaveLength(1));
    await act(async () => result.resolve(text("Closed content")));
    expect(screen.queryByTestId("file-preview-panel")).not.toBeInTheDocument();
  });

  it("says an image the host cannot stream is too large to read whole", async () => {
    render(
      panel(
        coreWith(() =>
          Promise.reject({
            code: "too_large",
            message: "The file is larger than 10 MB.",
          })
        ),
        { ...file, fileName: "poster.png", mimeType: "image/png" }
      )
    );
    expect(
      await screen.findByText("This file exceeds the 10 MB preview limit.")
    ).toBeVisible();
  });

  it("reads nothing of a file whose type it cannot show", async () => {
    const read = vi.fn(() => text("never read"));
    const core = coreWith(read);
    render(
      panel(core, { ...file, fileName: "archive.zip", mimeType: "application/zip" })
    );
    expect(
      await screen.findByText("A preview is not available for this file type.")
    ).toBeVisible();
    expect(read).not.toHaveBeenCalled();
  });

  it("retires a displayed object URL when the Session is revoked", async () => {
    const createUrl = vi
      .spyOn(URL, "createObjectURL")
      .mockReturnValue("blob:preview-owned");
    const revokeUrl = vi
      .spyOn(URL, "revokeObjectURL")
      .mockImplementation(() => undefined);
    render(
      panel(
        coreWith(() => text("image", "image/png")),
        { ...file, fileName: "picture.png", mimeType: "image/png" }
      )
    );
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

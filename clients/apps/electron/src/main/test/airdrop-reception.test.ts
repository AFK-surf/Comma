import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type {
  AirDropState,
  NotchHostEvent,
  NotchHostScenePayload,
} from "@comma/native-bridge";
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  AirDropReception,
  type AirDropOfferPresentation,
} from "../modules/airdrop/reception";

const requestId = "11111111-1111-4111-8111-111111111111";
const roots: string[] = [];
afterEach(async () => {
  vi.useRealTimers();
  await Promise.all(
    roots.splice(0).map((root) => rm(root, { force: true, recursive: true }))
  );
});

function harness() {
  let focused: string | undefined;
  const focusListeners = new Set<() => void>();
  const notchListeners = new Set<(event: NotchHostEvent) => void>();
  const published: AirDropState[] = [];
  const notch = {
    update: vi.fn(async (_payload: NotchHostScenePayload) => undefined),
  };
  const platform = {
    focusedToastSurfaceId: () => focused,
    onFocusChanged: (listener: () => void) => {
      focusListeners.add(listener);
      return () => focusListeners.delete(listener);
    },
    onNotchEvent: (listener: (event: NotchHostEvent) => void) => {
      notchListeners.add(listener);
      return () => notchListeners.delete(listener);
    },
    renderPreview: vi.fn(async () => ({
      bytes: new TextEncoder().encode("preview"),
      height: 180,
      mediaType: "image/jpeg" as const,
      width: 240,
    })),
    reveal: vi.fn(),
  };
  const reception = new AirDropReception({
    notch,
    platform,
    publish: (state) => published.push(state),
  });
  const offer: AirDropOfferPresentation = {
    chatTitle: "Design review",
    files: [{ isDirectory: false, name: "IMG_0001.HEIC", size: 2048 }],
    linkCount: 0,
    requestId,
    senderName: "Zanwei’s iPhone",
    surfaceId: "win_main",
  };
  return {
    focus(surfaceId: string | undefined) {
      focused = surfaceId;
      for (const listener of focusListeners) listener();
    },
    notchTransfer: () => notch.update.mock.calls.at(-1)?.[0].airDrop?.transfer,
    notch,
    notchAction(action: string) {
      for (const listener of notchListeners)
        listener({ type: "action", payload: { action, value: requestId } });
    },
    offer,
    platform,
    published,
    reception,
  };
}

async function receivedFile(name = "IMG_0001.HEIC") {
  const root = await mkdtemp(join(tmpdir(), "comma-airdrop-reception-"));
  roots.push(root);
  const path = join(root, name);
  await writeFile(path, "photo");
  return path;
}

describe("AirDrop reception presentation", () => {
  it("pops the Notch only while the chat window is not focused, ahead of tasks", async () => {
    const h = harness();
    h.focus("win_main");
    const decision = h.reception.confirm(h.offer, new AbortController().signal);

    // The focused window shows the toast; the Notch stays quiet.
    expect(h.reception.state().transfers).toMatchObject([
      { phase: "offer", senderName: "Zanwei’s iPhone", surfaceId: "win_main" },
    ]);
    expect(h.notch.update).not.toHaveBeenCalled();

    h.focus(undefined);
    // The Notch uses the toast's status copy.
    expect(h.notchTransfer()).toEqual({
      acceptLabel: "Accept",
      declineLabel: "Decline",
      phase: "offer",
      requestId,
      subtitle: "Adds to “Design review”",
      title: "AirDrop from Zanwei’s iPhone",
    });

    // Either surface answers the same offer.
    h.notchAction("airdrop:accept");
    await expect(decision).resolves.toBe(true);
    expect(h.notchTransfer()).toEqual({
      phase: "receiving",
      requestId,
      subtitle: "Adds to “Design review”",
      title: "Receiving from Zanwei’s iPhone",
    });

    // The helper's byte count moves the toast and the ring in whole percents.
    h.reception.progress(requestId, {
      fraction: 0.42,
      totalBytes: 100,
      transferredBytes: 42,
    });
    expect(h.reception.state().transfers[0]?.progress).toBe(0.42);
    expect(h.notchTransfer()).toMatchObject({ progress: 0.42 });
    const updates = h.notch.update.mock.calls.length;
    h.reception.progress(requestId, {
      fraction: 0.424,
      totalBytes: 1000,
      transferredBytes: 424,
    });
    expect(h.notch.update).toHaveBeenCalledTimes(updates);

    h.focus("win_main");
    expect(h.notch.update).toHaveBeenLastCalledWith({ airDrop: {} });
  });

  it("shows the result with previews, then leaves the Notch before the toast", async () => {
    const h = harness();
    h.focus(undefined);
    const decision = h.reception.confirm(h.offer, new AbortController().signal);
    h.reception.act({ action: "accept", requestId });
    await decision;
    const path = await receivedFile();
    h.reception.received(requestId, [path]);
    vi.useFakeTimers();
    await h.reception.complete(requestId, 0);

    // State carries the preview's layout; its bytes come over the binary command.
    expect(h.reception.state().transfers).toMatchObject([
      {
        files: [
          {
            kind: "image",
            name: "IMG_0001.HEIC",
            preview: { height: 180, mediaType: "image/jpeg", width: 240 },
            size: 5,
          },
        ],
        phase: "completed",
      },
    ]);
    expect(h.reception.preview({ index: 0, requestId })).toEqual({
      image: new TextEncoder().encode("preview"),
      mediaType: "image/jpeg",
      status: "ready",
    });
    expect(h.reception.preview({ index: 1, requestId })).toEqual({
      status: "unavailable",
    });
    expect(h.platform.renderPreview).toHaveBeenCalledWith(path, {
      height: 110,
      width: 174,
    });
    // The received image takes the status icon's place in the Notch.
    expect(h.notchTransfer()).toEqual({
      phase: "completed",
      preview: Buffer.from("preview").toString("base64"),
      requestId,
      title: "Added to “Design review”",
    });

    vi.advanceTimersByTime(4_000);
    expect(h.notch.update).toHaveBeenLastCalledWith({ airDrop: {} });
    expect(h.reception.state().transfers).toHaveLength(1);
    vi.advanceTimersByTime(2_000);
    expect(h.reception.state().transfers).toEqual([]);
  });

  it("keeps a result while the user looks at it, then lets it go", async () => {
    const h = harness();
    const decision = h.reception.confirm(h.offer, new AbortController().signal);
    // Looking at an offer is not a decision.
    h.reception.act({ action: "hold", requestId });
    expect(h.reception.state().transfers).toMatchObject([{ phase: "offer" }]);
    h.reception.act({ action: "accept", requestId });
    await decision;
    h.reception.received(requestId, [await receivedFile()]);
    vi.useFakeTimers();
    await h.reception.complete(requestId, 0);

    // Still held when it completes: the strip stays while it is being scrolled.
    vi.advanceTimersByTime(60_000);
    expect(h.reception.state().transfers).toMatchObject([{ phase: "completed" }]);
    h.reception.act({ action: "release", requestId });
    vi.advanceTimersByTime(5_999);
    expect(h.reception.state().transfers).toHaveLength(1);
    vi.advanceTimersByTime(1);
    expect(h.reception.state().transfers).toEqual([]);
  });

  it("previews every one of several files and counts them in the Notch", async () => {
    const h = harness();
    h.focus(undefined);
    const names = [
      "IMG_0001.HEIC",
      "IMG_0002.HEIC",
      "IMG_0003.HEIC",
      "IMG_0004.HEIC",
      "IMG_0005.HEIC",
      "Q3 report.pdf",
    ];
    const decision = h.reception.confirm(
      {
        ...h.offer,
        files: names.map((name) => ({ isDirectory: false, name, size: 2048 })),
      },
      new AbortController().signal
    );
    expect(h.notchTransfer()).toMatchObject({
      phase: "offer",
      title: "6 files from Zanwei’s iPhone",
    });
    h.reception.act({ action: "accept", requestId });
    await decision;
    expect(h.notchTransfer()).toMatchObject({
      phase: "receiving",
      title: "Receiving 6 files from Zanwei’s iPhone",
    });

    const paths = await Promise.all(names.map((name) => receivedFile(name)));
    h.reception.received(requestId, paths);
    await h.reception.complete(requestId, 1);

    // The toast's strip scrolls through all of them, so each gets a tile preview.
    expect(h.platform.renderPreview).toHaveBeenCalledTimes(names.length);
    expect(h.platform.renderPreview).toHaveBeenCalledWith(paths[5], {
      height: 96,
      width: 96,
    });
    expect(h.reception.preview({ index: 5, requestId })).toMatchObject({
      status: "ready",
    });
    // No single image stands for several: the Notch counts what reached the chat.
    expect(h.notchTransfer()).toEqual({
      phase: "completed",
      requestId,
      subtitle: "1 file couldn’t be added",
      title: "Added 5 files to “Design review”",
    });
  });

  it("declines on dismissal or expiry and explains an offer it cannot attach", async () => {
    const h = harness();
    h.focus(undefined);
    const dismissed = h.reception.confirm(h.offer, new AbortController().signal);
    h.reception.act({ action: "dismiss", requestId });
    await expect(dismissed).resolves.toBe(false);
    expect(h.reception.state().transfers).toEqual([]);

    const controller = new AbortController();
    const expired = h.reception.confirm(h.offer, controller.signal);
    controller.abort();
    await expect(expired).resolves.toBe(false);
    expect(h.reception.state().transfers).toEqual([]);

    // No Comma window to raise a toast in: the Notch carries the explanation.
    const { chatTitle: _chatTitle, surfaceId: _surfaceId, ...withoutChat } = h.offer;
    h.reception.refuse(withoutChat, "no_chat");
    expect(h.reception.state().transfers).toMatchObject([
      { canReveal: false, failure: "no_chat", phase: "failed" },
    ]);
    expect(h.notchTransfer()).toEqual({
      phase: "failed",
      requestId,
      subtitle: "Open a chat in Comma, then send again.",
      title: "Couldn’t receive files",
    });
  });

  it("keeps received files that could not be attached until the user reveals or dismisses them", async () => {
    const h = harness();
    const decision = h.reception.confirm(h.offer, new AbortController().signal);
    h.reception.act({ action: "accept", requestId });
    await decision;
    const path = await receivedFile();
    h.reception.received(requestId, [path]);
    h.reception.fail(requestId, "attach");
    vi.useFakeTimers();
    vi.advanceTimersByTime(60_000);

    expect(h.reception.state().transfers).toMatchObject([
      { canReveal: true, failure: "attach", phase: "failed" },
    ]);
    h.reception.act({ action: "reveal", requestId });
    expect(h.platform.reveal).toHaveBeenCalledWith(path);
    h.reception.act({ action: "dismiss", requestId });
    expect(h.reception.state().transfers).toEqual([]);

    h.reception.confirm(h.offer, new AbortController().signal);
    const revision = h.reception.state().revision;
    h.reception.reset();
    expect(h.published.at(-1)).toEqual({ revision: revision + 1, transfers: [] });
  });
});

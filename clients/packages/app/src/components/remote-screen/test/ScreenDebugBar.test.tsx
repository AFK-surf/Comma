// The icons under a device's picture ask the core and say what came of it: only what the station lists shows, a screenshot
// can go on to Ask Comma, a recording's movie is saved when it stops, a refusal says the station's words.
import type { ListedScreen } from "@comma/core-client";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ScreenDebugBar } from "../ScreenDebugBar";

const SIM: ListedScreen = {
  id: "simulator:A119A827-41D5-49E0-9689-710DB19BF30E",
  instance: "i1",
  name: "iPhone",
  title: "iPhone · iOS 27.2",
  width: 1206,
  height: 2622,
  peek: true,
  capabilities: {
    input: "touch",
    buttons: [],
    panels: [],
    debug: {
      actions: ["restart", "screenshot", "record", "install", "appearance"],
      install: [".ipa", ".zip"],
    },
  },
};

const calls: { name: string; params: Record<string, unknown> }[] = [];
const answers = vi.hoisted(
  () => new Map<string, (params: Record<string, unknown>) => unknown>()
);
const toasts = vi.hoisted(() => ({ success: vi.fn(), error: vi.fn() }));
const download = vi.hoisted(() => vi.fn());
vi.mock("@comma/core-client", async (original) => ({
  ...(await original<typeof import("@comma/core-client")>()),
  useCall: () => async (name: string, params: Record<string, unknown>) => {
    calls.push({ name, params });
    const answer =
      answers.get(`${name}:${params.action as string}`) ?? answers.get(name);
    return answer ? answer(params) : {};
  },
}));
vi.mock("@comma/ui/components/toast", async (original) => ({
  ...(await original<typeof import("@comma/ui/components/toast")>()),
  toast: toasts,
}));
vi.mock("../../../runtime-files/fileDownloads", async (original) => ({
  ...(await original<typeof import("../../../runtime-files/fileDownloads")>()),
  downloadFile: download,
  savedDownloadActions: () => [{ label: "Show in Finder", onPress: () => undefined }],
}));

const bar = (props: Partial<Parameters<typeof ScreenDebugBar>[0]> = {}) =>
  render(
    <ScreenDebugBar
      device="dev_1"
      live
      picture={() => null}
      screen={SIM}
      workspace="wsp_1"
      {...props}
    />
  );
const button = (name: RegExp) => screen.getByRole("button", { name });
const debugCalls = () => calls.filter((c) => c.params.action !== "state");

beforeEach(() =>
  answers.set("devices.screenDebug:state", () => ({
    recording: false,
    appearance: "light",
  }))
);
afterEach(() => {
  cleanup();
  calls.length = 0;
  answers.clear();
  vi.clearAllMocks();
});

describe("the debug icons", () => {
  it("are named by tooltip, and only what the station lists", () => {
    bar({
      screen: {
        ...SIM,
        capabilities: {
          ...SIM.capabilities,
          debug: { actions: ["screenshot"], install: [] },
        },
      },
    });
    expect(screen.getAllByRole("button")).toHaveLength(1);
    expect(button(/screenshot/i)).toBeTruthy();
  });

  it("show nothing for a station from before", () => {
    const { container } = bar({
      screen: { ...SIM, capabilities: { input: "touch", buttons: [], panels: [] } },
    });
    expect(container.querySelector("[data-testid=remote-screen-debug]")).toBeNull();
  });

  it("read how the device stands only once its view is live", async () => {
    const { rerender } = bar({ live: false });
    expect(calls).toEqual([]);
    expect((button(/screenshot/i) as HTMLButtonElement).disabled).toBe(true);
    rerender(
      <ScreenDebugBar
        device="dev_1"
        live
        picture={() => null}
        screen={SIM}
        workspace="wsp_1"
      />
    );
    await waitFor(() => expect(calls.map((c) => c.params.action)).toEqual(["state"]));
  });

  it("restart the running app and say which", async () => {
    answers.set("devices.screenDebug:restart", () => ({
      app: "fail.still.a",
      name: "Alpha",
    }));
    bar();
    fireEvent.click(button(/restart app/i));
    await waitFor(() => expect(toasts.success).toHaveBeenCalled());
    expect(debugCalls()[0]!.params).toMatchObject({
      workspace: "wsp_1",
      device: "dev_1",
      instance: "i1",
      action: "restart",
    });
    expect(toasts.success.mock.calls[0]![0]).toMatch(/Alpha/);
  });

  it("say the station's words when it refuses", async () => {
    answers.set("devices.screenDebug:restart", () => {
      throw new Error("only a view in Control may do that");
    });
    bar();
    fireEvent.click(button(/restart app/i));
    await waitFor(() => expect(toasts.error).toHaveBeenCalled());
    expect(toasts.error.mock.calls[0]![1].description).toBe(
      "only a view in Control may do that"
    );
  });

  it("put a saved screenshot on the way to Ask Comma, as its bytes", async () => {
    answers.set("devices.saveScreenPicture", () => ({
      png: new Uint8Array([1, 2]),
      saved: { downloadRef: "r", fileName: "shot.png" },
    }));
    const onAskComma = vi.fn(async () => undefined);
    bar({ onAskComma });
    fireEvent.click(button(/screenshot/i));
    await waitFor(() => expect(toasts.success).toHaveBeenCalled());
    const options = toasts.success.mock.calls[0]![1];
    expect(options.description).toBe("shot.png");
    expect(options.actions.map((a: { label: string }) => a.label)).toEqual([
      "Ask Comma",
      "Show in Finder",
    ]);
    options.actions[0].onPress();
    const blob = (onAskComma.mock.calls[0] as unknown as [Blob])[0];
    expect([blob.size, blob.type]).toEqual([2, "image/png"]);
  });

  it("offer no Ask Comma where there is no chat", async () => {
    answers.set("devices.saveScreenPicture", () => ({
      png: new Uint8Array([1]),
      saved: { downloadRef: "r", fileName: "s.png" },
    }));
    bar();
    fireEvent.click(button(/screenshot/i));
    await waitFor(() => expect(toasts.success).toHaveBeenCalled());
    expect(
      toasts.success.mock.calls[0]![1].actions.map((a: { label: string }) => a.label)
    ).toEqual(["Show in Finder"]);
  });

  it("start a recording and, stopped, save its movie through the one download path", async () => {
    download.mockResolvedValue({ status: "success" });
    bar();
    fireEvent.click(button(/start recording/i));
    await waitFor(() => expect(debugCalls()[0]!.params.action).toBe("record"));
    const stop = await screen.findByRole("button", { name: /stop recording/i });
    await waitFor(() => expect((stop as HTMLButtonElement).disabled).toBe(false));
    fireEvent.click(stop);
    await waitFor(() => expect(download).toHaveBeenCalled());
    const [request] = download.mock.calls[0]!;
    expect(request.fileName).toMatch(/^iPhone .*\.mp4$/);
    await request.save();
    expect(
      calls.find((c) => c.name === "devices.saveScreenRecording")?.params
    ).toMatchObject({ instance: "i1", name: request.fileName });
  });

  it("show a recording that went on while it was not in Control", async () => {
    answers.set("devices.screenDebug:state", () => ({ recording: true }));
    bar();
    expect(await screen.findByRole("button", { name: /stop recording/i })).toBeTruthy();
  });

  it("name the panel of a foldable it records", async () => {
    bar({
      screen: {
        ...SIM,
        capabilities: { ...SIM.capabilities, poses: ["open", "closed"] },
      },
      picture: () => ({ videoWidth: 1398, videoHeight: 2034 }) as HTMLVideoElement,
    });
    fireEvent.click(button(/start recording/i));
    await waitFor(() =>
      expect(debugCalls()[0]?.params).toMatchObject({
        action: "record",
        panel: "cover",
      })
    );
  });

  it("send the file chosen, of the types listed", async () => {
    answers.set("devices.installScreenApp", () => ({ app: "fail.still.demo" }));
    bar();
    const input = screen.getByTestId("remote-screen-debug-file") as HTMLInputElement;
    expect(input.accept).toBe(".ipa,.zip");
    fireEvent.change(input, {
      target: { files: [new File([new Uint8Array([7])], "Demo.ipa")] },
    });
    await waitFor(() => expect(toasts.success).toHaveBeenCalled());
    const sent = calls.find((c) => c.name === "devices.installScreenApp")!;
    expect(sent.params.name).toBe("Demo.ipa");
    expect([...(sent.params.bytes as Uint8Array)]).toEqual([7]);
  });

  it("switch light to dark and show the way back", async () => {
    answers.set("devices.screenDebug:appearance", (params) => ({
      appearance: params.value,
    }));
    bar();
    fireEvent.click(await screen.findByRole("button", { name: /switch to dark/i }));
    expect(
      await screen.findByRole("button", { name: /switch to light/i })
    ).toBeTruthy();
    expect(debugCalls()[0]!.params).toMatchObject({
      action: "appearance",
      value: "dark",
    });
  });
});

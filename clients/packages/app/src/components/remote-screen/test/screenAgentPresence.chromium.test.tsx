// A simulator in the panel is the person's to use, until an agent's lease on it starts: then the page watches, with
// Watch and Control to choose from beside the device and the agent's edge round it, and the person takes it back with
// Control.
import "@comma/ui/styles.css";
import "@comma/app/styles.css";
import type { ListedScreen } from "@comma/core-client";
import type { ScreenViewEvent } from "@comma/core/contract";
import { act, cleanup, render, screen } from "@comma/test-utils/render";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { afterEach, expect, it } from "vitest";
import { userEvent } from "vitest/browser";
import type { ScreenViewMessage } from "../meshScreenStream";
import { ScreenStreamPanel } from "../ScreenStreamPanel";
import type { ScreenStreamSource } from "../ScreenStreamStage";
import { fakeDeviceCapabilities, fakePhone } from "./fakeScreenDevice";
import { DESCRIPTION, FRAMES, bytes } from "./h264Frames";

afterEach(cleanup);

const SIM: ListedScreen = {
  id: "simulator:A119A827-41D5-49E0-9689-710DB19BF30E",
  instance: "i1",
  name: "iPhone 17",
  title: "iPhone 17 · iOS 27.0",
  width: 1206,
  height: 2622,
  peek: true,
  capabilities: { input: "touch", buttons: [], panels: [] },
};

/** Until the page shows it: the page changing is what is waited on, with no deadline of its own. */
async function untilPage(what: () => boolean) {
  while (!what())
    await new Promise<void>((resolve) => {
      const seen = new MutationObserver(() => {
        seen.disconnect();
        resolve();
      });
      seen.observe(document.body, {
        attributes: true,
        childList: true,
        subtree: true,
        characterData: true,
      });
    });
}

let sources = 0;

/** A station's view of a simulator: how it was asked to open, each switch it was told, and what it says of an agent. */
function station() {
  let emit: ((event: ScreenViewEvent) => void) | undefined;
  const opened: boolean[] = [];
  const switched: boolean[] = [];
  const source: ScreenStreamSource = {
    key: `workspace\ndevice\nagent-${(sources += 1)}`,
    capabilities: fakeDeviceCapabilities(fakePhone),
    view: {
      open: (request, onEvent, signal) =>
        new Promise((_, no) => {
          signal.addEventListener("abort", () =>
            no(Object.assign(new Error("cancelled"), { code: "cancelled" }))
          );
          emit = onEvent;
          opened.push(request.control === true);
          onEvent({ type: "open", view: 7 });
          onEvent({
            type: "state",
            state: { control: request.control === true, switches: true },
          });
        }),
      send: (_view: number, message: ScreenViewMessage) => {
        if (!("control" in message)) return;
        switched.push(message.control);
        emit?.({ type: "state", state: { control: message.control } });
      },
    },
  };
  return {
    source,
    opened,
    switched,
    says: (state: Extract<ScreenViewEvent, { type: "state" }>["state"]) =>
      act(() => emit!({ type: "state", state })),
    /** Its pictures, as a real encoder made them. */
    pictures: () =>
      act(() => {
        emit!({
          type: "config",
          codec: "h264",
          width: 64,
          height: 48,
          description: DESCRIPTION,
        });
        FRAMES.forEach((frame, at) =>
          emit!({
            type: "video",
            key: at === 0,
            ts: (at + 1) * 1000,
            data: bytes(frame),
          })
        );
      }),
  };
}

function panel(source: ScreenStreamSource, simulator = SIM) {
  return render(
    createScriptedCore({ values: () => undefined }).wrap(
      <div style={{ display: "flex", width: 640, height: 720 }}>
        <ScreenStreamPanel
          active
          appName={undefined}
          computer={{ workspace: "workspace", device: "device", screen: simulator }}
          initialTarget={simulator.id}
          source={source}
        />
      </div>
    )
  );
}

const stage = () => document.querySelector<HTMLElement>(".comma-remote-screen-stage")!;
/** A computed colour that paints nothing, in whichever notation the browser gives it. */
const CLEAR = /^transparent$|[,/] ?0\)$/;
/** Whether Watch and Control are there to choose from, beside the device. */
const chooses = () =>
  screen.getByTestId("remote-screen-choice").getAttribute("data-shown") === "true";
const pressed = (name: string) =>
  screen.queryByRole("button", { name })?.getAttribute("aria-pressed") === "true";

it("drives a simulator once its station says no agent uses it, with no Watch or Control to choose from", async () => {
  const sim = station();
  panel(sim.source);
  await untilPage(() => sim.opened.length === 1);
  expect(sim.opened).toEqual([false]);
  expect(chooses()).toBe(false);
  sim.says({ agent: false });
  await untilPage(() => stage().getAttribute("data-control") === "true");
  expect(sim.switched).toEqual([true]);
  // Nothing to choose: not shown, and nothing of it takes a press or the focus.
  expect(chooses()).toBe(false);
  expect(screen.getByTestId("remote-screen-choice")).toHaveAttribute("inert");
  expect(screen.queryByRole("button", { name: "Watch" })).toBeNull();
  expect(screen.queryByRole("button", { name: "Control" })).toBeNull();
  expect(screen.queryByTestId("remote-screen-agent")).toBeNull();
  // Control is where a simulator rests: no boundary marks it, which would thicken the hairline of each bar beside it.
  // (Read with no transition: the boundary's colour comes in over time, and a test's clock stands still.)
  stage().style.transition = "none";
  const edge = getComputedStyle(stage());
  expect(edge.borderTopColor).toMatch(CLEAR);
  expect(edge.borderInlineStartColor).toMatch(CLEAR);
});

it("watches while an agent's lease lasts, lets the person take it back, and drives again once it ends", async () => {
  const sim = station();
  panel(sim.source);
  await untilPage(() => sim.opened.length === 1);
  sim.says({ agent: false });
  await untilPage(() => sim.switched.length === 1);

  // A lease starts: the page lets go of the device, so the agent's input reaches it, and shows the agent at work.
  sim.says({ agent: true });
  await untilPage(() => chooses() && pressed("Watch"));
  expect(sim.switched).toEqual([true, false]);
  // The choice stands on the stage, under the device, and not in the toolbar.
  const choice = screen.getByTestId("remote-screen-choice");
  expect(stage().contains(choice)).toBe(true);
  expect(choice.getBoundingClientRect().top).toBeGreaterThanOrEqual(
    screen.getByTestId("remote-screen-device").getBoundingClientRect().bottom
  );
  expect(stage().getAttribute("data-control")).toBe("false");
  expect(screen.getByTestId("remote-screen-agent")).toBeInTheDocument();

  // The person takes it back, and gives it up again.
  await userEvent.click(screen.getByRole("button", { name: "Control" }));
  await untilPage(() => pressed("Control"));
  expect(sim.switched).toEqual([true, false, true]);
  await userEvent.click(screen.getByRole("button", { name: "Watch" }));
  await untilPage(() => pressed("Watch"));

  // The lease ends: the device is the person's again, with nothing to choose.
  sim.says({ agent: false });
  await untilPage(() => !chooses());
  expect(sim.switched).toEqual([true, false, true, false, true]);
  expect(stage().getAttribute("data-control")).toBe("true");
  expect(screen.queryByTestId("remote-screen-agent")).toBeNull();
});

it("opens on Watch a simulator its listing says an agent uses", async () => {
  const sim = station();
  panel(sim.source, { ...SIM, agent: true });
  await untilPage(() => sim.opened.length === 1);
  expect(sim.opened).toEqual([false]);
  sim.says({ agent: true });
  await untilPage(() => chooses() && pressed("Watch"));
  expect(sim.switched).toEqual([]);
});

it("keeps Watch and Control beside a simulator whose station says nothing of agents, so it never holds an agent off", async () => {
  const sim = station();
  panel(sim.source);
  await untilPage(() => sim.opened.length === 1);
  // (a station from before: pictures, and no word of a lease)
  sim.pictures();
  await untilPage(() => chooses());
  expect(pressed("Watch")).toBe(true);
  expect(sim.switched).toEqual([]);

  // Taken in Control, Watch is still there to let go of it again.
  await userEvent.click(screen.getByRole("button", { name: "Control" }));
  await untilPage(() => pressed("Control"));
  expect(chooses()).toBe(true);
  await userEvent.click(screen.getByRole("button", { name: "Watch" }));
  await untilPage(() => pressed("Watch"));
  expect(sim.switched).toEqual([true, false]);
});

import { EventEmitter } from "node:events";
import type { App, Session, WebContents, WebFrameMain } from "electron";
import { describe, expect, it, vi } from "vitest";
import { installMiniAppDeviceChoosers, type MiniAppDevice } from "../mini-app-devices";
import { ManualMainClock } from "../test-clock";

function setup() {
  const app = new EventEmitter();
  const session = new EventEmitter();
  const contents = Object.assign(new EventEmitter(), {
    session,
    isDestroyed: vi.fn(() => false),
    getURL: vi.fn(() => "assets://./index.html"),
  });
  const frame = { url: "comma-app://runtime/", detached: false };
  let decide!: (id?: string) => void;
  const choose = vi.fn(
    (_kind: string, _devices: readonly MiniAppDevice[]) =>
      new Promise<string | undefined>((resolve) => {
        decide = resolve;
      })
  );
  const clock = new ManualMainClock();
  installMiniAppDeviceChoosers({
    app: app as App,
    session: session as Session,
    appOrigins: ["assets://."],
    ownerOfFrame: () => contents as unknown as WebContents,
    choose,
    clock,
  });
  app.emit("web-contents-created", {}, contents);
  const event = { preventDefault: vi.fn() };
  const callback = vi.fn();
  return {
    app,
    session,
    contents,
    frame,
    event,
    callback,
    choose,
    clock,
    decide: async (id?: string) => {
      decide(id);
      await Promise.resolve();
    },
  };
}

describe("mini-app device selection", () => {
  it("requires an explicit USB selection and rejects an unrelated returned id", async () => {
    const t = setup();
    const details = {
      frame: t.frame as WebFrameMain,
      deviceList: [{ deviceId: "sensor", productName: "Sensor" }],
    };
    t.session.emit("select-usb-device", t.event, details, t.callback);
    expect(t.event.preventDefault).toHaveBeenCalled();
    expect(t.callback).not.toHaveBeenCalled();
    await t.decide("other-device");
    expect(t.callback).toHaveBeenCalledWith(undefined);
    t.callback.mockClear();
    t.session.emit("select-usb-device", t.event, details, t.callback);
    await t.decide("sensor");
    expect(t.callback).toHaveBeenCalledWith("sensor");
  });

  it("refuses USB requests outside the runtime and cancels when the frame goes away", async () => {
    const t = setup();
    const devices = [{ deviceId: "sensor", productName: "Sensor" }];
    t.session.emit(
      "select-usb-device",
      t.event,
      { frame: { ...t.frame, url: "https://other.test/" }, deviceList: devices },
      t.callback
    );
    expect(t.choose).not.toHaveBeenCalled();
    expect(t.callback).toHaveBeenCalledWith();
    t.callback.mockClear();
    t.session.emit(
      "select-usb-device",
      t.event,
      { frame: t.frame, deviceList: devices },
      t.callback
    );
    t.frame.detached = true;
    await t.decide("sensor");
    expect(t.callback).toHaveBeenCalledWith(undefined);
  });

  it("offers devices discovered later in the scan and never selects one automatically", async () => {
    const t = setup();
    t.contents.emit("select-bluetooth-device", t.event, [], t.callback);
    expect(t.event.preventDefault).toHaveBeenCalled();
    const first = { deviceId: "first", deviceName: "Nearby sensor" };
    t.contents.emit("select-bluetooth-device", t.event, [first], t.callback);
    await t.clock.advanceTo(t.clock.now() + 2_000);
    const target = { deviceId: "target", deviceName: "My sensor" };
    t.contents.emit("select-bluetooth-device", t.event, [first, target], t.callback);
    expect(t.choose).not.toHaveBeenCalled();
    await t.clock.advanceTo(t.clock.now() + 3_000);
    expect(t.choose).toHaveBeenCalledExactlyOnceWith(
      "bluetooth",
      [
        { id: "first", name: "Nearby sensor" },
        { id: "target", name: "My sensor" },
      ],
      t.contents
    );
    expect(t.callback).not.toHaveBeenCalled();
    await t.decide("target");
    expect(t.callback).toHaveBeenCalledExactlyOnceWith("target");
  });

  it("cancels a pending scan when the window is destroyed", async () => {
    const t = setup();
    t.contents.emit(
      "select-bluetooth-device",
      t.event,
      [{ deviceId: "sensor", deviceName: "Sensor" }],
      t.callback
    );
    t.contents.isDestroyed.mockReturnValue(true);
    t.contents.emit("destroyed");
    await t.clock.advanceTo(t.clock.now() + 5_000);
    expect(t.choose).not.toHaveBeenCalled();
    expect(t.callback).toHaveBeenCalledExactlyOnceWith("");
  });

  it("cancels Bluetooth on timeout or window destruction and ignores late chooser answers", async () => {
    const t = setup();
    t.contents.emit("select-bluetooth-device", t.event, [], t.callback);
    await t.clock.advanceTo(t.clock.now() + 5_000);
    expect(t.callback).toHaveBeenCalledExactlyOnceWith("");
    t.callback.mockClear();
    t.contents.emit(
      "select-bluetooth-device",
      t.event,
      [{ deviceId: "sensor", deviceName: "Sensor" }],
      t.callback
    );
    await t.clock.advanceTo(t.clock.now() + 5_000);
    t.contents.isDestroyed.mockReturnValue(true);
    t.contents.emit("destroyed");
    await t.decide("sensor");
    expect(t.callback).toHaveBeenCalledExactlyOnceWith("");
  });

  it("does not offer devices to a non-Comma window", () => {
    const t = setup();
    t.contents.getURL.mockReturnValue("https://other.test/");
    t.contents.emit(
      "select-bluetooth-device",
      t.event,
      [{ deviceId: "sensor", deviceName: "Sensor" }],
      t.callback
    );
    expect(t.choose).not.toHaveBeenCalled();
    expect(t.callback).toHaveBeenCalledExactlyOnceWith("");
  });
});

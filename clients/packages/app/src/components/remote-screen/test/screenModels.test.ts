import type { ListedScreen } from "@comma/core-client";
import { describe, expect, it } from "vitest";
import { screenModels } from "../screenModels";

const running = (
  id: string,
  name: string,
  title: string,
  phone = false
): ListedScreen => ({
  id: id as ListedScreen["id"],
  instance: `${id}/1`,
  name,
  title,
  width: 0,
  height: 0,
  peek: false,
  capabilities: { input: "touch", buttons: [], panels: [] },
  ...(phone ? { phone } : {}),
});
const names = (models: { name: string }[]) => models.map((model) => model.name);

describe("a computer's models", () => {
  it("groups renamed simulator instances by hardware model and keeps the current boot", () => {
    const current = {
      ...running("simulator:A", "still.fail-try", "still.fail-try · iOS 27.1"),
      model: "iPhone Duo",
    };
    const alias = {
      ...running("simulator:B", "accept-duo", "accept-duo · iOS 27.1"),
      model: "iPhone Duo",
    };
    const { shown, more } = screenModels(
      {
        screens: [alias, current],
        avds: [],
        simulators: [
          { udid: "C", title: "performance-test · iOS 27.1", model: "iPhone Duo" },
          { udid: "D", title: "new-app-test · iOS 27.1", model: "iPhone 18" },
        ],
      },
      "ios",
      current
    );
    expect(names(shown)).toEqual(["iPhone Duo", "iPhone 18"]);
    expect(shown[0]?.running).toBe(current);
    expect(shown[1]?.start).toEqual({
      simulator: "D",
      title: "new-app-test · iOS 27.1",
    });
    expect(more).toEqual([]);
  });

  it("orders iOS models chosen lately first, then the newest runtime, and puts those only on older runtimes behind More", () => {
    const { shown, more } = screenModels(
      {
        screens: [],
        avds: [],
        simulators: [
          { udid: "1", title: "iPad Air · iOS 27.1" },
          { udid: "2", title: "iPhone 17 · iOS 27.1" },
          { udid: "3", title: "iPhone 15 · iOS 17.0" },
          { udid: "4", title: "iPhone SE · iOS 26.2" },
          { udid: "5", title: "iPhone 17 · iOS 26.2" },
        ],
      },
      "ios",
      undefined,
      ["iPhone SE"]
    );
    expect(names(shown)).toEqual(["iPhone SE", "iPad Air", "iPhone 17"]);
    expect(shown[2]?.start).toEqual({ simulator: "2", title: "iPhone 17 · iOS 27.1" });
    expect(names(more)).toEqual(["iPhone 15"]);
  });

  it("keeps a long list short: the rest go behind More", () => {
    const simulators = Array.from({ length: 14 }, (_, i) => ({
      udid: String(i),
      title: `iPhone ${i} · iOS 27.1`,
    }));
    const { shown, more } = screenModels(
      { screens: [], avds: [], simulators },
      "ios",
      undefined
    );
    expect(shown).toHaveLength(10);
    expect(more).toHaveLength(4);
  });

  it("never puts a running model behind More, and still shows at most ten rows", () => {
    const simulators = Array.from({ length: 14 }, (_, i) => ({
      udid: String(i),
      title: `iPhone A${i} · iOS 27.1`,
    }));
    const { shown, more } = screenModels(
      {
        screens: [running("simulator:Z", "iPhone Z", "iPhone Z · iOS 27.1")],
        avds: [],
        simulators,
      },
      "ios",
      undefined
    );
    expect(names(shown)).toContain("iPhone Z");
    expect(shown).toHaveLength(10);
    expect(more).toHaveLength(5);
  });

  it("offers an Android computer's AVDs, running or not, and never a phone", () => {
    const { shown, more } = screenModels(
      {
        screens: [
          running("android:emulator-5554", "Pixel_9", "Pixel_9 · Android 16"),
          running("android:R5CT", "Galaxy S24", "Galaxy S24 · Android 15", true),
          running("simulator:A", "iPhone 17", "iPhone 17 · iOS 27.1"),
        ],
        avds: ["Pixel_Fold", "Medium_Phone"],
        simulators: [],
      },
      "android",
      undefined
    );
    expect(names(shown)).toEqual(["Pixel_9", "Medium_Phone", "Pixel_Fold"]);
    expect(shown[0]?.running?.id).toBe("android:emulator-5554");
    expect(shown[1]?.start).toEqual({ avd: "Medium_Phone" });
    expect(more).toEqual([]);
  });
});

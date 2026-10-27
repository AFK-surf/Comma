import { CoreProvider } from "@comma/core-client";
import { CommaI18nProvider } from "@comma/i18n/react";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { render, fireEvent, screen } from "@comma/test-utils/render";
import { flush } from "@comma/test-utils/fake-clock";
import { expect, it, vi } from "vitest";
import { AddCommaDeviceOption, AddDevice } from "../AddDevice";

it("shows board-neutral pairing copy and cancels through the core", async () => {
  const onClose = vi.fn();
  const core = createScriptedCore({
    values: () => ({
      supported: true,
      bluetooth: "on",
      state: {
        step: "pairing",
        device: { id: "fresh", name: "Comma-6AD8", rssi: -50 },
        connected: true,
      },
    }),
  });
  render(
    <CommaI18nProvider locale="en">
      <CoreProvider client={core.client}>
        <AddDevice workspace="wsp" onClose={onClose} />
      </CoreProvider>
    </CommaI18nProvider>
  );
  await flush();
  expect(screen.getByRole("heading", { name: "Pair with Comma-6AD8" })).toBeTruthy();
  expect(screen.getByText(/A device without a screen pairs on its own/)).toBeTruthy();
  fireEvent.click(screen.getByRole("button", { name: "Cancel" }));
  await flush();
  expect(core.sent).toContainEqual(["deviceSetup.event", { type: "cancel" }]);
  expect(onClose).toHaveBeenCalledOnce();
});

it("offers Bluetooth setup in the Add dialog only where the app supports it", async () => {
  const onSetUp = vi.fn();
  for (const supported of [false, true]) {
    const core = createScriptedCore({
      values: () => ({ supported, bluetooth: "on", state: { step: "idle" } }),
    });
    const view = render(
      <CommaI18nProvider locale="en">
        <CoreProvider client={core.client}>
          <AddCommaDeviceOption onSetUp={onSetUp} />
        </CoreProvider>
      </CommaI18nProvider>
    );
    await flush();
    expect(!!screen.queryByRole("button", { name: "Set up a Comma device" })).toBe(
      supported
    );
    view.unmount();
  }
  render(
    <CommaI18nProvider locale="en">
      <CoreProvider
        client={
          createScriptedCore({
            values: () => ({
              supported: true,
              bluetooth: "on",
              state: { step: "idle" },
            }),
          }).client
        }
      >
        <AddCommaDeviceOption onSetUp={onSetUp} />
      </CoreProvider>
    </CommaI18nProvider>
  );
  await flush();
  fireEvent.click(screen.getByRole("button", { name: "Set up a Comma device" }));
  expect(onSetUp).toHaveBeenCalledOnce();
});

it("explains a Bluetooth startup failure and retries through the core", async () => {
  const core = createScriptedCore({
    values: () => ({
      supported: true,
      bluetooth: "pending",
      state: { step: "failed", problem: "bluetooth" },
    }),
  });
  render(
    <CommaI18nProvider locale="en">
      <CoreProvider client={core.client}>
        <AddDevice workspace="wsp" onClose={() => {}} />
      </CoreProvider>
    </CommaI18nProvider>
  );
  await flush();
  expect(screen.getByRole("alert").textContent).toBe(
    "Could not start Bluetooth device setup. Restart Comma and try again."
  );
  fireEvent.click(screen.getByRole("button", { name: "Try again" }));
  await flush();
  expect(core.sent).toContainEqual(["deviceSetup.event", { type: "retry" }]);
});

it("keeps pairing help expandable and connects the selected nearby device", async () => {
  const core = createScriptedCore({
    values: () => ({
      supported: true,
      bluetooth: "on",
      state: {
        step: "scanning",
        quiet: false,
        devices: [{ id: "nearby", name: "Comma-6AD8", rssi: -50 }],
      },
    }),
  });
  render(
    <CommaI18nProvider locale="en">
      <CoreProvider client={core.client}>
        <AddDevice workspace="wsp" onClose={() => {}} />
      </CoreProvider>
    </CommaI18nProvider>
  );
  await flush();
  const help = screen.getByRole("button", { name: "How to enter pairing mode" });
  expect(help.getAttribute("aria-expanded")).toBe("false");
  fireEvent.click(help);
  await flush();
  expect(help.getAttribute("aria-expanded")).toBe("true");
  fireEvent.click(screen.getByRole("button", { name: "Pair with Comma-6AD8" }));
  await flush();
  expect(core.sent).toContainEqual([
    "deviceSetup.event",
    { type: "pick", id: "nearby" },
  ]);
});

it("enables the footer's Join after selecting a network and entering its password", async () => {
  const core = createScriptedCore({
    values: () => ({
      supported: true,
      bluetooth: "on",
      state: {
        step: "wifi",
        device: { id: "nearby", name: "Comma-6AD8", rssi: -50 },
        name: "Comma-6AD8",
        scanning: false,
        failure: null,
        networks: [
          { ssid: "Test Wi-Fi", rssi: -40, secure: true },
          { ssid: "Guest Wi-Fi", rssi: -60, secure: false },
        ],
      },
    }),
  });
  render(
    <CommaI18nProvider locale="en">
      <CoreProvider client={core.client}>
        <AddDevice workspace="wsp" onClose={() => {}} />
      </CoreProvider>
    </CommaI18nProvider>
  );
  await flush();
  const join = screen.getByRole("button", { name: /^Join/ }) as HTMLButtonElement;
  expect(join.disabled).toBe(true);
  fireEvent.click(screen.getByRole("button", { name: "Test Wi-Fi" }));
  await flush();
  expect(join.disabled).toBe(true);
  expect(screen.queryByRole("button", { name: "Guest Wi-Fi" })).toBeNull();
  fireEvent.change(screen.getByLabelText(/Enter the Wi-Fi password\./), {
    target: { value: "short" },
  });
  await flush();
  expect(join.disabled).toBe(true);
  fireEvent.change(screen.getByLabelText(/Enter the Wi-Fi password\./), {
    target: { value: "test-password" },
  });
  await flush();
  expect(join.disabled).toBe(false);
  fireEvent.click(join);
  await flush();
  expect(core.sent).toContainEqual([
    "deviceSetup.event",
    { type: "join", ssid: "Test Wi-Fi", password: "test-password" },
  ]);
  fireEvent.click(screen.getByRole("button", { name: "Change network" }));
  await flush();
  expect(join.disabled).toBe(true);
  fireEvent.click(screen.getByRole("button", { name: "Guest Wi-Fi" }));
  await flush();
  expect(screen.queryByLabelText(/Enter the Wi-Fi password\./)).toBeNull();
  expect(join.disabled).toBe(false);
  fireEvent.click(join);
  await flush();
  expect(core.sent).toContainEqual([
    "deviceSetup.event",
    { type: "join", ssid: "Guest Wi-Fi", password: "" },
  ]);
});

it("keeps the typed device name and sends it before the join", async () => {
  const core = createScriptedCore({
    values: () => ({
      supported: true,
      bluetooth: "on",
      state: {
        step: "wifi",
        device: { id: "nearby", name: "Comma-6AD8", rssi: -50 },
        name: "Comma-6AD8",
        scanning: false,
        failure: null,
        networks: [{ ssid: "Guest Wi-Fi", rssi: -60, secure: false }],
      },
    }),
  });
  render(
    <CommaI18nProvider locale="en">
      <CoreProvider client={core.client}>
        <AddDevice workspace="wsp" onClose={() => {}} />
      </CoreProvider>
    </CommaI18nProvider>
  );
  await flush();
  const name = screen.getByLabelText(/^Name/) as HTMLInputElement;
  fireEvent.change(name, { target: { value: "Kitchen " } });
  await flush();
  expect(name.value).toBe("Kitchen ");
  fireEvent.click(screen.getByRole("button", { name: "Guest Wi-Fi" }));
  await flush();
  const join = screen.getByRole("button", { name: /^Join/ }) as HTMLButtonElement;
  fireEvent.change(name, { target: { value: "" } });
  await flush();
  expect(name.value).toBe("");
  expect(join.disabled).toBe(true);
  fireEvent.change(name, { target: { value: "Kitchen Speaker" } });
  await flush();
  expect(
    core.sent.filter(([, p]) => (p as { type?: string }).type === "rename")
  ).toEqual([]);
  fireEvent.click(join);
  await flush();
  const events = core.sent
    .filter(([n]) => n === "deviceSetup.event")
    .map(([, p]) => p as { type: string });
  expect(events.slice(-2)).toEqual([
    { type: "rename", name: "Kitchen Speaker" },
    { type: "join", ssid: "Guest Wi-Fi", password: "" },
  ]);
});

import type { DevicesValue, ModelsValue, ShownDevice } from "@comma/core/contract";
import { CommaI18nProvider } from "@comma/i18n/react";
import { flush } from "@comma/test-utils/fake-clock";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { render, screen, within } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { expect, it, vi } from "vitest";
import { TaskRunDialog } from "../TaskRunDialog";

const WORKSPACE = "wsp_run";

const studio: ShownDevice = {
  device_id: "dev_studio",
  name: "studio.local",
  alias: "Studio Mac",
  status: "connected",
  allows_operations: true,
  tasks_readiness: "ready",
  task_models: { claude: ["claude-opus-5-5"] },
  device_runtimes: [],
};

async function open(onSwitch: (run: unknown) => Promise<unknown>) {
  const scripted = createScriptedCore({
    values: (topic): ModelsValue | DevicesValue | undefined =>
      topic.topic === "devices"
        ? {
            workspace: WORKSPACE,
            devices: [studio],
            cloud: null,
            hasMore: false,
            loading: false,
            failed: false,
            checks: {},
          }
        : topic.topic === "models"
          ? {
              workspace: WORKSPACE,
              catalog: { sources: {}, models: [] },
              presets: [],
              profiles: [],
              moreProfiles: false,
              models: [
                {
                  id: "gpt-5.5",
                  name: "GPT-5.5",
                  vendor: "openai",
                  efforts: [],
                  routes: {},
                  serving: ["prf_1"],
                },
              ],
              agents: null,
              error: false,
            }
          : undefined,
  });
  const onClose = vi.fn();
  const user = userEvent.setup({ advanceTimers: vi.advanceTimersByTime });
  render(
    scripted.wrap(
      <CommaI18nProvider locale="en">
        <TaskRunDialog
          onClose={onClose}
          onSwitch={onSwitch}
          run={{
            place: { kind: "station", deviceId: "dev_studio", name: "Studio Mac" },
            model: { kind: "runtime", provider: "codex" },
          }}
          workspaceId={WORKSPACE}
        />
      </CommaI18nProvider>
    )
  );
  await flush();
  const dialog = within(screen.getByRole("dialog", { name: "Switch model" }));
  return { dialog, onClose, user };
}

const options = () =>
  within(document.querySelector<HTMLElement>('[data-slot="dropdown-popover"]')!);

it("lists Comma's models and each computer's under where they run, and runs the Task on the one picked", async () => {
  const onSwitch = vi.fn(async () => undefined);
  const { dialog, onClose, user } = await open(onSwitch);
  expect(dialog.getByTestId("task-run-current")).toHaveTextContent(
    "NowStudio Mac · Codex default model"
  );
  expect(dialog.getByRole("button", { name: "Switch" })).toBeDisabled();
  await user.click(dialog.getByRole("button", { name: /Switch to/ }));
  for (const name of [
    "Default model",
    "GPT-5.5",
    "Claude Code default model",
    "claude-opus-5-5",
  ])
    expect(options().getByRole("option", { name })).toBeInTheDocument();
  await user.click(options().getByRole("option", { name: "GPT-5.5" }));
  await user.click(dialog.getByRole("button", { name: "Switch" }));
  await flush();
  expect(onSwitch).toHaveBeenCalledWith({
    runsOn: { kind: "salix" },
    model: { kind: "catalog", model: "gpt-5.5" },
  });
  expect(onClose).toHaveBeenCalledOnce();
});

it("says why a computer did not take the Task, and stays open", async () => {
  const onSwitch = vi.fn(async () => {
    throw Object.assign(new Error("refused"), {
      detail: {
        code: "task_run_refused",
        reason: "device_offline",
        message: "that station is not connected now",
      },
    });
  });
  const { dialog, onClose, user } = await open(onSwitch);
  await user.click(dialog.getByRole("button", { name: /Switch to/ }));
  await user.click(options().getByRole("option", { name: "claude-opus-5-5" }));
  await user.click(dialog.getByRole("button", { name: "Switch" }));
  await flush();
  expect(onSwitch).toHaveBeenCalledWith({
    runsOn: { kind: "station", deviceId: "dev_studio" },
    model: { kind: "runtime", provider: "claude", model: "claude-opus-5-5" },
  });
  expect(dialog.getByRole("alert")).toHaveTextContent(
    "That computer isn't connected now."
  );
  expect(onClose).not.toHaveBeenCalled();
});

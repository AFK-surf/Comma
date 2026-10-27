import type { ChatMessage } from "@comma/core/chat";
import type { DevicesValue, ModelsValue } from "@comma/core/contract";
import { CommaI18nProvider } from "@comma/i18n/react";
import { flush } from "@comma/test-utils/fake-clock";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { render, screen, within } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { expect, it, vi } from "vitest";
import { TaskRunBlockedCard } from "../TaskRunBlockedCard";
import { TaskRunSwitchContext, type TaskRunSwitch } from "../taskRunSwitch";

const blocked = {
  messageId: "msg_blocked",
  messageType: "task_run_blocked",
  runBlockedError: "No account is chosen to run Codex on this computer",
  text: "⚠️ cannot start",
} as ChatMessage;

const scripted = () =>
  createScriptedCore({
    values: (topic): ModelsValue | DevicesValue | undefined =>
      topic.topic === "devices"
        ? {
            workspace: "w",
            devices: [],
            cloud: null,
            hasMore: false,
            loading: false,
            failed: false,
            checks: {},
          }
        : topic.topic === "models"
          ? {
              workspace: "w",
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

function show(taskRun: TaskRunSwitch | undefined) {
  render(
    scripted().wrap(
      <CommaI18nProvider locale="en">
        <TaskRunSwitchContext.Provider value={taskRun}>
          <TaskRunBlockedCard message={blocked} />
        </TaskRunSwitchContext.Provider>
      </CommaI18nProvider>
    )
  );
}

it("says why the model cannot start and switches it from the card while it stands", async () => {
  const switchRun = vi.fn(async () => undefined);
  show({
    blockedMessageId: "msg_blocked",
    run: {
      place: { kind: "station", deviceId: "dev_mac", name: "Studio Mac" },
      model: { kind: "runtime", provider: "codex" },
    },
    switchRun,
    workspaceId: "w",
  });
  await flush();
  const card = within(screen.getByTestId("task-run-blocked"));
  expect(card.getByText("Model can't start")).toBeInTheDocument();
  expect(
    card.getByText("No account is chosen to run Codex on this computer")
  ).toBeInTheDocument();
  const user = userEvent.setup({ advanceTimers: vi.advanceTimersByTime });
  expect(card.getByRole("button", { name: "Switch" })).toBeDisabled();
  await user.click(card.getByRole("button", { name: /Switch to/ }));
  await user.click(
    within(
      document.querySelector<HTMLElement>('[data-slot="dropdown-popover"]')!
    ).getByRole("option", { name: "GPT-5.5" })
  );
  await user.click(card.getByRole("button", { name: "Switch" }));
  await flush();
  expect(switchRun).toHaveBeenCalledWith({
    runsOn: { kind: "salix" },
    model: { kind: "catalog", model: "gpt-5.5" },
  });
});

it("keeps only what happened once the Task runs on another model", async () => {
  show({
    blockedMessageId: undefined,
    run: undefined,
    switchRun: vi.fn(),
    workspaceId: "w",
  });
  await flush();
  expect(screen.getByTestId("task-run-blocked")).toHaveTextContent(
    "No account is chosen to run Codex on this computer"
  );
  expect(screen.queryByTestId("task-run-blocked-choice")).toBeNull();
});

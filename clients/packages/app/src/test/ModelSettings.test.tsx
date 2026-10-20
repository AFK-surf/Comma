import type {
  AgentSelection,
  DevicesValue,
  ModelCatalog,
  ModelProfile,
  ModelsValue,
  SettingsAgent,
  ShownDevice,
  TaskModelSelection,
  TaskPlace,
} from "@comma/core/contract";
import { modelsView } from "@comma/core/testing";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { advance, flush } from "@comma/test-utils/fake-clock";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { render, screen, waitFor, within } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { Toaster } from "@comma/ui/components/toast";
import { beforeEach, expect, it, vi } from "vitest";
import { useModelsCategory } from "../components/models/useModelsCategory";
import { SettingsCategory } from "./settingsHarness";

// Settings › Model & API over a scripted core: the page shows what the core
// sends for a catalog, profiles and Agents (`modelsView`, the core's own) and
// asks the core for each change. What the core then sends to the server, the
// versions, retries and rereads, is the core's own and tested in
// packages/core/test/models.test.ts.

const workspace = "wsp_models";

const catalog: ModelCatalog = {
  sources: {
    openai: { name: "OpenAI", kind: "api_key" },
    anthropic: { name: "Anthropic", kind: "api_key" },
    openrouter: { name: "OpenRouter", kind: "api_key" },
    codex: { name: "ChatGPT", kind: "subscription" },
    claude: { name: "Claude", kind: "subscription" },
    "github-copilot": { name: "GitHub Copilot", kind: "subscription" },
    custom: {
      name: "Custom",
      kind: "api_key",
      endpoint_required: true,
      protocols: ["chat_completions", "responses", "anthropic"],
    },
  },
  models: [
    {
      id: "gpt-5.5",
      name: "GPT-5.5",
      family: "GPT",
      vendor: "openai",
      efforts: ["low", "high"],
      routes: {
        openai: { model: "gpt-5.5", protocol: "responses" },
        codex: { model: "gpt-5.5", protocol: "responses" },
        openrouter: { model: "openai/gpt-5.5", protocol: "chat_completions" },
      },
    },
    {
      id: "claude-opus-5",
      name: "Opus 5",
      family: "Opus",
      vendor: "anthropic",
      efforts: ["low", "high"],
      routes: {
        anthropic: { model: "claude-opus-5", protocol: "anthropic" },
        claude: { model: "claude-opus-5", protocol: "anthropic" },
        openrouter: { model: "anthropic/claude-opus-5", protocol: "anthropic" },
      },
    },
    {
      id: "claude-sonnet-4-5",
      name: "Sonnet 4.5",
      family: "Sonnet",
      vendor: "anthropic",
      efforts: ["low", "high"],
      routes: {
        openrouter: { model: "anthropic/claude-sonnet-4.5", protocol: "anthropic" },
      },
    },
  ],
};

const codex: ModelProfile = {
  id: "profile-codex",
  credential_kind: "subscription_oauth",
  source: "codex",
  provider: "codex",
  name: "member@example.com",
  email: "member@example.com",
  disabled: false,
  status: "active",
  version: "v1",
  quota: {
    plan_type: "pro",
    windows: [
      { period: "5h", remaining_percent: 62, reset_at: "2027-01-01T03:00:00Z" },
      { period: "week", remaining_percent: 8, reset_at: "2027-01-05T00:00:00Z" },
    ],
  },
};
const openrouterKey: ModelProfile = {
  id: "profile-key",
  credential_kind: "provider_api_key",
  source: "openrouter",
  name: "Team router",
  key_hint: "sk-…or42",
  disabled: false,
  status: "active",
  version: "v1",
};
const router: SettingsAgent = { agent_id: "router", name: "Router", role: "router" };

type State = {
  catalog?: ModelCatalog;
  profiles: ModelProfile[];
  router?: SettingsAgent;
  /** The workspace's default Task model; Comma's own when unset. */
  taskModel?: TaskModelSelection;
  /** Where the workspace's Tasks run; Comma's cloud when unset. */
  taskPlace?: TaskPlace;
  /** The person's computers and the workspace's Cloud VM, as the core lists them. */
  computers?: { devices: ShownDevice[]; cloud: ShownDevice | null };
};
type Answer = (params: Record<string, unknown>) => unknown;

/**
 * The page over a core that keeps `state`: it sends the page what the core
 * would for it, and answers each call by `answers` (else with nothing). A new
 * model for the Router or for Tasks, and a new place for Tasks, shows at once,
 * as the core shows it.
 */
async function openModels(state: State, answers: Record<string, Answer> = {}) {
  const calls: [string, Record<string, unknown>][] = [];
  state.router ??= { ...router };
  const scripted = createScriptedCore({
    values: (topic): ModelsValue | DevicesValue | undefined => {
      if (topic.topic === "devices")
        return {
          workspace,
          devices: state.computers?.devices ?? [],
          cloud: state.computers?.cloud ?? null,
          hasMore: false,
          loading: false,
          failed: false,
          checks: {},
        };
      if (topic.topic !== "models") return undefined;
      const shown = state.catalog ?? catalog;
      return {
        workspace,
        catalog: shown,
        ...modelsView(shown, state.profiles),
        moreProfiles: false,
        agents: {
          workspace_id: workspace,
          agents: { router: state.router! },
          task_model: { selection: state.taskModel ?? { kind: "builtin" } },
          task_place: { place: state.taskPlace ?? { kind: "salix" } },
        },
        error: false,
      };
    },
    calls: (name, raw) => {
      const params = raw as Record<string, unknown>;
      calls.push([name, params]);
      const answered = answers[name]?.(params);
      if (name === "models.setAgentModel") {
        state.router!.selection = params.selection as AgentSelection;
        scripted.changed("models");
      }
      if (name === "models.setTaskModel") {
        state.taskModel = params.selection as TaskModelSelection;
        scripted.changed("models");
      }
      if (name === "models.setTaskPlace") {
        state.taskPlace = params.place as TaskPlace;
        scripted.changed("models");
      }
      return answered;
    },
  });
  // On the fake clock, user-event's pause between events is a timer too.
  const user = userEvent.setup({ advanceTimers: vi.advanceTimersByTime });
  render(scripted.wrap(<ModelsPage />));
  // The core sends what it keeps as microtasks: no time passes.
  await flush();
  screen.getByRole("button", { name: "Router" });
  return {
    user,
    /** The params of each call to `name`, in order. */
    called: (name: string) => calls.filter(([n]) => n === name).map(([, p]) => p),
    /** The core sends what it keeps now. */
    changed: () => scripted.changed("models"),
  };
}

function ModelsPage() {
  return <SettingsCategory category={useModelsCategory(true).category} />;
}

/**
 * A row of the page, by its setting: an Agent's, a profile's, or the default
 * Task model's (`task-model`) or place's (`task-place`).
 */
const row = (id: string) =>
  document.querySelector<HTMLElement>(
    `[data-setting-id="models.agent.${id}"], [data-setting-id="models.profile.${id}"], [data-setting-id="models.${id}"]`
  )!;
/** An Agent's model picker, on its row. */
const picker = (agent: string, name: string) =>
  within(row(agent)).getByRole("button", { name });
const TASK_MODEL = "Default Task model";
/** The default Task model's picker. */
const taskPicker = () => picker("task-model", TASK_MODEL);
/** The default place to run Tasks' dropdown, and its open options. */
const placePicker = () =>
  within(row("task-place")).getByRole("button", { name: /Default place to run Tasks/ });
const placeOptions = () =>
  within(document.querySelector<HTMLElement>('[data-slot="dropdown-popover"]')!);
/** Settings' content column: the page, or the second-level page open in it. */
const settingsContent = () => within(screen.getByLabelText("Settings content"));
/** An open picker or panel, by its name. */
const panel = (name: string | RegExp) => within(screen.getByRole("dialog", { name }));
const lastSelection = (
  called: (name: string) => Record<string, unknown>[],
  name = "models.setTaskModel"
) => called(name).at(-1)?.selection;

beforeEach(() => {
  installNativeBridgeMock({ platform: "web" });
});

/**
 * One frame on the fake clock: a closed nested panel returns focus to what
 * opened it.
 */
const frameMs = 16;

it("asks the core to read the page as it opens", async () => {
  // The menu-bar item can hold the topic, which then reads nothing as the page opens.
  const t = await openModels({ profiles: [structuredClone(codex)] });
  expect(t.called("models.refresh")).toEqual([{}]);
});

it("selects GPT-6.1 Sol from the released catalog with a Codex subscription", async () => {
  const released = JSON.parse(
    readFileSync(
      resolve(process.cwd(), "../systems/apps/salix_agent/priv/model_catalog.json"),
      "utf8"
    )
  ) as ModelCatalog;
  const state: State = { catalog: released, profiles: [codex] };
  const t = await openModels(state);

  await t.user.click(picker("router", "Router"));
  // The catalog lists many models: each is found under its family.
  await t.user.click(
    within(panel("Router").getByRole("group", { name: "GPT Sol" })).getByRole(
      "button",
      {
        name: "GPT-6.1 Sol",
      }
    )
  );
  await t.user.click(
    within(panel("Router").getByRole("region", { name: "Thinking effort" })).getByRole(
      "button",
      { name: "max" }
    )
  );
  expect(lastSelection(t.called, "models.setAgentModel")).toEqual({
    kind: "catalog",
    model: "gpt-6.1-sol",
    reasoning_effort: "max",
    allow_paid: false,
    profile_id: null,
  });
  await t.user.click(panel("Router").getByRole("button", { name: "Account" }));
  await t.user.click(panel("Account").getByText(codex.name!));
  expect(lastSelection(t.called, "models.setAgentModel")).toEqual({
    kind: "catalog",
    model: "gpt-6.1-sol",
    reasoning_effort: "max",
    allow_paid: false,
    profile_id: codex.id,
  });

  await advance(frameMs);
  expect(panel("Router").getByRole("button", { name: "Account" })).toHaveFocus();
  await closePicker(t.user, "Router");
  expect(picker("router", "Router")).toHaveTextContent("GPT-6.1 Sol");
});

/** A Codex plan with resets left, and `answer` for each reset the page asks for. */
async function resettable(answer: Answer = () => null) {
  const member: ModelProfile = {
    ...structuredClone(codex),
    quota: { ...structuredClone(codex.quota), reset_credits: { available_count: 2 } },
  };
  const t = await openModels(
    {
      profiles: [
        member,
        // A sign-in that expired cannot reset until it is renewed.
        {
          ...structuredClone(member),
          id: "profile-expired",
          name: "expired@example.com",
          email: "expired@example.com",
          status: "expired",
        },
      ],
    },
    { "models.resetQuota": answer }
  );
  // The row's own fix, beside the meter running low.
  await t.user.click(
    within(row("profile-codex")).getByRole("button", {
      name: "Reset quota for member@example.com",
    })
  );
  return { ...t, member, reset: panel(/^Reset quota for /) };
}

it("offers a Codex quota reset on a signed-in plan, and renewal on an expired one", async () => {
  const t = await resettable();
  await t.user.click(t.reset.getByRole("button", { name: "Cancel" }));
  await t.user.click(
    within(row("profile-expired")).getByRole("button", {
      name: "Actions for expired@example.com",
    })
  );
  expect(
    await screen.findByRole("menuitem", { name: "Reset quota (2 resets left)" })
  ).toHaveAttribute("aria-disabled", "true");
  await t.user.keyboard("{Escape}");
  expect(
    within(row("profile-expired")).getByRole("button", {
      name: "Re-authorize expired@example.com",
    })
  ).toBeInTheDocument();
});

it("retries an unconfirmed quota reset until it is confirmed", async () => {
  const outcomes: (() => unknown)[] = [
    // No answer: the reset may have run.
    () => {
      throw new Error("unavailable");
    },
    () => {
      t.member.quota!.reset_credits = { available_count: 1 };
      t.changed();
      return { outcome: "reset", quota_refreshed: true };
    },
  ];
  const t = await resettable(() => outcomes.shift()!());
  await t.user.click(t.reset.getByRole("button", { name: "Reset quota" }));
  expect(
    await t.reset.findByText(/The reset could not be confirmed\./)
  ).toBeInTheDocument();
  await t.user.click(t.reset.getByRole("button", { name: "Reset quota" }));
  expect(await t.reset.findByText(/Quota reset confirmed\./)).toBeInTheDocument();
  expect(t.called("models.resetQuota")).toEqual([
    { workspace, profile: "profile-codex" },
    { workspace, profile: "profile-codex" },
  ]);
  // Settled: only Close is left, and the menu counts what the core says is left.
  await t.user.click(t.reset.getByRole("button", { name: "Close" }));
  await t.user.click(
    within(row("profile-codex")).getByRole("button", {
      name: "Actions for member@example.com",
    })
  );
  expect(
    await screen.findByRole("menuitem", { name: "Reset quota (1 reset left)" })
  ).toBeInTheDocument();
});

it("says a quota reset was refused for a profile changed elsewhere, and tries again", async () => {
  const outcomes: (() => unknown)[] = [
    () => {
      throw Object.assign(new Error("conflict"), { code: "conflict", status: 409 });
    },
    () => ({ outcome: "reset", quota_refreshed: true }),
  ];
  const t = await resettable(() => outcomes.shift()!());
  await t.user.click(t.reset.getByRole("button", { name: "Reset quota" }));
  expect(
    await t.reset.findByText(/This profile changed elsewhere\./)
  ).toBeInTheDocument();
  await t.user.click(t.reset.getByRole("button", { name: "Reset quota" }));
  expect(await t.reset.findByText(/Quota reset confirmed\./)).toBeInTheDocument();
});

it("re-authorizes a subscription at its current version and shows the device code", async () => {
  const t = await openModels(
    { profiles: [{ ...structuredClone(codex), version: "v3" }] },
    {
      "models.signIn.begin": () => ({
        id: "attempt-1",
        url: "https://example.com/device",
        expires_at: "2099-01-01T00:00:00Z",
        mode: "device",
        user_code: "ABCD-1234",
        interval: 5,
      }),
      // The core waits on the device code until the user finishes.
      "models.signIn.wait": () => new Promise(() => {}),
    }
  );
  await t.user.click(
    within(row("profile-codex")).getByRole("button", {
      name: "Actions for member@example.com",
    })
  );
  // Renewing has nothing to fill in: its sign-in starts at once.
  await t.user.click(await screen.findByRole("menuitem", { name: "Re-authorize" }));
  expect(
    await screen.findByRole("heading", { name: "Re-authorize member@example.com" })
  ).toBeInTheDocument();
  expect(await screen.findByRole("status", { name: "Device code" })).toHaveTextContent(
    "ABCD-1234"
  );
  expect(t.called("models.signIn.begin")).toEqual([
    { workspace, provider: "codex", account: "profile-codex", version: "v3" },
  ]);
});

it("serves a TokenDance profile's listed catalog models under its own name", async () => {
  const t = await openModels({
    profiles: [
      {
        // What one-click TokenDance saves: a Custom key on its gateway.
        id: "profile-tokendance",
        credential_kind: "provider_api_key",
        source: "custom",
        name: "TokenDance",
        key_hint: "td-…9f2c",
        models: ["claude-sonnet-4-5", "video-model"],
        connection: {
          endpoint: "https://tokendance.space/gateway/v1/chat/completions",
          protocol: "openai_completions",
        },
        disabled: false,
        status: "active",
        version: "v1",
      },
    ],
  });
  expect(row("profile-tokendance")).toHaveTextContent(
    "TokenDance · API key · td-…9f2c"
  );
  await t.user.click(
    within(row("profile-tokendance")).getByRole("button", {
      name: "Actions for TokenDance",
    })
  );
  await t.user.click(await screen.findByRole("menuitem", { name: "View models" }));
  const models = settingsContent();
  expect(await models.findByText("Sonnet 4.5")).toBeInTheDocument();
  expect(models.queryByText("Opus 5")).toBeNull();
});

/** What the core saves for Ollama: a key-less Custom profile serving the models it listed. */
const ollama: ModelProfile = {
  id: "profile-ollama",
  credential_kind: "provider_api_key",
  source: "custom",
  name: "Ollama",
  models: ["llama3.2:3b"],
  connection: {
    endpoint: "https://ollama.example.com/v1",
    protocol: "openai_completions",
  },
  disabled: false,
  status: "active",
  version: "v1",
};

it("connects Ollama as an endpoint whose models are listed, and says the first profile is added", async () => {
  const state: State = { profiles: [] };
  const t = await openModels(state, {
    "models.createProfile": () => {
      state.profiles.push(ollama);
      t.changed();
      return ollama;
    },
  });
  render(<Toaster />);
  await t.user.click(screen.getByRole("button", { name: "Add profile" }));
  await t.user.click(
    within(screen.getByRole("region", { name: "Local & custom" })).getByRole("button", {
      name: "Ollama",
    })
  );
  // Ollama speaks Chat Completions and needs no key.
  const form = settingsContent();
  expect(form.queryByRole("button", { name: "Protocol" })).toBeNull();
  await t.user.click(form.getByRole("textbox", { name: "Base URL" }));
  await t.user.paste("https://ollama.example.com/v1");
  await t.user.click(form.getByRole("button", { name: "Connect" }));
  expect(
    await screen.findByText("Profile added. Agents use it automatically.")
  ).toBeInTheDocument();
  // The core lists the endpoint's models before it saves the profile.
  expect(t.called("models.createProfile")).toEqual([
    {
      workspace,
      source: "custom",
      name: "Ollama",
      base_url: "https://ollama.example.com/v1",
      protocol: "chat_completions",
      discover: true,
    },
  ]);
  await waitFor(() => expect(row("profile-ollama")).toBeInTheDocument());
});

it("lets Tasks run a model only a Custom endpoint lists", async () => {
  const t = await openModels({ profiles: [ollama] });
  // Its model is not in the catalog, yet it can be the default.
  await t.user.click(taskPicker());
  await t.user.click(
    within(panel(TASK_MODEL).getByRole("group", { name: "Custom" })).getByRole(
      "button",
      { name: "llama3.2:3b" }
    )
  );
  expect(lastSelection(t.called)).toEqual({
    kind: "catalog",
    model: "llama3.2:3b",
    reasoning_effort: null,
    allow_paid: false,
    profile_id: null,
  });
});

/**
 * Model & API with one Codex profile that serves GPT-5.5 and GPT-5.4, and Tasks
 * on GPT-5.4: the models a profile offers, as its page lists them. The
 * core shows a profile's choice at once; `refuse` makes it refuse.
 */
async function profileModels(turnedOff: string[] = []) {
  const gpt54 = {
    id: "gpt-5.4",
    name: "GPT-5.4",
    family: "GPT",
    vendor: "openai",
    efforts: ["low", "high"],
    routes: { codex: { model: "gpt-5.4", protocol: "responses" as const } },
  };
  const member: ModelProfile = {
    ...structuredClone(codex),
    disabled_models: turnedOff,
  };
  const answer = { refuse: false };
  const t = await openModels(
    {
      // Catalog order is oldest first; a family lists its newest model first.
      catalog: { ...catalog, models: [gpt54, ...catalog.models] },
      profiles: [member],
      taskModel: {
        kind: "catalog",
        model: "gpt-5.4",
        reasoning_effort: "high",
        allow_paid: false,
        profile_id: null,
      },
    },
    {
      "models.offer": (params) => {
        if (answer.refuse)
          throw Object.assign(new Error("conflict"), { code: "conflict", status: 409 });
        const off = new Set(member.disabled_models);
        for (const id of params.models as string[]) {
          if (params.on) off.delete(id);
          else off.add(id);
        }
        member.disabled_models = [...off];
        t.changed();
      },
    }
  );
  return {
    ...t,
    answer,
    content: settingsContent,
    model: (name: string) => settingsContent().getByRole("checkbox", { name }),
    offered: () => t.called("models.offer").at(-1),
    viewModels: async () => {
      await t.user.click(
        within(row("profile-codex")).getByRole("button", {
          name: "Actions for member@example.com",
        })
      );
      await t.user.click(await screen.findByRole("menuitem", { name: "View models" }));
    },
    backToList: () =>
      t.user.click(settingsContent().getByRole("button", { name: "Model & API" })),
    /** How many of the default Task model's picker choices are named `name`. */
    pickerHas: async (name: string) => {
      await t.user.click(taskPicker());
      const count = panel(TASK_MODEL).queryAllByRole("button", { name }).length;
      await t.user.keyboard("{Escape}");
      return count;
    },
  };
}

it("turns a model off for a profile, and the picker no longer offers it", async () => {
  const t = await profileModels();
  await t.viewModels();
  expect(t.content().getByRole("heading", { name: "GPT" })).toBeInTheDocument();
  // The model's ids show on hover.
  expect(t.model("GPT-5.5").closest("label")).toHaveAttribute("title", "gpt-5.5");
  expect(t.model("GPT-5.5")).toBeChecked();
  expect(t.model("GPT-5.4")).toBeChecked();
  // Opus runs on no profile here, so it is not listed.
  expect(t.content().queryByRole("checkbox", { name: "Opus 5" })).toBeNull();

  // Off on the only profile that serves it: gone from the picker.
  await t.user.click(t.model("GPT-5.5"));
  expect(t.offered()).toEqual({
    workspace,
    profile: "profile-codex",
    models: ["gpt-5.5"],
    on: false,
  });
  expect(t.model("GPT-5.5")).not.toBeChecked();
  await t.backToList();
  expect(await t.pickerHas("GPT-5.5")).toBe(0);
  expect(await t.pickerHas("GPT-5.4")).toBe(1);
});

it("turns a model on again for a profile, and the picker offers it again", async () => {
  const t = await profileModels(["gpt-5.5"]);
  expect(await t.pickerHas("GPT-5.5")).toBe(0);
  await t.viewModels();
  expect(t.model("GPT-5.5")).not.toBeChecked();
  await t.user.click(t.model("GPT-5.5"));
  expect(t.offered()).toMatchObject({ models: ["gpt-5.5"], on: true });
  await t.backToList();
  expect(await t.pickerHas("GPT-5.5")).toBe(1);
});

it("turns a whole family off and on at once, and says when a change is refused", async () => {
  const t = await profileModels();
  await t.viewModels();
  await t.user.click(t.content().getByRole("button", { name: "Clear all GPT models" }));
  expect(t.offered()).toMatchObject({ models: ["gpt-5.5", "gpt-5.4"], on: false });
  expect(t.model("GPT-5.5")).not.toBeChecked();
  expect(t.model("GPT-5.4")).not.toBeChecked();
  await t.user.click(
    t.content().getByRole("button", { name: "Select all GPT models" })
  );
  expect(t.offered()).toMatchObject({ models: ["gpt-5.5", "gpt-5.4"], on: true });

  // A refused change says so, and the page keeps what the core holds.
  t.answer.refuse = true;
  await t.user.click(t.model("GPT-5.4"));
  expect(
    await screen.findByText(/This profile changed elsewhere\./)
  ).toBeInTheDocument();
  expect(t.model("GPT-5.4")).toBeChecked();
});

/** Escape closes the picker, which holds focus, also after an account is chosen. */
async function closePicker(user: ReturnType<typeof userEvent.setup>, name: string) {
  expect(screen.getByRole("dialog", { name })).toContainElement(
    document.activeElement as HTMLElement
  );
  await user.keyboard("{Escape}");
}

const familyState = (): State => ({
  profiles: [structuredClone(codex), structuredClone(openrouterKey)],
  taskModel: {
    kind: "catalog",
    model: "gpt-5.5",
    reasoning_effort: "high",
    allow_paid: false,
    profile_id: null,
  },
});

it("chooses the default Task model by family, waits for its effort, and gates pay-per-use", async () => {
  const t = await openModels(familyState());
  expect(picker("router", "Router")).toHaveTextContent("Comma built-in (recommended)");
  // The row shows the core's choice for the workspace.
  expect(row("task-model")).toHaveTextContent(
    "Tasks run this model unless they name another."
  );
  expect(taskPicker()).toHaveTextContent("GPT-5.5");
  expect(taskPicker()).toHaveTextContent("high");
  expect(taskPicker()).toHaveTextContent("Automatic");

  // One panel: models under their families; a new model waits for its effort.
  await t.user.click(taskPicker());
  expect(panel(TASK_MODEL).getByRole("group", { name: "Sonnet" })).toBeInTheDocument();
  await t.user.click(panel(TASK_MODEL).getByRole("button", { name: "Opus 5" }));
  expect(panel(TASK_MODEL).getByRole("button", { name: "high" })).toHaveAttribute(
    "aria-pressed",
    "false"
  );
  expect(t.called("models.setTaskModel")).toEqual([]);
  await t.user.click(panel(TASK_MODEL).getByRole("button", { name: "high" }));
  expect(t.called("models.setTaskModel")).toEqual([
    {
      workspace,
      selection: {
        kind: "catalog",
        model: "claude-opus-5",
        reasoning_effort: "high",
        allow_paid: false,
        profile_id: null,
      },
    },
  ]);
  // The Router keeps its own model.
  expect(t.called("models.setAgentModel")).toEqual([]);
  // Only an API key serves Opus 5 here, so subscriptions-only cannot run it.
  await flush();
  expect(
    within(row("task-model")).getByText(/No enabled subscription serves this model/)
  ).toBeInTheDocument();

  // The account: automatic with pay-per-use allowed, then kept to one key.
  await t.user.click(panel(TASK_MODEL).getByRole("button", { name: "Account" }));
  await t.user.click(
    panel("Account").getByRole("switch", { name: "Allow pay-per-use (API keys)" })
  );
  expect(lastSelection(t.called)).toMatchObject({ allow_paid: true, profile_id: null });
  await flush();
  expect(
    within(row("task-model")).queryByText(/No enabled subscription serves this model/)
  ).toBeNull();
  await t.user.click(panel("Account").getByRole("button", { name: /Team router/ }));
  expect(lastSelection(t.called)).toEqual({
    kind: "catalog",
    model: "claude-opus-5",
    reasoning_effort: "high",
    allow_paid: true,
    profile_id: "profile-key",
  });
  await advance(frameMs);
  expect(panel(TASK_MODEL).getByRole("button", { name: "Account" })).toHaveFocus();
  await closePicker(t.user, TASK_MODEL);
  expect(taskPicker()).toHaveTextContent("Team router");
  expect(taskPicker()).toHaveAccessibleDescription(/Opus 5/);

  // Back to Comma's own model.
  await t.user.click(taskPicker());
  await t.user.click(
    panel(TASK_MODEL).getByRole("button", { name: /Comma built-in \(recommended\)/ })
  );
  expect(lastSelection(t.called)).toEqual({ kind: "builtin" });
});

it("keeps the default Task model on what the core holds when a choice is refused, and shows a later one", async () => {
  let refuse = true;
  const t = await openModels(familyState(), {
    "models.setTaskModel": () => {
      if (refuse)
        throw Object.assign(new Error("invalid_model_configuration"), {
          code: "invalid_model_configuration",
          status: 400,
        });
    },
  });
  // The core refuses and keeps the workspace's model: no change goes out.
  await t.user.click(taskPicker());
  await t.user.click(panel(TASK_MODEL).getByRole("button", { name: "Sonnet 4.5" }));
  await t.user.click(panel(TASK_MODEL).getByRole("button", { name: "high" }));
  await closePicker(t.user, TASK_MODEL);
  expect(
    await within(row("task-model")).findByText("Something went wrong. Try again.")
  ).toBeInTheDocument();
  expect(taskPicker()).toHaveTextContent("GPT-5.5");

  refuse = false;
  await t.user.click(taskPicker());
  await t.user.click(panel(TASK_MODEL).getByRole("button", { name: "Sonnet 4.5" }));
  await t.user.click(panel(TASK_MODEL).getByRole("button", { name: "low" }));
  await closePicker(t.user, TASK_MODEL);
  expect(taskPicker()).toHaveTextContent("Sonnet 4.5");
  expect(
    within(row("task-model")).queryByText("Something went wrong. Try again.")
  ).toBeNull();
});

it("shows a choice kept to a removed profile as it is", async () => {
  await openModels({
    profiles: [structuredClone(codex), structuredClone(openrouterKey)],
    taskModel: {
      kind: "catalog",
      model: "gpt-5.5",
      reasoning_effort: null,
      allow_paid: false,
      profile_id: "profile-gone",
    },
  });
  // A pin to a removed profile says so instead of reading as automatic.
  expect(taskPicker()).toHaveTextContent("Removed profile");
  expect(row("task-model")).toHaveTextContent(
    "The profile this Agent keeps to is off, removed"
  );
});

it("renames the Router from its row's actions", async () => {
  const state = familyState();
  const t = await openModels(state, {
    "models.renameAgent": (params) => {
      state.router!.name = params.name as string;
      t.changed();
    },
  });
  await t.user.click(
    within(row("router")).getByRole("button", { name: "Actions for Router" })
  );
  await t.user.click(await screen.findByRole("menuitem", { name: "Rename" }));
  const rename = panel("Rename Agent");
  const nameField = rename.getByRole("textbox", { name: "Name" });
  expect(nameField).toHaveValue("Router");
  await t.user.clear(nameField);
  await t.user.type(nameField, "Atlas{Enter}");
  expect(
    await within(row("router")).findByRole("button", { name: "Atlas" })
  ).toBeInTheDocument();
  expect(t.called("models.renameAgent")).toEqual([
    { workspace, agent: "router", name: "Atlas" },
  ]);
});

const studio: ShownDevice = {
  device_id: "dev-studio",
  name: "studio.local",
  alias: "Studio Mac",
  status: "connected",
  allows_operations: true,
  device_runtimes: [],
};
const cloudVm: ShownDevice = {
  device_id: "dev-cloud",
  name: "cloud-vm",
  status: "connected",
  allows_operations: true,
  device_runtimes: [],
};

it("chooses where Tasks run, and shows a held computer the list no longer has", async () => {
  const t = await openModels({
    profiles: [],
    taskPlace: { kind: "station", device_id: "dev-gone" },
    computers: { devices: [studio], cloud: cloudVm },
  });
  // The place the core holds shows, by its id when the list lacks the computer.
  expect(row("task-place")).toHaveTextContent(
    "Tasks run here unless the Router names another place."
  );
  expect(placePicker()).toHaveTextContent("dev-gone");

  // Comma's cloud, the Cloud VM, and each computer by its name.
  await t.user.click(placePicker());
  for (const name of ["Comma (in the cloud)", "Cloud VM", "Studio Mac", "dev-gone"])
    expect(placeOptions().getByRole("option", { name })).toBeInTheDocument();
  await t.user.click(placeOptions().getByRole("option", { name: "Studio Mac" }));
  expect(t.called("models.setTaskPlace")).toEqual([
    { workspace, place: { kind: "station", device_id: "dev-studio" } },
  ]);
  expect(placePicker()).toHaveTextContent("Studio Mac");

  await t.user.click(placePicker());
  await t.user.click(placeOptions().getByRole("option", { name: "Cloud VM" }));
  expect(t.called("models.setTaskPlace").at(-1)).toEqual({
    workspace,
    place: { kind: "cloud_vm" },
  });
  // The Task model stays as it was.
  expect(t.called("models.setTaskModel")).toEqual([]);
});

it("offers the Cloud VM only when the workspace has one, and says why a place is refused", async () => {
  const t = await openModels(
    { profiles: [], computers: { devices: [studio], cloud: null } },
    {
      "models.setTaskPlace": () => {
        throw Object.assign(new Error("not_found"), { code: "not_found", status: 404 });
      },
    }
  );
  expect(placePicker()).toHaveTextContent("Comma (in the cloud)");
  await t.user.click(placePicker());
  expect(placeOptions().queryByRole("option", { name: "Cloud VM" })).toBeNull();
  await t.user.click(placeOptions().getByRole("option", { name: "Studio Mac" }));
  expect(
    await within(row("task-place")).findByText(
      "This computer is no longer in this workspace. Choose another place."
    )
  ).toBeInTheDocument();
  // The core keeps the place it holds.
  expect(placePicker()).toHaveTextContent("Comma (in the cloud)");
});

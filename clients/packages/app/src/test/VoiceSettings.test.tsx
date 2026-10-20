import type { VoiceIntegration, VoiceKey, VoiceValue } from "@comma/core/contract";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { render, screen, waitFor, within } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { beforeEach, expect, it } from "vitest";
import { useVoiceSettingsCategory } from "../components/voice/useVoiceSettingsCategory";
import { SettingsCategory } from "./settingsHarness";

// Settings › System › Voice over a scripted core: a caller number is listed
// only once its SMS code checks out, its PIN is write-only, and a voice agent
// API key's plaintext is shown once, right after creation. The requests the
// core makes for each call are tested in packages/core/test/voice.test.ts.

const workspace = "wsp_voice";
const line = "+15550001111";
const caller = "+15551234567";
const secret = "salix_vk_e2eSecretValueThatIsShownOnce";
const readinessUrl = "https://salix.example.test/v1/agent-groups/grp_voice/voice";
const sessionsUrl = "wss://salix.example.test/v1/agent-groups/grp_voice/voice/sessions";

type CallerNumber = VoiceIntegration["numbers"][number];
const verified = (pin_set = false): CallerNumber => ({
  e164: caller,
  line,
  carrier: "twilio",
  pin_set,
  pin_locked_until: null,
  verified_at: 1_700_000_000_000,
  status: "verified",
});
const frontDesk: VoiceKey = {
  key_id: "gak_voice",
  name: "Front desk",
  prefix: secret.slice(0, 15),
  status: "active",
  created_at: 1_700_000_000,
  sessions_url: sessionsUrl,
  readiness_url: readinessUrl,
};

/**
 * Settings › Voice over a core holding `numbers` and `keys`. Each call is
 * noted; a code other than 246810 is refused as the server refuses it.
 */
async function openVoice(state: { numbers: CallerNumber[]; keys: VoiceKey[] }) {
  const calls: [string, Record<string, unknown>][] = [];
  const core = createScriptedCore({
    values: (topic): VoiceValue | undefined =>
      topic.topic === "voice"
        ? {
            workspace,
            integration: {
              lines: [line],
              numbers: state.numbers,
              readiness: { ready: true, reason: null },
              sessions_url: sessionsUrl,
              readiness_url: readinessUrl,
            },
            keys: state.keys,
            integrationError: false,
            keysError: false,
          }
        : undefined,
    calls: (name, raw) => {
      const params = raw as Record<string, unknown>;
      calls.push([name, params]);
      const answered = answer(name, params);
      core.changed("voice");
      return answered;
    },
  });
  const answer = (name: string, params: Record<string, unknown>) => {
    switch (name) {
      case "voice.checkCode":
        if (params.code !== "246810")
          throw Object.assign(new Error("invalid_code"), {
            code: "invalid_code",
            status: 422,
          });
        state.numbers = [verified()];
        return null;
      case "voice.setPin":
        state.numbers = [verified(params.pin !== "")];
        return null;
      case "voice.createKey":
        state.keys = [{ ...frontDesk, name: params.name as string }];
        return { ...state.keys[0], key: secret, sessions_url: sessionsUrl };
      case "voice.updateKey":
        state.keys = state.keys.map((key) =>
          key.key_id === params.key ? { ...key, ...(params as Partial<VoiceKey>) } : key
        );
        return null;
      case "voice.deleteKey":
        state.keys = state.keys.filter((key) => key.key_id !== params.key);
        return null;
      default:
        return null;
    }
  };
  const user = userEvent.setup();
  render(core.wrap(<VoicePage />));
  await waitFor(() =>
    expect(setting("voice.readiness.status")).toHaveTextContent("Ready")
  );
  return {
    user,
    /** The params of each call to `name`, in order. */
    called: (name: string) => calls.filter(([n]) => n === name).map(([, p]) => p),
  };
}

function VoicePage() {
  return <SettingsCategory category={useVoiceSettingsCategory(true)} />;
}

const setting = (id: string) =>
  document.querySelector<HTMLElement>(`[data-setting-id="${id}"]`);
const numberRow = () => setting(`voice.number.${caller}.${line}`)!;
const keyRow = () => setting("voice.key.gak_voice")!;

beforeEach(() => {
  installNativeBridgeMock({ platform: "web" });
});

it("lists a caller number only once its SMS code checks out", async () => {
  const t = await openVoice({ numbers: [], keys: [] });
  const lineRow = setting(`voice.line.${line}`)!;
  expect(lineRow).toHaveTextContent(`Call ${line}`);
  await t.user.click(within(lineRow).getByRole("button", { name: "Add number" }));
  const add = within(await screen.findByRole("dialog", { name: "Add a phone number" }));
  expect(add.getByRole("button", { name: "Send code" })).toBeDisabled();
  await t.user.click(add.getByRole("textbox", { name: "Phone number" }));
  await t.user.paste(caller);
  await t.user.click(add.getByRole("button", { name: "Send code" }));

  const code = within(await screen.findByRole("dialog", { name: "Enter the code" }));
  const field = () => code.getByRole("textbox", { name: "Code" });
  await t.user.click(field());
  await t.user.paste("111111");
  await t.user.click(code.getByRole("button", { name: "Verify" }));
  expect(
    await code.findByText(/The code is not correct or has expired\./)
  ).toBeInTheDocument();
  expect(numberRow()).toBeNull();
  await t.user.clear(field());
  await t.user.paste("246810");
  await t.user.click(code.getByRole("button", { name: "Verify" }));
  await waitFor(() =>
    expect(screen.queryByRole("dialog", { name: "Enter the code" })).toBeNull()
  );
  expect(numberRow()).toHaveTextContent("Verified");
  expect(numberRow()).toHaveTextContent("No PIN");
  expect(t.called("voice.startVerification")).toEqual([
    { workspace, e164: caller, line },
  ]);
  expect(t.called("voice.checkCode")).toEqual([
    { workspace, e164: caller, code: "111111", line },
    { workspace, e164: caller, code: "246810", line },
  ]);
});

it("sets a caller's PIN, and shows only that one is set", async () => {
  const t = await openVoice({ numbers: [verified()], keys: [] });
  await t.user.click(
    within(numberRow()).getByRole("button", { name: "Number actions" })
  );
  await t.user.click(await screen.findByRole("menuitem", { name: "Set PIN" }));
  const pin = await screen.findByRole("dialog", { name: "Caller PIN" });
  await t.user.click(pin.querySelector("input")!);
  await t.user.paste("2468");
  await t.user.click(within(pin).getByRole("button", { name: "Save PIN" }));
  await waitFor(() =>
    expect(screen.queryByRole("dialog", { name: "Caller PIN" })).toBeNull()
  );
  expect(numberRow()).toHaveTextContent("PIN set");
  expect(numberRow()).not.toHaveTextContent("2468");
  expect(t.called("voice.setPin")).toEqual([{ workspace, e164: caller, pin: "2468" }]);
});

it("shows a new voice key's plaintext and a comma-voice command once", async () => {
  const t = await openVoice({ numbers: [], keys: [] });
  await t.user.click(screen.getByRole("button", { name: "New voice key" }));
  const create = within(await screen.findByRole("dialog", { name: "New voice key" }));
  await t.user.click(create.getByRole("textbox", { name: "Name" }));
  await t.user.paste("Front desk");
  await t.user.click(create.getByRole("button", { name: "Create key" }));
  const created = await screen.findByTestId("voice-key-created");
  expect(screen.getByTestId("voice-key-secret")).toHaveTextContent(secret);
  const example = screen.getByTestId("voice-key-example");
  expect(example).toHaveTextContent(
    "export COMMA_VOICE_SERVER='https://salix.example.test'"
  );
  expect(example).toHaveTextContent("export COMMA_VOICE_GROUP='grp_voice'");
  // The key goes to an owner-only file and reaches the CLI by --key-file,
  // never through the environment.
  expect(example).toHaveTextContent(
    `(umask 077; printf '%s' '${secret}' > ~/.comma-voice-key)`
  );
  expect(example).toHaveTextContent(
    "comma-voice check --key-file ~/.comma-voice-key && comma-voice call --key-file ~/.comma-voice-key"
  );
  expect(example).not.toHaveTextContent("COMMA_VOICE_API_KEY");
  expect(t.called("voice.createKey")).toEqual([{ workspace, name: "Front desk" }]);

  await t.user.click(within(created).getByRole("button", { name: "Done" }));
  expect(screen.queryByTestId("voice-key-created")).toBeNull();
  expect(screen.queryByText(secret)).toBeNull();
  expect(keyRow()).toHaveTextContent("Front desk");
  expect(keyRow()).toHaveTextContent("Active");
});

it("disables a voice key, then deletes it once confirmed", async () => {
  const t = await openVoice({ numbers: [], keys: [frontDesk] });
  await t.user.click(within(keyRow()).getByRole("button", { name: "Key actions" }));
  await t.user.click(await screen.findByRole("menuitem", { name: "Disable key" }));
  await waitFor(() => expect(keyRow()).toHaveTextContent("Disabled"));
  expect(t.called("voice.updateKey")).toEqual([
    { workspace, key: "gak_voice", status: "disabled" },
  ]);

  await t.user.click(within(keyRow()).getByRole("button", { name: "Key actions" }));
  await t.user.click(await screen.findByRole("menuitem", { name: "Delete key" }));
  await t.user.click(
    within(
      await screen.findByRole("dialog", { name: "Delete this voice agent API key?" })
    ).getByRole("button", { name: "Delete key" })
  );
  await waitFor(() => expect(setting("voice.key.gak_voice")).toBeNull());
  expect(t.called("voice.deleteKey")).toEqual([{ workspace, key: "gak_voice" }]);
});

// adb_devices (the Rust station's adb.rs): the Android phones people shared with this station's agents. The phones are the
// station process's (its adb tunnels over the mesh, not ported yet): it gives them here as `phones`; until it does,
// there are none, as with the Rust station before it registered its lister.
import type { Tool } from "./mcp.ts";

type Json = any;

export const ADB_DEVICES = {
  name: "adb_devices",
  description:
    "The Android phones people shared with this station's agents (from the still.fail app), each with the adb serial it is reached at on this machine (127.0.0.1:<port>), its model, owner and whether adb is connected; and the link that opens this station's 共享调试 page in a person's app, to ask them for theirs.",
  inputSchema: {
    "type": "object",
    "properties": {},
    "additionalProperties": false
  },
};

/// What the agent is told: the phones, how to use them, and how to ask for one (`page`: this station's 共享调试 page).
export function listed(phones: Json[], page: string | null): string {
  const ask =
    page !== null
      ? `To ask a person for their phone (or to pair it), send them this link in the conversation: ${page} — it opens this station's 共享调试 page in their still.fail Android app, where they tap 开始共享.`
      : "A person shares their phone from the still.fail Android app: this station's page, 共享调试.";
  if (phones.length === 0) return `No phone is shared with this station now. ${ask}`;
  let text = `${JSON.stringify(phones, null, 2)}\n\n`;
  text +=
    'Use a phone with `adb -s <serial> …` (adb is this machine\'s). adb "connected" is ready; "unpaired" means its person still has to pair it in the app (Wireless debugging › 使用配对码配对设备); after `adb kill-server` run `adb connect <serial>` again. A phone is its owner\'s: use it for what they asked, and it goes when they stop sharing it. ';
  text += ask;
  return text;
}

/// `phones`: the phones offered now (`{serial, device, android, owner: {name, email}, adb, message}` each); `page`: where
/// a person opens this station's 共享调试, once the station is in a workspace.
export function adbTools(phones: () => Json[], page: () => string | null): Tool[] {
  return [{ ...ADB_DEVICES, run: async () => listed(phones(), page()) }];
}

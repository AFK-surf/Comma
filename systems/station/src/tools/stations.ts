// The workspace's other stations, for agents (the Rust station's remote.rs `tools`): station_list, station_job,
// station_file. Their definitions are the Rust station's, but for remote tasks now being jobs; what they do is the station transport's
// (remote.rs, ported in src/jobs/), reached through the hub's `Remote`. Their answer is its JSON, pretty-printed.
import type { Remote } from "../sessions/neighbours.ts";
import type { Tool } from "./mcp.ts";

export const STATION_LIST = {
  name: "station_list",
  description:
    "List stations in this workspace. With station, ask its OS, architecture and whether it accepts jobs from here. Old stations may not support peer calls.",
  inputSchema: {
    "type": "object",
    "properties": {
      "station": {
        "type": "string"
      }
    },
    "additionalProperties": false
  },
};

export const STATION_JOB = {
  name: "station_job",
  description:
    "Run a shell job on a trusted workspace station. All jobs of this session run in one persistent directory there (shared, so a later job can build in what an earlier one cloned); keep checkouts and build output inside it, not elsewhere on that machine. It is removed, with anything still running, when this chat is archived or deleted, or after 14 days unused. action prepare records command/name with a caller-chosen stable key; upload inputs with station_file; action start executes it once. Reuse the same key after uncertain replies; use a new key for new work. get/log/stop address the same job. Completion and job notices return here, including after reconnect/restart. Commands run as the remote station OS user, not in a sandbox. A lost process is marked failed with unknown exit, never automatically re-executed.",
  inputSchema: {
    "type": "object",
    "properties": {
      "station": {
        "type": "string"
      },
      "key": {
        "type": "string"
      },
      "action": {
        "enum": [
          "prepare",
          "start",
          "get",
          "log",
          "stop",
          "list"
        ]
      },
      "command": {
        "type": "string"
      },
      "name": {
        "type": "string"
      },
      "lines": {
        "type": "integer"
      }
    },
    "required": [
      "station",
      "action"
    ],
    "additionalProperties": false
  },
};

export const STATION_FILE = {
  name: "station_file",
  description:
    "Upload an input before starting a remote job, or download a job artifact to this session. path is relative to this session's directory on that station; local is a path in this session workspace. Files are transferred in chunks, up to 1 GiB each; repeat upload after a disconnect. direction is upload/download. Downloads never overwrite an existing local file. Post downloaded artifacts using chat_post files.",
  inputSchema: {
    "type": "object",
    "properties": {
      "station": {
        "type": "string"
      },
      "key": {
        "type": "string"
      },
      "direction": {
        "enum": [
          "upload",
          "download"
        ]
      },
      "path": {
        "type": "string"
      },
      "local": {
        "type": "string"
      }
    },
    "required": [
      "station",
      "key",
      "direction",
      "path",
      "local"
    ],
    "additionalProperties": false
  },
};

/// The tools, on `remote` (a function: the transport is made after the tools, and may be none yet).
export function stationTools(remote: () => Remote | null): Tool[] {
  return [STATION_LIST, STATION_JOB, STATION_FILE].map((definition) => ({
    ...definition,
    run: async (session: string, args: Record<string, any>) => {
      const r = remote();
      if (!r) throw new Error("other stations cannot be reached from this one yet");
      return JSON.stringify(await r.tool(definition.name as "station_list" | "station_job" | "station_file", session, args), null, 2);
    },
  }));
}

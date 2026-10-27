// This Mac's station, asked about its agents' accounts over its local admin interface (RFC43 §3.3): HTTP on the
// address the station writes in `<station data>/run/local-admin.address` (its Unix socket, `run/local-admin.sock`, on
// macOS; a named pipe on Windows), with the token it keeps in `<station data>/local-admin.token`. Both are read for
// each request, so a station that started again is found. The token stays in Main: it is never returned, logged or
// put in an error.
//
// Bounds: one request per call, at most `timeoutMs` (a station that does not answer fails fast with a retryable
// error, it is not waited for), and at most `MAX_ANSWER_BYTES` of answer. A model server's address given is checked by
// the station before it answers (its model list, read within 15 s): that call waits `LOCAL_STATION_CHECK_TIMEOUT_MS`.
import { request } from "node:http";
import { readFile } from "node:fs/promises";
import { createConnection } from "node:net";
import { join } from "node:path";
import type { Duplex } from "node:stream";
import {
  localStationAccountsSchema,
  type LocalStationAccounts,
  type LocalStationAccountTarget,
  type LocalStationSetAccountSourceInput,
} from "@comma/native-bridge";
import { realMainClock, type MainClock } from "../../clock";
import { NativeOperationError } from "../ipc/operation-error";

export const LOCAL_STATION_TIMEOUT_MS = 3_000;
export const LOCAL_STATION_CHECK_TIMEOUT_MS = 20_000;
const MAX_ANSWER_BYTES = 256 * 1024;

export interface LocalStationProvider {
  accounts(input: void): Promise<LocalStationAccounts>;
  setAccountSource(
    input: LocalStationSetAccountSourceInput
  ): Promise<LocalStationAccounts>;
  signIn(input: LocalStationAccountTarget): Promise<LocalStationAccounts>;
  stopSignIn(input: LocalStationAccountTarget): Promise<LocalStationAccounts>;
}

export interface LocalStationAdminOptions {
  /** The station's data directory (`LocalStation.data`). Absent: there is no station, and every call fails. */
  data: string | undefined;
  timeoutMs?: number;
  /** For a call that has the station check a model server first. */
  checkTimeoutMs?: number;
  /** Main's clock for the answer deadline; a test gives its own. */
  clock?: MainClock | undefined;
  /** Opens the listen address (a socket or pipe path); a test gives an in-memory stream. */
  connect?: (address: string) => Duplex;
}

const unavailable = () =>
  new NativeOperationError(
    "The station on this computer did not answer.",
    "LOCAL_STATION_UNAVAILABLE"
  );

export class LocalStationAdmin implements LocalStationProvider {
  readonly #data: string | undefined;
  readonly #timeoutMs: number;
  readonly #checkTimeoutMs: number;
  readonly #clock: MainClock;
  readonly #connect: (address: string) => Duplex;

  constructor(options: LocalStationAdminOptions) {
    this.#data = options.data;
    this.#timeoutMs = options.timeoutMs ?? LOCAL_STATION_TIMEOUT_MS;
    this.#checkTimeoutMs = options.checkTimeoutMs ?? LOCAL_STATION_CHECK_TIMEOUT_MS;
    this.#clock = options.clock ?? realMainClock;
    this.#connect = options.connect ?? ((address) => createConnection(address));
  }

  accounts(): Promise<LocalStationAccounts> {
    return this.#ask("GET", "/local/accounts");
  }

  setAccountSource(
    input: LocalStationSetAccountSourceInput
  ): Promise<LocalStationAccounts> {
    if (input.endpoint === undefined)
      return this.#ask("PUT", accountPath(input), { source: input.source });
    return this.#ask(
      "PUT",
      accountPath(input),
      {
        source: input.source,
        endpoint: input.endpoint,
        ...(input.key === undefined ? {} : { key: input.key }),
      },
      this.#checkTimeoutMs
    );
  }

  signIn(input: LocalStationAccountTarget): Promise<LocalStationAccounts> {
    return this.#ask("POST", `${accountPath(input)}/sign-in`);
  }

  stopSignIn(input: LocalStationAccountTarget): Promise<LocalStationAccounts> {
    return this.#ask("DELETE", `${accountPath(input)}/sign-in`);
  }

  async #ask(
    method: string,
    path: string,
    body?: unknown,
    timeoutMs = this.#timeoutMs
  ): Promise<LocalStationAccounts> {
    const data = this.#data;
    if (!data) throw unavailable();
    let token: string;
    let address: string;
    try {
      [token, address] = (
        await Promise.all([
          readFile(join(data, "local-admin.token"), "utf8"),
          readFile(join(data, "run", "local-admin.address"), "utf8"),
        ])
      ).map((text) => text.trim()) as [string, string];
    } catch {
      // The station has not started yet, or this app carries none.
      throw unavailable();
    }
    if (!token || !address) throw unavailable();
    const answer = await this.#send(address, {
      method,
      path,
      token,
      payload: body === undefined ? undefined : JSON.stringify(body),
      timeoutMs,
    });
    if (answer.status === 409)
      throw new NativeOperationError(
        "The station did not allow this change now.",
        "LOCAL_STATION_CONFLICT"
      );
    // 401: the station is not ready yet, or started again with a new token that the next read takes. 404
    // (unknown_workspace) and 400 are not answers to show either; the view read again says what the station holds.
    if (answer.status !== 200) throw unavailable();
    let parsed: unknown;
    try {
      parsed = JSON.parse(answer.body);
    } catch {
      throw unavailable();
    }
    const view = localStationAccountsSchema.safeParse(parsed);
    if (!view.success) throw unavailable();
    // The machine's own login is shown only while its source is `local` (RFC43 §3.3).
    for (const workspace of view.data.workspaces)
      for (const runtime of [workspace.runtimes.codex, workspace.runtimes.claude])
        if (runtime.source !== "local") runtime.local = null;
    return view.data;
  }

  #send(
    address: string,
    {
      method,
      path,
      token,
      payload,
      timeoutMs,
    }: {
      method: string;
      path: string;
      token: string;
      payload: string | undefined;
      timeoutMs: number;
    }
  ): Promise<{ status: number; body: string }> {
    return new Promise((resolve, reject) => {
      let settled = false;
      let cancelDeadline: (() => void) | undefined;
      const fail = () => {
        if (settled) return;
        settled = true;
        cancelDeadline?.();
        reject(unavailable());
      };
      const req = request(
        {
          createConnection: () => this.#connect(address),
          method,
          path,
          headers: {
            accept: "application/json",
            authorization: `Bearer ${token}`,
            ...(payload === undefined
              ? {}
              : {
                  "content-type": "application/json",
                  "content-length": Buffer.byteLength(payload),
                }),
          },
        },
        (res) => {
          const chunks: Buffer[] = [];
          let size = 0;
          res.on("data", (chunk: Buffer) => {
            size += chunk.length;
            if (size > MAX_ANSWER_BYTES) {
              req.destroy();
              fail();
              return;
            }
            chunks.push(chunk);
          });
          res.on("end", () => {
            if (settled) return;
            settled = true;
            cancelDeadline?.();
            resolve({
              status: res.statusCode ?? 0,
              body: Buffer.concat(chunks).toString("utf8"),
            });
          });
          res.on("error", fail);
        }
      );
      // One deadline for connecting, sending and the whole answer.
      cancelDeadline = this.#clock.setTimer(timeoutMs, () => {
        req.destroy();
        fail();
      });
      req.on("error", fail);
      req.end(payload);
    });
  }
}

function accountPath({ workspaceId, runtime }: LocalStationAccountTarget) {
  return `/local/accounts/${encodeURIComponent(workspaceId)}/${runtime}`;
}

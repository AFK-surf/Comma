// A reader: answers the admin API's reads off the main thread, on a read-only connection of its own (WAL lets readers
// and the one writer go on together). What it answers is text, ready to send: no copying the value across threads.
import { parentPort, workerData } from "node:worker_threads";
import type { Lang } from "../ops/i18n.ts";
import { ops } from "./ops.ts";
import { openStore } from "./store.ts";
import { HttpError, setSpoken } from "./views.ts";

export type Ask = { id: number; op: string; args: any; lang: Lang; names: [string, string][]; processes: [string, string][]; clientKeys: [string, string][] };
export type Answer = { id: number; text?: string; status?: number; error?: string };

const store = openStore(workerData.data as string);

parentPort!.on("message", (ask: Ask) => {
  let answer: Answer;
  try {
    setSpoken(ask.lang);
    store.names = new Map(ask.names);
    store.processes = new Map(ask.processes);
    store.clientKeys = new Map(ask.clientKeys);
    const op = ops[ask.op];
    if (!op) throw new HttpError(500, `no read ${ask.op}`);
    answer = { id: ask.id, text: JSON.stringify(op(store, ask.args)) };
  } catch (error) {
    answer = { id: ask.id, status: error instanceof HttpError ? error.status : 500, error: (error as Error).message };
  }
  parentPort!.postMessage(answer);
});

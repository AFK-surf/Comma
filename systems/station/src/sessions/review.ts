// After an agent ends a turn all_done (or final), whether the chat has nothing left to do (the Rust station's hub.rs
// `suggest_archive`). As main has it since migration note 21: all_done is not reviewed before it is posted or recorded;
// the review runs on its own afterwards, asked of the decision model with the latest messages that fit, newest first.
// A chat it finds finished is recommended for the archive (until anyone says anything in it again); one it finds
// unfinished, or cannot tell, is not. It never holds an agent back.
import { Effect } from "effect";
import type { MessageRow } from "../store/store.ts";
import { type ArchivePolicy, archiveMass, currentPolicy, policyQuestion, recommends } from "./archive-policy.ts";
import { type Capability, type ChoiceResult, decide, type DecisionConfig, resolvedModel } from "./decision.ts";
import type { Hub } from "./hub.ts";
import { usable } from "./pool.ts";

type Json = any;

/// The decision reads the latest messages of a chat that fit these: how many it is given, and how many bytes of them.
const ARCHIVE_REVIEW_MESSAGES = 400;
const ARCHIVE_REVIEW_BYTES = 80_000;

/// The archive policy in force.
export const policyOf = (hub: Hub): ArchivePolicy => currentPolicy(hub.store);

/// Which policy a check was made under: its number as saved (0 for the default).
export const policyStamp = (hub: Hub): number => hub.store.archivePolicy()?.change.id ?? 0;

/// Starts the review in the background (a fiber of the hub's).
export function suggestArchive(hub: Hub, key: string) {
  hub.fork(Effect.promise(() => review(hub, key).catch(() => {})));
}

/// The profiles whose verified model the rule names, in order: the ones a review may ask.
function candidatesOf(hub: Hub): [string, DecisionConfig][] {
  const rule = hub.config().automaticDecisions.completion;
  const candidates: [string, DecisionConfig][] = [];
  for (const profile of hub.config().profiles) {
    const health = hub.accounts.healthOf(profile.id);
    if (!usable(health)) continue;
    const capability = health.check?.decision as Capability | undefined;
    const config = capability ? resolvedModel(profile, capability, rule.model) : undefined;
    if (config) candidates.push([profile.id, config]);
  }
  return candidates;
}

/// The review itself; resolves once its result is recorded.
export async function review(hub: Hub, key: string): Promise<void> {
  const rule = hub.config().automaticDecisions.completion;
  if (!rule.enabled) return;
  const candidates = candidatesOf(hub);
  const record = (detail: Json) => {
    try {
      hub.store.recordDecision(key, detail);
    } catch {}
  };
  const policy = policyOf(hub);
  const policyAt = policyStamp(hub);
  // What the chats look like to their pages: the option picked, or why none was, for each thread as it stands.
  const verdict = (versions: [number, number][], v: Json) => {
    for (const [id, version] of versions) {
      try {
        hub.store.setArchiveVerdict(key, id, version, v);
      } catch {}
    }
  };
  const standing = (): [number, number][] => hub.store.sessionThreads(key).map((t) => [t.thread.id, hub.store.lastEntry(t.thread.id)]);
  if (candidates.length === 0) {
    const error = "配置的模型在现有 Profile 中暂不可用";
    record({ purpose: "archive", version: 3, model: rule.model ?? "", accepted: false, elapsedMs: 0, error });
    verdict(standing(), { error });
    return;
  }
  const started = hub.now();
  const versions: [number, number][] = [];
  let selected = 0;
  let reviewed: { ok: ChoiceResult } | { error: string };
  try {
    // The chat as it is now: each thread this agent closes, its latest messages while they fit.
    const conversations: Json[] = [];
    for (const thread of hub.store.sessionThreads(key)) {
      const id = thread.thread.id;
      const version = hub.store.lastEntry(id);
      const messages = hub.store.messagesBefore(id, null, ARCHIVE_REVIEW_MESSAGES + 1);
      const omitted = messages.length > ARCHIVE_REVIEW_MESSAGES;
      if (omitted) messages.shift();
      const shown = (m: MessageRow) => ({ authorKind: m.authorKind, author: m.author, text: m.text, ts: m.ts, hasAttachments: m.attachments.length > 0 });
      // Newest first, as many as fit; the ones that did not are older, and said so.
      const kept: Json[] = [];
      let size = 0;
      for (const m of [...messages].reverse()) {
        const view = shown(m);
        size += Buffer.byteLength(JSON.stringify(view));
        if (size > ARCHIVE_REVIEW_BYTES && kept.length > 0) break;
        kept.push(view);
      }
      const older = messages.length - kept.length;
      kept.reverse();
      const pending = hub.store.pendingCard(id);
      conversations.push({ thread: id, messages: kept, olderMessagesLeftOut: older > 0 || omitted, pendingCard: pending ? { ts: pending[0].ts, text: pending[0].text } : null });
      versions.push([id, version]);
    }
    if (conversations.length === 0) throw new Error("archive review has no conversation evidence");
    const state = { agent: key, conversations, attachmentContentsAvailable: false };
    let answer: { ok: ChoiceResult } | { error: string } = { error: "no decision profile available" };
    for (let i = 0; i < candidates.length; i++) {
      selected = i;
      try {
        answer = { ok: await decide(candidates[i]![1], policyQuestion(policy), state) };
        break;
      } catch (error) {
        answer = { error: (error as Error).message };
      }
    }
    reviewed = answer;
  } catch (error) {
    reviewed = { error: (error as Error).message };
  }
  const config = candidates[selected]![1];
  const accepted = "ok" in reviewed && recommends(reviewed.ok, policy, config.threshold);
  const picked = "ok" in reviewed ? policy.options.find((o) => o.id === reviewed.ok.selected) : undefined;
  // Said while the chat stood still: anything said since makes it a question for another review.
  const now = hub.config().automaticDecisions.completion;
  const unchanged = versions.every(([id, version]) => hub.store.lastEntry(id) === version) && now.enabled === rule.enabled && now.model === rule.model && policyStamp(hub) === policyAt;
  record({
    purpose: "archive",
    version: 3,
    policyAt,
    option: picked ? { id: picked.id, name: picked.name, archive: picked.archive } : null,
    archiveMass: "ok" in reviewed ? archiveMass(reviewed.ok, policy) : null,
    profile: candidates[selected]![0],
    provider: config.provider,
    model: config.model,
    threshold: config.threshold,
    elapsedMs: hub.now() - started,
    threads: versions,
    accepted: accepted && unchanged,
    result: "ok" in reviewed ? reviewed.ok : null,
    error: "error" in reviewed ? reviewed.error : null,
  });
  if (!unchanged) return;
  verdict(
    versions,
    picked ? { option: picked.id, name: picked.name, archive: picked.archive, recommended: accepted } : { error: "error" in reviewed ? reviewed.error : "没有判断结果" },
  );
  for (const [id, version] of versions) {
    try {
      if (accepted) hub.store.suggestArchive(key, id, version);
      else hub.store.clearArchiveSuggestion(key, id);
    } catch {}
  }
}

/// The done chats no decision has answered as they stand now: ended all_done before the rule was on (or under another
/// model or policy), or while the model could not be reached. Nothing running or waiting to be heard, and not archived.
export function undecided(hub: Hub): string[] {
  const { store } = hub;
  const stats = store.sessionStats(null);
  const policy = policyStamp(hub);
  const keys: string[] = [];
  for (const s of store.listSessions()) {
    if (s.archivedAt !== null || s.running) continue;
    const stat = stats.get(s.key);
    const last = stat?.lastTurn ?? null;
    if (!last || last.endedAt === null || last.ending !== "all_done" || (stat?.pending ?? 0) > 0) continue;
    const threads = store.sessionThreads(s.key).map((t) => t.thread.id);
    const decided = store.lastDecision(s.key);
    // Under another policy than now, it is asked again, the recommended ones too.
    const samePolicy = (decided?.policyAt ?? 0) === policy;
    if (threads.length === 0 || (samePolicy && threads.every((id) => store.archiveSuggested(id)))) continue;
    const seen = new Map<number, number>(Array.isArray(decided?.threads) ? decided.threads : []);
    if (decided?.result && decided.error == null && samePolicy && threads.every((id) => seen.get(id) === store.lastEntry(id))) continue;
    keys.push(s.key);
  }
  return keys;
}

/// Asked from the pages: the sweep started, and how many chats it has to look at (null when no model can be asked).
export function startReview(hub: Hub): number | null {
  if (candidatesOf(hub).length === 0) return null;
  const queued = undecided(hub).length;
  void reviewUndecided(hub).catch(() => {});
  return queued;
}

/// Per hub: the sweep going on, and whether it was asked for again meanwhile.
const sweeps = new WeakMap<Hub, { done: Promise<void>; again: boolean }>();

/// Reviews each undecided chat, one after another, in the background: when the rule is turned on or given another
/// model, and once after the station starts. Asked while one runs, it goes over them again after.
export function reviewUndecided(hub: Hub): Promise<void> {
  const running = sweeps.get(hub);
  if (running) {
    running.again = true;
    return running.done;
  }
  const sweep = { done: Promise.resolve(), again: false };
  sweep.done = (async () => {
    do {
      sweep.again = false;
      if (!hub.config().automaticDecisions.completion.enabled || candidatesOf(hub).length === 0) break;
      for (const key of undecided(hub)) {
        if (!hub.config().automaticDecisions.completion.enabled) break;
        await review(hub, key).catch(() => {});
      }
    } while (sweep.again);
  })().finally(() => sweeps.delete(hub));
  sweeps.set(hub, sweep);
  return sweep.done;
}

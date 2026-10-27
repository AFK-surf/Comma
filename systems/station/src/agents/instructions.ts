// What the agent is told about its situation, appended to the runtime's own system prompt, and how messages are put to
// it. A change to how agents work gets a note in migrations.ts too, for the sessions begun before it.
import type { MessageRow, PendingMessage, WidgetModel } from "../store/store.ts";

/// The connect and surface of the station's own chats.
const STILLFAIL_SURFACE = "ember";
const TASK_SURFACE = "task";

/// `project`: the directory the runtime runs in, for a session begun outside still.fail (in a terminal) and continued here.
export function sessionInstructions(workspace: string, project: string | null, repos_dir: string, memory_path: string): string {
  const projectLine = project === null ? "" : `- Project directory: ${project}. This session began outside still.fail (in a terminal on this machine) and goes on here: you run in that directory and keep working on it as before. The session workspace below is for scratch files only.\n`;
  return instructions(projectLine, workspace, repos_dir, memory_path);
}

const instructions = (project: string, workspace: string, repos_dir: string, memory_path: string) => `You work on this machine and answer messages from Slack threads and still.fail web chats.

Identity: still.fail (formerly ember) carries messages; it is not your name. A Slack message's \`you\` attribute gives your name in that connect only. Elsewhere you are your model and runtime; answer identity questions accordingly.

Messages:
- <message via="slack" connect="…" you="name (<@ID>)" thread="CHANNEL/THREAD_TS" from="…" ts="…">…</message> identifies the conversation and sender. One session can receive several threads: keep them separate and reply to the originating thread.
- via="web", thread="EMBER/…" is a still.fail chat; answer it like any other conversation. The optional client attribute identifies the app/version a reported problem is in.
- via="task", thread="TASK/…" is a Task you participate in on another station or Salix. Answer it with chat_post in Markdown. Salix Tasks, including Coding tasks, accept files. Other station hosts reject files. Task posts do not accept cards.
- Read context before acting: not every message addresses you. Other agents appear as bots with their local names. Build on their findings, leave or hand over work they own or are better placed to do, and mention them when you need something.
- via="ember" is a station notice, such as a job's progress or completion; it belongs to no conversation. Act on it and tell whoever requested the work when relevant.
- Incoming messages can move a command or subagent wait to the background. A result saying the user backgrounded it means the station did so; the work continues and reports back. Answer the new message, then continue.
- Post only when asked or when you have something to add. Acknowledgements and unrelated bot messages need no reply; end with chat_state instead.

Reply tools (MCP server \`stillfail\`; a running session from before the migration may still expose \`ember\` — use the tools available to you):
- Ordinary assistant output reaches nobody. Use chat_post with to=<the message's thread>; there is no default conversation. Call it directly, without looking it up: arguments are to, text, kind, need, done, about, card, files, title, as described below.
- text uses the destination's formatting. Omit kind for progress; otherwise use "all_done" with done, or "need_human" with need. chat_state records a state without posting; it also supports "waiting" with seconds and for.
- Give title (a few words naming the chat, including Slack chats) with your first post that ends a turn. Change it only when the topic changes.
- chat_history(to=…) reads a thread including your posts. For another chat's link (…/chats/<key>, …/o/<workspace>/<station>/<key>, or ?history=<key>&entry=<n>; on this station or another of the workspace), read chat_read(chat=<link>) for the conversation and session_history(chat=<link>) for the agent's work. chat_list finds chats by words.
- slack_api calls Slack as your bot, including reading, posting, reacting, editing/deleting your messages and opening DMs. It cannot write in another session's thread. Writing in a new thread makes it one of your conversations; replies come to you.
- session_send(to=<another chat's link or session key>, text) writes to another session's agent, on this station or another station of the workspace; it is posted in that chat for people to see. A message headed 来自/From <a chat's link> comes from such an agent: answer it with session_send to that link, not chat_post. Talk as long as the work needs; a person's decision stays theirs.

Files and presentation:
- files=[absolute local paths] attaches files with chat_post. In still.fail chats, ![](shot.png) places an attached image; [report](report.pdf) on its own line places a file, while a link within a sentence opens it. In still.fail chats and Salix Tasks, local absolute paths in Markdown links/images attach automatically. Correct missing paths or duplicate attachment names before posting; write example paths as code.
- Slack uploads files below the text; do not use Markdown image syntax there.
- Show visible results (UI, animation, pictures) with images, video, an inline page or a service. Use stillfail-show for choosing and making evidence, stillfail-viz for inline HTML diagrams/widgets, and stillfail-jobs for services and background work.

Decisions and cards:
- Set card.assignee to the email of the person who must decide, chosen from the conversation; never guess from their display name. Each card goes only to that person’s 奏 list. Other members can help by answering in its chat; doing so does not assign them future decisions. A card without an assignee goes to whoever started the chat. A still.fail chat ending need_human without a card also goes on its starter’s 奏 list, with the message it is about as the question.
- Ask for a decision only when a real unresolved choice is needed to continue; end need_human then. Advice or a factual answer alone does not require a follow-up question. Do not invent a decision to end a reply, or reopen decisions already made: carry out authorized work.
- The user always has a chat input box and can reply freely, with or without a card. Cards are optional shortcuts: use options only for concrete alternatives that help a real decision; do not add filler such as “Other”, “Type my own answer” or “Ask another question”. For a simple question or open-ended input, ask in the message and let the user type. Each option must be a complete answer on its own: tapping it tells you everything you need. Anything the user would have to word themselves (what to change, a name, a value, a different approach) is never an option; they type it. A card may have a single option, e.g. 合并 when asking to merge shown work. When a card helps, use card {"type":"options","options":[{"label":"…","detail":"…","recommended":true}]} for named choices: short self-contained labels, one-line consequences, recommend one when possible. Use {"type":"text","placeholder":"…"} for a value they must write.
- You may give an option action="close" (e.g. label="不需要部署") only when selecting it needs no further work: it ends need_human without a message or waking you. Other options default to action="reply". There is no fixed close button; you decide whether to offer one.
- When your question is resolved or obsolete, withdraw your own card with chat_post(to=..., withdraw=<its message ts>), with no other arguments. This keeps the post and does not mark the chat done; continue the work and end with the appropriate state.
- The question must stand alone with the facts needed to answer it. A reply quotes the card; ordinary chat text also answers it. A card is not a state: end need_human and say what decision/input is needed. Slack has no cards; put choices in the text.

End every turn with exactly one state:
- all_done: nothing in this chat remains unfinished — no unmerged branch, undeployed/unconfirmed change, unanswered question or result awaiting approval. done must name evidence and where the result landed (commit, release, user's confirmation, or factual answer given), e.g. 已合进 main 82f108a5，测试版 1389 已发，你确认过滑动可以. Bare 做完了 / done is rejected. This state marks the chat finished in people's lists.
- need_human: first state the outstanding question or request in a visible chat message; need is a status summary and does not ask the person anything. After answering a clarification, if a previous decision is still needed, say so explicitly in that reply. Use chat_post kind=need_human, or chat_state with about pointing to your question (a pending card is used by default). Waiting on a person to provide, do, decide, confirm or verify anything. need says what in one sentence; for verification, include where, how and what to check. Use a card only when it makes answering easier. If work is also running, mention it after the ask, e.g. 选统计口径；CI 还在跑. Waiting on a person is never waiting.
- waiting: only work you started that continues after the turn and will bring you back (a job, a background command or agent, a loop watching CI or a build), with nothing asked of anyone. Use chat_state with seconds (a fallback, see below) and for (a few words naming the work); if nothing returns by then you are asked again.
Before you end a turn waiting:
- Something must be watching the work and bring you back when it ends or fails: a background command or agent the harness reports on, or a job (with watch for a long run). CI or another remote run you only would look at later is not being watched: start a loop that polls it and exits on the first failure. Never wait on a guessed duration alone; the seconds are a fallback, not the way back. Only when the work truly cannot be watched, give seconds as the shortest it could take, not the longest.
- Waiting is for when nothing else is left. While the work runs, carry on with whatever does not depend on it (the next item, another part, a check you can do now); end the turn waiting only when all that is left needs the result.
A chat_post with kind already records the state; do not follow it with chat_state. Use chat_state when no post is needed or your last post lacked kind. Optional about is the ts to jump to: the result for all_done, question for need_human (defaults to the pending card), progress message for waiting. A turn without a state is sent back to you. Nothing reviews or holds back all_done: once it is recorded, the station may assess the chat in the background and recommend it for the archive when nothing is left in it, following its archive policy; that never blocks you, so end the turn truthfully. When someone says a recommendation is wrong, read the policy with archive_policy: change it if the policy causes it (an option counted the wrong way, a situation missing), or say the model misjudged if not.

Progress: post when people need news before completion — a changed plan, useful partial result, decision or blocker. Do not narrate routine steps. When work will run long, one post saying so and roughly how long is enough.

Formatting:
- Slack is mrkdwn, posted literally: *bold*, _italic_, ~strike~, \`code\`, triple-backtick blocks without a language, > quotes, <https://example.com|label>, <@USER_ID>, <#CHANNEL_ID>. Escape literal < > & as &lt; &gt; &amp;. Lists use • or 1., one level deep. No Markdown headings, tables, nested lists or inline images: use bold headings, short lists or aligned code blocks. **bold** and [label](url) do not convert.
- still.fail chats use standard Markdown: lists start with - or 1. and an item per line; a • and a single line break do not make a list, the lines run into one paragraph. Attached HTML placed with a file link renders inline; see stillfail-viz.

Where you work:
${project}- Session workspace: ${workspace}. Scratch files, clones and git worktrees belong here.
- Shared repository cache: ${repos_dir}. Keep canonical clones there; work in session worktrees, never edit canonical clones directly.

Memory and skills:
- Both runtimes share memory. Keep it short; no credentials or one-off task details.
- Global memory ${memory_path} loads at session start: lasting cross-project lessons only (teamwork, answering).
- Project lessons belong in skills/<project>/SKILL.md beside it; create one if absent. Start its description with "项目记忆：" and say when it applies. A project can be a product, customer or recurring duty, not just a repository.
- Use other shared skills there when their descriptions match the task.
- A skill can be shared with the workspace's other stations (people turn that on). One shared from another station shows there like the others; what you write to it reaches that station. A SKILL.conflict-<station>.md beside a SKILL.md is an edit made on an older copy: merge it into SKILL.md and remove it.`;

/// A coding Session's own instructions (tasks/coding.ts): its sandbox stops when it idles and may lose its files
/// then, so only what it committed and pushed outlives it.
export const codingInstructions = (owner: string, name: string, branch: string, pullRequest?: number) => `# Coding session

You work in a checkout of github.com/${owner}/${name} on the branch ${branch}, in a cloud sandbox of your own. The sandbox is temporary: it stops when it is idle, and its files may be lost then. Commit and push work that must survive it.
${pullRequest === undefined ? "" : `${branch} is the head branch of pull request #${pullRequest}: what you push to it updates that pull request. Do not open another pull request for this work.
`}These are default behaviors. Follow explicit user instructions when they differ, including requests to leave changes uncommitted, use another branch, or force-push.
- By default, commit your changes and push ${branch} before you end a turn in which you changed files.
- By default, push to ${branch} without force. When the user requests a force-push, prefer --force-with-lease to protect concurrent changes.
- If a push fails, report the error. If work remains uncommitted or unpushed, explain that it may be lost when the sandbox stops.`;

export const NUDGE = `Your turn ended without a state, so nobody knows where the chat stands. Only a real unresolved need requires need_human. A factual answer alone does not need a follow-up question; do not invent one. If you still need something after answering a clarification, visibly ask for it; need alone is only a status summary. Cards are optional. Do not reopen a decision the user already made. Decide whether anything in it is still unfinished, then end the turn with exactly one:
- all_done: nothing in the chat is left unfinished at all. Post the result with chat_post kind "all_done" (or chat_state "all_done" if you already posted it), with done: why nothing is left, naming the evidence (a commit, a release, a person's confirmation, the answer given).
- need_human: a person has to give, do, decide, confirm or verify something (a card you posted included), or answer a question you asked: kind "need_human" with need, what they have to give, do or decide (to verify: where, how and what to look at). If work you started is pending too, mention it after the ask in need.
- waiting: only work you started that will bring you back on its own (a background command or agent, a job, a loop watching CI), with nothing asked of anyone, and nothing else you can do meanwhile: chat_state "waiting" with seconds, your estimate of how long until it does, and for, what you wait for. Waiting on a person is need_human.
- Otherwise: continue the work.`;

export const RESUME_AFTER_RESTART = `The station restarted while you were in the middle of a turn, so that turn was cut off. Check where you were (files, git state, anything you started), then continue. Post only if people need to know.`;

export const GO_ON_AFTER_AUTH = `Your last turn stopped on an authentication error. The station reopened Claude to reload its credentials. Continue the unfinished work from this conversation. First check the transcript, files and any operations already started; do not repeat completed actions. If an action's outcome is uncertain, verify it before retrying. Post only if people need to know.`;

export const GO_ON_AFTER_SPENT = `Your last turn was cut off: the account it ran on hit its usage limit. You now run on another account (or model). Check where you were, then continue the work. Post only if people need to know.`;

export const RESUME_LOST = `Your earlier conversation could not be restored. Read the relevant threads with chat_history to catch up before answering.`;

/// It goes on in a new runtime session: the earlier one is not taken up; it reads back what it needs from it.
export const afresh = (key: string, threads: string[]) => `This is a new conversation: your earlier one in this session is no longer used. Before you act on what comes below, read back from it what you need: session_history with chat ${key} (the latest entries first; older ones with before)${threads.length === 0 ? "" : `, and chat_history for ${threads.join(", ")}`}.`;

/// The agent said it would wait this long, and nothing has brought it back.
export const waitOver = (seconds: number) => `You said you were waiting on work you started (${seconds} seconds), and nothing has brought you back yet. Check on it now.
- If it is done: pick up its results and carry on. If nothing was watching it (you would have been told when it ended), start a watch the next time instead of waiting on a guessed duration.
- If it is still running: make sure something will tell you when it ends or fails (a background command or agent, a job with watch, a loop polling CI that exits on the first failure), do whatever else you can meanwhile, and only then chat_state "waiting" again. If it truly cannot be watched, wait the shortest it could still take.
- If it has stopped or is stuck: say so in the thread, and fix or restart it if you can.`;

/// The first turn in still.fail of a session begun in a terminal: from now on it works as still.fail's sessions do.
export const continuedHere = (instructions: string) => `This session began in a terminal and now goes on in still.fail: what people say comes as messages below, and nothing you write as ordinary output reaches them any more; answer with the station's tools. How still.fail works, from now on:

<stillfail-instructions>
${instructions}
</stillfail-instructions>`;

/// A conversation address as the agent sees and names it.
export const threadAddress = (channel: string, threadTs: string) => `${channel}/${threadTs}`;

export function parseThreadAddress(value: string): [string, string] | null {
  const v = value.trim();
  const at = v.indexOf("/");
  if (at < 0) return null;
  const [channel, ts] = [v.slice(0, at), v.slice(at + 1)];
  const dot = ts.indexOf(".");
  if (dot < 0) return null;
  const [secs, micros] = [ts.slice(0, dot), ts.slice(dot + 1)];
  const ok = /^[A-Z0-9]+$/.test(channel) && /^[0-9]+$/.test(secs) && /^[0-9]+$/.test(micros);
  return ok ? [channel, ts] : null;
}

const escapeAttr = (value: string) => value.replaceAll("&", "&amp;").replaceAll('"', "&quot;");

/// A message's words as the agent reads them: quotes (which message, whose, the passage as a blockquote, then the
/// comment), then the words, then the files as paths.
export function messageForAgent(m: MessageRow): string {
  const parts = m.quotes.map((q) => {
    let whose: string;
    if (q.role === "agent") whose = "your own earlier message";
    else if (q.role === "page") {
      // A mark on a web service's page in a preview: its own screenshot (`file`), or the whole page's from clients before.
      const shot = q.file ? m.attachments.find((a) => a.name === q.file) : undefined;
      whose = shot
        ? `a web page shown in the chat's preview (${q.author}), marked with its number in its own screenshot ${shot.path}`
        : `a web page shown in the chat's preview (${q.author}), marked with its number in the attached screenshot`;
    } else if (q.role === "image") whose = `an image marked in the chat (${q.author}), its number pinned on the marked image attached`;
    else whose = `a message from ${q.author}`;
    const which = q.ts !== null && q.ts !== undefined ? `${whose} ${q.ts} in this conversation` : whose;
    const passage = q.text.split("\n").map((l) => `> ${l}`);
    const comment = q.comment === "" ? "" : `\nTheir comment on it: ${q.comment}`;
    return `[Quote] From ${which}:\n${passage.join("\n")}${comment}`;
  });
  parts.push(m.text);
  if (m.attachments.length > 0) parts.push(`Attached files:\n${m.attachments.map((a) => `- ${a.path} (${a.name}, ${a.size} bytes)`).join("\n")}`);
  return parts.filter((p) => p !== "").join("\n\n");
}

const via = (surface: string) => (surface === STILLFAIL_SURFACE ? "web" : surface === TASK_SURFACE ? "task" : "slack");

/// The still.fail app a message was sent from, as an attribute; nothing for one that did not say.
const clientAttr = (m: MessageRow) => (m.client !== null && m.client !== undefined ? ` client="${escapeAttr(m.client)}"` : "");

/// Messages handed to a session, each with its source and sender, and a hint where a thread is new to it.
export function formatInbound(messages: PendingMessage[], newThreads: Set<number>, names: Map<string, string>, selves: Map<string, string>): string {
  const lines: string[] = [];
  const hinted = new Set<number>();
  for (const p of messages) {
    const m = p.message;
    const address = threadAddress(p.channel, p.threadTs);
    // Something was said before it: earlier entries, or (Slack) a reply rather than the thread's first message.
    const before = m.n > 1 || (p.surface !== STILLFAIL_SURFACE && m.ts !== p.threadTs);
    if (newThreads.has(m.thread) && before && !hinted.has(m.thread)) {
      hinted.add(m.thread);
      lines.push(`(Thread ${address} had messages before you were brought in; read them with chat_history to="${address}" if they matter.)`);
    }
    const self = selves.get(p.connect);
    const you = self !== undefined ? ` you="${escapeAttr(self)}"` : "";
    const agent = m.authorKind === "agent";
    const name = names.get(m.author);
    const from = agent ? (name ?? "another agent") : name !== undefined ? `${name} (${m.author})` : m.author;
    lines.push(`<message via="${via(p.surface)}" connect="${escapeAttr(p.connect)}"${you} thread="${address}" from="${escapeAttr(from)}"${agent ? " bot" : ""}${clientAttr(m)} ts="${m.ts}">\n${messageForAgent(m)}\n</message>`);
  }
  return lines.join("\n");
}

/// What people chose in widgets the agent posted, riding along with messages it is handed anyway; empty when none.
export function formatWidgetModels(models: WidgetModel[]): string {
  if (models.length === 0) return "";
  const lines = models.map((w) => (w.thread ? `- ${w.name} in ${threadAddress(w.thread[0], w.thread[1])}: ${w.model}` : `- ${w.name}: ${w.model}`));
  return `A widget you posted has state for you (the person's choices in it; not a message to answer by itself):\n${lines.join("\n")}`;
}

/// A thread's messages for chat_history: people by name, this session's own posts as "you", other agents and the
/// station marked as bots.
export function formatHistory(messages: MessageRow[], surface: string, address: string, selfKey: string, names: Map<string, string>): string {
  return messages
    .map((m) => {
      const from = m.authorKind === "agent" && m.author === selfKey ? "you" : m.authorKind === "ember" ? "ember" : names.has(m.author) ? `${names.get(m.author)} (${m.author})` : m.author;
      const bot = m.authorKind !== "person" && from !== "you" ? " bot" : "";
      return `<message via="${via(surface)}" thread="${address}" from="${escapeAttr(from)}"${bot}${clientAttr(m)} ts="${m.ts}">\n${messageForAgent(m)}\n</message>`;
    })
    .join("\n");
}

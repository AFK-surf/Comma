import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";

let requestNumber = 0;
let visibleSendCount = 0;

const maxVisibleSends = 20;
const maxInlineTasksPerMessage = 16;
const taskListTool = "im_api.internal.task.list";
const streamedTextDeltaMaxCodePoints = 3;
const streamedTextDeltaIntervalMs = 40;
const sourceContextHeader = "Inbound message source:";

function asText(value) {
  if (typeof value === "string") return value;
  if (Array.isArray(value)) return value.map(asText).join("\n");
  if (value && typeof value === "object") {
    if (typeof value.text === "string") return value.text;
    if (typeof value.content === "string") return value.content;
    return JSON.stringify(value);
  }
  return "";
}

function parseJson(value) {
  if (value && typeof value === "object") return value;
  if (typeof value !== "string") return null;

  try {
    return JSON.parse(value);
  } catch {
    return null;
  }
}

function deepFind(value, predicate) {
  if (predicate(value)) return value;

  if (Array.isArray(value)) {
    for (const item of value) {
      const found = deepFind(item, predicate);
      if (found !== undefined) return found;
    }
  } else if (value && typeof value === "object") {
    for (const item of Object.values(value)) {
      const found = deepFind(item, predicate);
      if (found !== undefined) return found;
    }
  }

  return undefined;
}

function allIds(text, prefix) {
  const pattern = new RegExp(`${prefix}[A-Za-z0-9_-]+`, "g");
  return [...new Set(text.match(pattern) || [])];
}

export function conversationContext(text) {
  const ids = allIds(text, "cnv1_");
  const sourceConversationIds = [
    ...text.matchAll(/^\s*- conversation_id:\s*(cnv1_[A-Za-z0-9_-]+)\s*$/gm),
  ];

  return {
    ids,
    currentId:
      sourceConversationIds.length === 1
        ? sourceConversationIds[0]?.[1] || null
        : null,
  };
}

function sourceContextValue(text, key) {
  const matches = [
    ...text.matchAll(new RegExp(`^\\s*- ${key}:\\s*(.+?)\\s*$`, "gm")),
    ...text.matchAll(new RegExp(`^\\s*${key}=([^\\r\\n]+?)\\s*$`, "gm")),
  ];
  return matches.length === 1 ? matches[0]?.[1] || null : null;
}

// Chat Completions only accepts a system message at the beginning, so Salix
// carries later system-authored context (source context, runtime facts) on a
// `<system>`-wrapped user message. Returns that text for either shape, or null
// for a real conversation turn.
function systemAuthoredText(message) {
  if (!message) return null;

  const text = asText(message.content);
  if (message.role === "system") return text;
  if (message.role !== "user") return null;

  const trimmed = text.trim();
  if (!trimmed.startsWith("<system>\n") || !trimmed.endsWith("\n</system>")) {
    return null;
  }

  return trimmed.slice("<system>\n".length, -"\n</system>".length);
}

// A conversation turn from the user, as opposed to system-authored context
// riding on the user role. Turn boundaries below key off this.
function isUserTurn(message) {
  return message?.role === "user" && systemAuthoredText(message) === null;
}

function latestSourceContext(messages) {
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const authored = systemAuthoredText(messages[index]);
    if (authored === null) continue;

    const lines = authored.trimStart().split(/\r?\n/);
    const sourceHeaderIndex = lines.findLastIndex(
      (line) => line.trim() === sourceContextHeader,
    );
    if (sourceHeaderIndex < 0) continue;

    const contextLines = [];
    for (const line of lines.slice(sourceHeaderIndex)) {
      if (contextLines.length > 0 && line.trim() === "") break;
      contextLines.push(line);
    }

    return contextLines.join("\n");
  }

  return "";
}

function latestProviderContext(messages) {
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const text = asText(messages[index]?.content);
    const match = text.match(
      /^<system-reminder>\nIM provider message context\.\n([\s\S]*?)\n<\/system-reminder>(?:\n|$)/,
    );
    if (match) return match[1];
  }

  return "";
}

function previousToolCall(messages) {
  const lastUserIndex = messages.findLastIndex(isUserTurn);

  for (let index = messages.length - 1; index >= 0; index -= 1) {
    if (index < lastUserIndex) return null;
    const calls = messages[index]?.tool_calls;
    if (!Array.isArray(calls)) continue;
    const call = calls[0];
    const args = parseJson(call?.function?.arguments || call?.arguments);
    if (args?.tool) return args;
  }

  return null;
}

function toolResultsForTarget(messages, target) {
  const lastUserIndex = messages.findLastIndex(isUserTurn);
  const results = [];
  let activeTarget = null;

  for (let index = lastUserIndex + 1; index < messages.length; index += 1) {
    const message = messages[index];
    const calls = message?.tool_calls;

    if (Array.isArray(calls) && calls.length > 0) {
      const args = parseJson(
        calls[0]?.function?.arguments || calls[0]?.arguments,
      );
      activeTarget = args?.tool || null;
      continue;
    }

    if (message?.role === "tool" && activeTarget === target) {
      const result = parseJson(message.content);
      if (result) results.push(result);
    }
  }

  return results;
}

function toolRecordsForTarget(messages, target) {
  const lastUserIndex = messages.findLastIndex(isUserTurn);
  const records = [];
  let active = null;

  for (let index = lastUserIndex + 1; index < messages.length; index += 1) {
    const message = messages[index];
    const calls = message?.tool_calls;

    if (Array.isArray(calls) && calls.length > 0) {
      const args = parseJson(
        calls[0]?.function?.arguments || calls[0]?.arguments,
      );
      active = args?.tool === target ? { params: args.params || {} } : null;
      continue;
    }

    if (message?.role === "tool" && active) {
      const result = parseJson(message.content);
      if (result) records.push({ ...active, result });
      active = null;
    }
  }

  return records;
}

function latestToolResult(messages) {
  const lastUserIndex = messages.findLastIndex(isUserTurn);

  for (let index = messages.length - 1; index >= 0; index -= 1) {
    if (index < lastUserIndex) return null;
    if (messages[index]?.role === "tool")
      return parseJson(messages[index].content);
  }

  return null;
}

function latestAsyncToolResult(messages, target) {
  const lastUserIndex = messages.findLastIndex(isUserTurn);
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    if (index < lastUserIndex) return null;
    const content = systemAuthoredText(messages[index]);
    if (content === null) continue;
    if (!content.startsWith("<runtime-message>\n")) continue;
    if (!content.includes("\ntype: tool_call_completed\n")) continue;

    const encoded = content.match(
      /\ncontent: (?:\[src:[^\]]+\]\n)?(\{.*\})\nsource_refs: /s,
    )?.[1];
    const completion = parseJson(encoded);

    if (
      completion?.status === "completed" &&
      completion?.tool_name === target &&
      completion?.result?.status === "completed"
    ) {
      return completion.result;
    }
  }

  return null;
}

function findWorkerId(result) {
  const worker = deepFind(
    result,
    (value) =>
      value &&
      typeof value === "object" &&
      typeof value.agent_id === "string" &&
      (value.role === "worker" || /worker/i.test(value.name || "")),
  );
  if (worker?.agent_id) return worker.agent_id;

  const anyAgent = deepFind(
    result,
    (value) =>
      value && typeof value === "object" && typeof value.agent_id === "string",
  );
  return anyAgent?.agent_id || null;
}

function taskListRequest(text) {
  if (/LOCAL_LIST_TASKS/i.test(text)) return {};

  if (/(?:列出|查看|有哪些|搜索|查找).*(?:任务|tasks?)/iu.test(text)) {
    return {};
  }

  return null;
}

function isTaskListContinuationRequest(text) {
  return /^(?:继续|接着)(?:\s*(?:查看|查询|查找|搜索|列出|看)?\s*(?:一下)?\s*(?:任务|tasks?)?)?\s*(?:吧)?[。.!！?？]*$/iu.test(
    text.trim(),
  );
}

function establishesTaskListContinuation(params) {
  return /后面仍可能有更多结果/u.test(asText(params?.content));
}

function pendingTaskListContinuation(messages) {
  const currentUserIndex = messages.findLastIndex(isUserTurn);
  if (currentUserIndex <= 0) return null;

  let previousUserIndex = -1;
  for (let index = currentUserIndex - 1; index >= 0; index -= 1) {
    if (isUserTurn(messages[index])) {
      previousUserIndex = index;
      break;
    }
  }
  if (previousUserIndex < 0) return null;

  let activeCall = null;
  let latestListPage = null;
  let pending = null;

  for (
    let index = previousUserIndex + 1;
    index < currentUserIndex;
    index += 1
  ) {
    const message = messages[index];
    const calls = message?.tool_calls;

    if (Array.isArray(calls) && calls.length > 0) {
      activeCall = parseJson(
        calls[0]?.function?.arguments || calls[0]?.arguments,
      );

      if (activeCall?.tool === "im_api.internal.send_message") {
        const cursor = latestListPage?.next_cursor;
        pending =
          latestListPage?.has_more === true &&
          typeof cursor === "string" &&
          cursor.length > 0 &&
          establishesTaskListContinuation(activeCall.params)
            ? { cursor }
            : null;
      }
      continue;
    }

    if (message?.role === "tool" && activeCall?.tool === taskListTool) {
      latestListPage = parseJson(message.content);
    }
  }

  return pending;
}

function toolCall(tool, params) {
  return {
    kind: "tool",
    id: `local_call_${Date.now()}_${requestNumber}`,
    name: "call",
    args: { tool, params },
  };
}

function disclosedTool(body, name) {
  return (Array.isArray(body?.tools) ? body.tools : []).some(
    (tool) => tool?.function?.name === name || tool?.name === name,
  );
}

function settleTerminalText(body, decision) {
  if (
    decision.kind !== "text" ||
    decision.terminal === false ||
    !disclosedTool(body, "end_turn")
  ) {
    return decision;
  }

  const blocked = /^LOCAL_DEV_(?:ERROR|GUARD):/.test(decision.text);

  return {
    kind: "tool",
    id: `local_end_turn_${Date.now()}_${requestNumber}`,
    name: "end_turn",
    args: blocked
      ? {
          outcome: "blocked",
          reason:
            "The local deterministic LLM could not complete this scenario.",
        }
      : { outcome: "done" },
    text: decision.text,
  };
}

function recommendationRequest(text) {
  const collectedPrefix = "Run: ";
  const factsMarker = ". Server-collected facts: ";
  const failuresMarker = ". Source collection failures: ";
  const collectedStart = text.indexOf(collectedPrefix);
  const factsStart = text.indexOf(
    factsMarker,
    collectedStart + collectedPrefix.length,
  );
  const failuresStart = text.indexOf(
    failuresMarker,
    factsStart + factsMarker.length,
  );

  if (
    collectedStart >= 0 &&
    factsStart > collectedStart &&
    failuresStart > factsStart
  ) {
    const run = parseJson(
      text.slice(collectedStart + collectedPrefix.length, factsStart),
    );
    const facts = parseJson(
      text.slice(factsStart + factsMarker.length, failuresStart),
    );

    if (run && Array.isArray(facts) && facts.length > 0) {
      return {
        runId: run.id,
        generation: Number(run.generation),
        sourceRevision: Number(run.sourceRevision),
        collectedFacts: facts,
        sources: facts.map((fact) => ({
          appName: fact.appName,
          connectionId: fact.sourceId,
          kind: "composio",
          label: fact.appName,
          toolkit: fact.toolkit || fact.appId,
        })),
      };
    }
  }

  const match = text.match(
    /Run id:\s*([^\.\s]+)\. Generation:\s*(\d+)\. Source revision:\s*(\d+)\. Enabled sources:\s*(\[.*\])\. Read only/s,
  );
  if (!match) return null;

  const sources = parseJson(match[4]);
  if (!Array.isArray(sources) || sources.length === 0) return null;

  return {
    runId: match[1],
    generation: Number(match[2]),
    sourceRevision: Number(match[3]),
    sources,
  };
}

function scheduledRecommendationRequest(target, result) {
  if (target !== "recommendation.begin") return null;

  const payload = decodedToolContent(result) || result;
  const run = payload?.run;
  const facts = payload?.facts;
  if (!run || !Array.isArray(facts) || facts.length === 0) return null;

  return {
    runId: run.id,
    generation: Number(run.generation),
    sourceRevision: Number(run.sourceRevision),
    collectedFacts: facts,
    sources: facts.map((fact) => ({
      appName: fact.appName,
      connectionId: fact.sourceId,
      kind: "composio",
      label: fact.appName,
      toolkit: fact.toolkit || fact.appId,
    })),
  };
}

function callableTargetTools(body) {
  const names = new Set();

  for (const tool of body.tools || []) {
    const values = tool?.function?.parameters?.properties?.tool?.enum;
    if (!Array.isArray(values)) continue;
    for (const value of values) {
      if (typeof value === "string") names.add(value);
    }
  }

  return names;
}

function recommendationSources(request, callableTools) {
  const candidates = request.sources.filter(
    (source) =>
      typeof source?.connectionId === "string" &&
      source.connectionId.length > 0 &&
      ((source?.kind === "composio" &&
        typeof source?.toolkit === "string" &&
        source.toolkit.length > 0) ||
        (typeof source?.bindingAlias === "string" &&
          source.bindingAlias.length > 0)),
  );

  if (callableTools.size === 0 || request.collectedFacts) return candidates;

  return candidates.filter((source) =>
    source.kind === "composio"
      ? callableTools.has("composio.list_tools") &&
        callableTools.has("composio.get_tool") &&
        callableTools.has("composio.execute")
      : callableTools.has(`mcp.${source.bindingAlias}.comma_local_search`),
  );
}

function recommendationSourceResult(messages, sourceTool) {
  const asynchronous = latestAsyncToolResult(messages, sourceTool);
  if (asynchronous) return asynchronous;

  return toolResultsForTarget(messages, sourceTool).findLast(
    (result) => result?.status === "completed",
  );
}

function recommendationItems(result, source) {
  const content = result?.content;
  const decoded =
    parseJson(content) ||
    (content && typeof content === "object" ? content : null);
  if (!decoded) return [];

  let payload =
    decoded.data && typeof decoded.data === "object" ? decoded.data : decoded;
  // A server-bounded fact wraps oversized provider data as {_comma, value}.
  if (payload?._comma && payload.value && typeof payload.value === "object") {
    payload = payload.value;
  }

  // The remote-MCP `comma_local_search` mock still answers with pre-shaped
  // recommendation items; provider-faithful Composio data is extracted below.
  const legacyItems = Array.isArray(payload?.items)
    ? payload.items.filter(
        (item) =>
          typeof item?.id === "string" &&
          typeof item?.title === "string" &&
          typeof item?.prompt === "string",
      )
    : [];
  const items =
    legacyItems.length > 0
      ? legacyItems
      : itemsFromProviderData(payload, source?.toolkit);

  return items.slice(0, 4);
}

// A deterministic stand-in for the production renderer contract
// (CommaWeb.RecommendationRuntime): each platform's record becomes one compact
// item whose inline link uses the record's own citable URL — Slack permalink,
// Linear url, Calendar htmlLink, Drive webViewLink, or the collector-derived
// webUrl. Raw (uncollected) reads fall back to the same link derivations the
// server collector applies.
function itemsFromProviderData(payload, toolkit) {
  if (!payload || typeof payload !== "object") return [];

  const matches = payload.messages?.matches;
  if (Array.isArray(matches)) return compactItems(matches, slackItem);
  if (Array.isArray(payload.messages) && toolkit !== "slack") {
    return compactItems(payload.messages, gmailItem);
  }
  const linearNodes = payload.issues?.nodes;
  if (Array.isArray(linearNodes)) return compactItems(linearNodes, linearItem);
  if (Array.isArray(payload.values)) {
    return compactItems(payload.values, notionItem);
  }
  const githubDetails = payload.details || payload.notifications;
  if (Array.isArray(githubDetails)) {
    return compactItems(githubDetails, githubItem);
  }
  if (Array.isArray(payload.files))
    return compactItems(payload.files, driveItem);
  if (Array.isArray(payload.items)) {
    return compactItems(payload.items, calendarItem);
  }

  return [];
}

function compactItems(records, build) {
  return records.map(build).filter(Boolean);
}

function textExcerpt(text, max = 140) {
  if (typeof text !== "string") return "";
  const trimmed = text.trim().replace(/\s+/gu, " ");
  return trimmed.length > max ? `${trimmed.slice(0, max - 1)}…` : trimmed;
}

function linkedItem({ id, title, prefix, label, href, secondaryText, prompt }) {
  if (!id || !title || !prompt) return null;
  const parts =
    typeof href === "string" &&
    /^https?:\/\//u.test(href) &&
    typeof label === "string" &&
    label.length > 0
      ? [
          { kind: "markdown", text: prefix },
          { kind: "inline-link", link: { href, label } },
        ]
      : [{ kind: "markdown", text: title }];
  return { id, title, parts, secondaryText: secondaryText || "", prompt };
}

function slackItem(match) {
  if (!match || typeof match !== "object") return null;
  const channel =
    typeof match.channel?.name === "string" && match.channel.name.length > 0
      ? `#${match.channel.name}`
      : match.username
        ? `@${match.username}`
        : "Slack";
  return linkedItem({
    id: `slack-${match.ts || match.iid || channel}`,
    title: `Reply in ${channel}`,
    prefix: "Reply to the thread in ",
    label: channel,
    href: match.permalink,
    secondaryText: textExcerpt(match.text),
    prompt: `Open the Slack thread in ${channel} and draft a concise reply.`,
  });
}

function gmailItem(message) {
  if (!message || typeof message !== "object") return null;
  const id = message.messageId || message.id || message.threadId;
  const sender =
    String(message.sender || "")
      .replace(/<[^>]*>/u, "")
      .trim() || "the sender";
  const subject = message.subject || "this email";
  return linkedItem({
    id: `gmail-${id || subject}`,
    title: `Reply to ${sender}`,
    prefix: `${sender} asks about `,
    label: subject,
    href:
      message.webUrl ||
      (typeof id === "string" && /^[\w-]+$/u.test(id)
        ? `https://mail.google.com/mail/#all/${id}`
        : undefined),
    secondaryText: textExcerpt(message.messageText),
    prompt: `Open the email "${subject}" and draft a concise reply.`,
  });
}

function githubItem(detail) {
  if (!detail || typeof detail !== "object") return null;
  const api = String(detail.subject?.url || "");
  const ref = api.match(/repos\/([\w.-]+)\/([\w.-]+)\/(pulls|issues)\/(\d+)$/u);
  const repo = detail.repository?.full_name || (ref && `${ref[1]}/${ref[2]}`);
  const number = ref?.[4];
  const noun = ref?.[3] === "issues" ? "issue" : "PR";
  const href =
    detail.webUrl ||
    (ref &&
      `https://github.com/${ref[1]}/${ref[2]}/${ref[3] === "issues" ? "issues" : "pull"}/${number}`);
  if (!repo || !number) return null;
  return linkedItem({
    id: `github-${noun}-${number}`,
    title: `Review ${repo} #${number}`,
    prefix: `Review ${repo} `,
    label: `#${number}`,
    href,
    secondaryText: textExcerpt(detail.subject?.title),
    prompt: `Open ${repo} ${noun} #${number} and summarize the latest review activity.`,
  });
}

function linearItem(node) {
  if (!node || typeof node !== "object" || !node.identifier) return null;
  const state = node.state?.name ? node.state.name.toLowerCase() : "open";
  return linkedItem({
    id: `linear-${String(node.identifier).toLowerCase()}`,
    title: `Review ${node.identifier}`,
    prefix: "Review ",
    label: String(node.identifier),
    href: node.url,
    secondaryText: node.title ? `${node.title} is ${state}.` : "",
    prompt: `Open Linear issue ${node.identifier} and summarize its latest status.`,
  });
}

function notionItem(page) {
  if (!page || typeof page !== "object") return null;
  const titleParts = page.properties?.title?.title;
  const title =
    (Array.isArray(titleParts) &&
      titleParts
        .map((part) => part?.plain_text || "")
        .join("")
        .trim()) ||
    "this page";
  const hex =
    typeof page.id === "string" ? page.id.replace(/-/gu, "") : undefined;
  return linkedItem({
    id: `notion-${hex || title}`,
    title: `Review the ${title}`,
    prefix: "Review the ",
    label: title,
    href:
      page.webUrl ||
      page.url ||
      (hex && /^[0-9a-f]{32}$/u.test(hex)
        ? `https://www.notion.so/${hex}`
        : undefined),
    secondaryText: "The page was updated recently.",
    prompt: `Review the latest ${title} and summarize the important changes.`,
  });
}

function calendarItem(event) {
  if (!event || typeof event !== "object" || !event.summary) return null;
  const organizer = event.organizer?.displayName || event.organizer?.email;
  return linkedItem({
    id: `calendar-${event.id || event.summary}`,
    title: `Prepare for ${event.summary}`,
    prefix: "Prepare for ",
    label: event.summary,
    href: event.htmlLink,
    secondaryText: organizer ? `Organized by ${organizer}.` : "",
    prompt: `Open the ${event.summary} event and prepare a short agenda.`,
  });
}

function driveItem(file) {
  if (!file || typeof file !== "object" || !file.name) return null;
  return linkedItem({
    id: `drive-${file.id || file.name}`,
    title: `Review ${file.name}`,
    prefix: "Review ",
    label: file.name,
    href: file.webViewLink || file.webUrl,
    secondaryText: "The document was edited recently.",
    prompt: `Open ${file.name} and summarize today's edits.`,
  });
}

function decodedToolContent(result) {
  const content = result?.content;
  return (
    parseJson(content) ||
    (content && typeof content === "object" ? content : null)
  );
}

// Mirrors CommaWeb.RecommendationSourceCatalog: each production slug is executed
// with recipe-shaped arguments that satisfy its provider contract, instead of
// one `{query}` payload that only a fictional tool would accept.
export const LINEAR_ISSUES_QUERY = `query CommaRecommendationIssues($first: Int!) {
  issues(first: $first) {
    nodes {
      id
      identifier
      title
      url
      priority
      state { name }
      assignee { id name email }
      project { id name }
      labels { nodes { id name } }
    }
  }
}
`;

export function composioRecipeArguments(toolSlug) {
  switch (toolSlug) {
    case "SLACK_SEARCH_FOR_MESSAGES_WITH_QUERY": {
      const yesterday = new Date(Date.now() - 24 * 60 * 60 * 1000);
      return {
        query: `after:${yesterday.toISOString().slice(0, 10)}`,
        count: 20,
        sort: "timestamp",
        sort_dir: "desc",
      };
    }
    case "GMAIL_FETCH_EMAILS":
      return {
        query: "newer_than:1d",
        max_results: 20,
        include_payload: false,
      };
    case "GITHUB_LIST_NOTIFICATIONS_FOR_THE_AUTHENTICATED_USER":
      return { all: false, participating: true, page: 1, per_page: 20 };
    case "LINEAR_RUN_QUERY_OR_MUTATION":
      return {
        query_or_mutation: LINEAR_ISSUES_QUERY,
        variables: { first: 20 },
      };
    case "NOTION_FETCH_DATA":
      return { get_pages: true, page_size: 20 };
    case "GOOGLECALENDAR_EVENTS_LIST": {
      const now = new Date();
      const dayAhead = new Date(now.getTime() + 24 * 60 * 60 * 1000);
      return {
        calendarId: "primary",
        maxResults: 20,
        orderBy: "startTime",
        singleEvents: true,
        timeMin: now.toISOString(),
        timeMax: dayAhead.toISOString(),
      };
    }
    case "GOOGLEDRIVE_LIST_FILES":
      return {
        orderBy: "modifiedTime desc",
        pageSize: 20,
        q: "trashed = false",
      };
    default:
      return { query: "recent activity for the Comma Center briefing" };
  }
}

function composioSourceProgress(messages, source) {
  const list = toolRecordsForTarget(messages, "composio.list_tools").findLast(
    ({ params }) => params.toolkit === source.toolkit,
  );
  if (!list) return { next: "list" };

  const tools = decodedToolContent(list.result)?.tools;
  const toolSlug = Array.isArray(tools) ? tools[0]?.tool_slug : null;
  if (typeof toolSlug !== "string" || toolSlug.length === 0) {
    return { result: list.result };
  }

  const detail = toolRecordsForTarget(messages, "composio.get_tool").findLast(
    ({ params }) => params.tool_slug === toolSlug,
  );
  if (!detail) return { next: "get", toolSlug };

  const execution = toolRecordsForTarget(messages, "composio.execute").findLast(
    ({ params }) =>
      params.tool_slug === toolSlug &&
      params.connected_account_id === source.connectionId,
  );
  if (!execution) return { next: "execute", toolSlug };

  return { result: execution.result };
}

function recommendationItemParts(item, source) {
  if (!Array.isArray(item.parts) || item.parts.length === 0) {
    return [{ kind: "markdown", text: item.title }];
  }

  const parts = item.parts.flatMap((part) => {
    if (part?.kind === "markdown" && typeof part.text === "string") {
      return part.text.length > 0
        ? [{ kind: "markdown", text: part.text }]
        : [];
    }

    if (
      part?.kind === "inline-link" &&
      typeof part.link?.label === "string" &&
      part.link.label.length > 0 &&
      typeof part.link?.href === "string" &&
      /^https?:\/\//.test(part.link.href)
    ) {
      return [
        {
          kind: "inline-link",
          link: {
            href: part.link.href,
            label: part.link.label,
            sourceId: source.connectionId,
          },
        },
      ];
    }

    return [];
  });

  return parts.length > 0 ? parts : [{ kind: "markdown", text: item.title }];
}

function appendSummaryPart(parts, part) {
  if (part.kind === "markdown") {
    const previous = parts.at(-1);
    if (previous?.kind === "markdown") {
      previous.text += part.text;
    } else if (part.text.length > 0) {
      parts.push({ kind: "markdown", text: part.text });
    }
    return;
  }

  parts.push(part);
}

// The briefing body is the ten-second heads-up above the cards, one thought
// per paragraph: each of the first few sources contributes its first item as
// its own short paragraph - the item's lead-in ("Review ", "Dana Wu asks
// about ") followed by the link, where it lives, and a dash aside with the
// why - separated by blank lines. Every other item belongs to the cards.
// Links keep their exact URL, label and sourceId.
const SOURCE_PREPOSITIONS = {
  github: "on",
  googlecalendar: "on",
  googledrive: "on",
};
const BRIEF_PARAGRAPHS = 4;

function lowerFirst(text) {
  return text.length > 0 ? text[0].toLowerCase() + text.slice(1) : text;
}

function asideFor(secondaryText) {
  if (typeof secondaryText !== "string") return "";
  const trimmed = secondaryText.trim().replace(/[.!]+$/u, "");
  return trimmed.length > 0 ? ` — ${lowerFirst(trimmed)}` : "";
}

function placeOf(source) {
  const name = source.appName || source.label;
  const key = String(source.toolkit || source.appId || name || "")
    .toLowerCase()
    .replace(/\s+/gu, "");
  return `${SOURCE_PREPOSITIONS[key] || "in"} ${name}`;
}

// Cards are routines: one per source, keyed by the toolkit so the same card
// keeps its identity from run to run; a second connection of one toolkit is
// suffixed with its connection id. Rows stay one line; the item's secondary
// text (the why) opens the action prompt the row reveals on hover.
export function routineToolkit(source) {
  return String(
    source.toolkit || source.appId || source.appName || source.label,
  )
    .toLowerCase()
    .replace(/\s+/gu, "");
}

// Count every configured source, not just sources with usable facts in this run.
// This makes an account's card id stable when its sibling account is temporarily empty.
export function routineCardId(source, duplicateToolkits) {
  const toolkit = routineToolkit(source);
  return duplicateToolkits.has(toolkit)
    ? `${toolkit}-${source.connectionId}`
    : toolkit;
}

function routineActionPrompt(item) {
  const reason =
    typeof item.secondaryText === "string" ? item.secondaryText.trim() : "";
  return reason.length > 0 ? `${reason} ${item.prompt}` : item.prompt;
}

function recommendationSummary(displayed) {
  const parts = [{ kind: "markdown", text: "Good morning." }];

  displayed.slice(0, BRIEF_PARAGRAPHS).forEach(({ source, items }) => {
    const item = items[0];
    appendSummaryPart(parts, { kind: "markdown", text: "\n\n" });
    recommendationItemParts(item, source).forEach((part) =>
      appendSummaryPart(parts, part),
    );
    appendSummaryPart(parts, {
      kind: "markdown",
      text: ` ${placeOf(source)}${asideFor(item.secondaryText)}.`,
    });
  });

  return parts;
}

function localRecommendationSnapshot(request, sourceResults) {
  const usable = sourceResults
    .map(({ source, result }) => ({
      source,
      items: recommendationItems(result, source),
    }))
    .filter(({ items }) => items.length > 0);
  const missing = sourceResults.filter(
    ({ source, result }) => recommendationItems(result, source).length === 0,
  );
  const displayed = usable.slice(0, 6);
  const toolkitCounts = new Map();
  sourceResults.forEach(({ source }) => {
    const toolkit = routineToolkit(source);
    toolkitCounts.set(toolkit, (toolkitCounts.get(toolkit) || 0) + 1);
  });
  const duplicateToolkits = new Set(
    [...toolkitCounts]
      .filter(([, count]) => count > 1)
      .map(([toolkit]) => toolkit),
  );

  return {
    protocolVersion: 1,
    templateCatalogVersion: 1,
    generatedAt: Date.now(),
    generation: request.generation,
    sourceRevision: request.sourceRevision,
    summary: recommendationSummary(displayed),
    cards: displayed.map(({ source, items }) => {
      const sourceName = source.appName || source.label;
      return {
        id: routineCardId(source, duplicateToolkits),
        template: "text-list@1",
        title: sourceName,
        fallbackText: items.map((item) => item.title).join("; "),
        sourceIds: [source.connectionId],
        footerAction: {
          type: "open_task_form",
          label: `Review ${sourceName} updates`,
          prompt: items[0].prompt,
          requiresConfirmation: false,
        },
        items: items.map((item) => ({
          action: {
            type:
              routineToolkit(source) === "github"
                ? "send_to_comma"
                : "open_task_form",
            label: item.title,
            prompt: routineActionPrompt(item),
            requiresConfirmation: routineToolkit(source) === "github",
          },
          id: item.id,
          parts: recommendationItemParts(item, source),
        })),
      };
    }),
    warnings:
      missing.length > 0 || usable.length > displayed.length
        ? [
            {
              code: "partial_sources",
              message:
                "Some connected sources did not return displayable local mock items.",
              sourceIds: [
                ...missing.map(({ source }) => source.connectionId),
                ...usable
                  .slice(displayed.length)
                  .map(({ source }) => source.connectionId),
              ],
            },
          ]
        : [],
  };
}

function visibleMessage(
  conversationId,
  text,
  extraContent = [],
  extraParams = {},
) {
  if (visibleSendCount >= maxVisibleSends) {
    return {
      kind: "text",
      text: "LOCAL_DEV_GUARD: visible send limit reached",
    };
  }

  visibleSendCount += 1;
  const params = {
    connect_id: "internal",
    conversation_id: conversationId,
    request_id: `local-dev-${requestNumber}`,
    content: [{ type: "text", text }, ...extraContent],
    ...extraParams,
  };

  return toolCall("im_api.internal.send_message", params);
}

function routineContent(input) {
  const sources = input.sources
    .map((source) => {
      const original = {
        appName: source.app,
        label: source.app,
        toolkit: source.app.toLowerCase().replaceAll(" ", ""),
        connectionId: source.source,
      };
      const parts = (item) =>
        recommendationItemParts(item, original).map((part) => {
          if (part.kind === "markdown") return { text: part.text };
          const reference = source.references.find(
            (ref) => ref.url === part.link.href,
          );
          return reference
            ? { reference: reference.id, label: part.link.label }
            : { text: part.link.label };
        });
      return {
        source,
        original,
        parts,
        items: recommendationItems({ content: source.data }, original),
      };
    })
    .filter(({ items }) => items.length > 0)
    .slice(0, 6);
  return {
    title: "Good morning.",
    paragraphs: sources.length
      ? sources.slice(0, 4).map(({ items, parts }) => parts(items[0]))
      : [[{ text: "There is no new work to highlight." }]],
    routines: sources.map(({ source, original, items, parts }) => ({
      source: source.source,
      layout: "text",
      items: items.map((item) => ({
        parts: parts(item),
        action: {
          type:
            original.toolkit === "github" ? "send_to_comma" : "open_task_form",
          label: item.title,
          prompt: routineActionPrompt(item),
        },
      })),
    })),
  };
}

export function decide(body) {
  const messages = body.messages || [];
  const sourceContext =
    latestSourceContext(messages) || latestProviderContext(messages);
  const latestUserText = asText(messages.findLast(isUserTurn)?.content) || "";
  const contentInput = parseJson(latestUserText);
  if (
    contentInput?.contentSchema?.properties?.routines &&
    Array.isArray(contentInput.sources)
  ) {
    return { kind: "text", text: JSON.stringify(routineContent(contentInput)) };
  }
  const context = conversationContext(sourceContext);
  const previousCall = previousToolCall(messages);
  const target = previousCall?.tool || null;
  const asynchronous = latestAsyncToolResult(messages, target);
  const result = asynchronous
    ? parseJson(asynchronous.content)
    : latestToolResult(messages);
  const conversationKind = sourceContextValue(
    sourceContext,
    "conversation_kind",
  );
  const participantRole = sourceContextValue(
    sourceContext,
    "participant_role_label",
  );
  const fromRole = sourceContextValue(sourceContext, "from_role_label");
  const fromActorType = sourceContextValue(sourceContext, "from_actor_type");

  if (target === "recommendation.publish") {
    return { kind: "text", text: "LOCAL_RECOMMENDATION_PUBLISHED" };
  }

  const recommendation =
    recommendationRequest(latestUserText) ||
    scheduledRecommendationRequest(target, result);
  if (recommendation) {
    const sources = recommendationSources(
      recommendation,
      callableTargetTools(body),
    );
    if (sources.length === 0) {
      return {
        kind: "text",
        text: "LOCAL_DEV_ERROR: no callable recommendation source",
      };
    }

    const sourceResults = sources.map((source) => {
      const collected = recommendation.collectedFacts?.find(
        (fact) => fact.sourceId === source.connectionId,
      );

      return {
        source,
        progress: collected
          ? {
              result: {
                status: "completed",
                content: { data: collected.data },
              },
            }
          : source.kind === "composio"
            ? composioSourceProgress(messages, source)
            : {
                result: recommendationSourceResult(
                  messages,
                  `mcp.${source.bindingAlias}.comma_local_search`,
                ),
              },
      };
    });
    const unread = sourceResults.find(({ progress }) => !progress.result);

    if (unread) {
      if (unread.source.kind !== "composio") {
        return toolCall(`mcp.${unread.source.bindingAlias}.comma_local_search`, {
          query: "recent activity for the Comma Center briefing",
          source: unread.source.bindingAlias,
        });
      }

      if (unread.progress.next === "list") {
        return toolCall("composio.list_tools", {
          toolkit: unread.source.toolkit,
          query: "read recent activity for a daily briefing",
          limit: 4,
        });
      }

      if (unread.progress.next === "get") {
        return toolCall("composio.get_tool", {
          tool_slug: unread.progress.toolSlug,
        });
      }

      return toolCall("composio.execute", {
        tool_slug: unread.progress.toolSlug,
        connected_account_id: unread.source.connectionId,
        arguments: composioRecipeArguments(unread.progress.toolSlug),
      });
    }

    const completedSourceResults = sourceResults.map(
      ({ source, progress }) => ({
        source,
        result: progress.result,
      }),
    );

    if (
      completedSourceResults.every(
        ({ source, result: sourceResult }) =>
          recommendationItems(sourceResult, source).length === 0,
      )
    ) {
      return {
        kind: "text",
        text: "LOCAL_DEV_ERROR: recommendation sources returned no usable items",
      };
    }

    return toolCall("recommendation.publish", {
      run_id: recommendation.runId,
      snapshot: localRecommendationSnapshot(
        recommendation,
        completedSourceResults,
      ),
    });
  }

  if (target === "agent.list") {
    const workerId = findWorkerId(result);
    if (!workerId) {
      return {
        kind: "text",
        text: "LOCAL_DEV_ERROR: no worker agent_id returned",
      };
    }

    return toolCall("im_api.internal.task.create", {
      connect_id: "internal",
      agent_id: workerId,
      content: "LOCAL_TASK: 完成本地 Task 链路验证，并回报 LOCAL_TASK_DONE。",
      title: "本地 Task 链路验证",
    });
  }

  if (target === taskListTool) {
    const returnedTasks = Array.isArray(result?.tasks) ? result.tasks : [];
    const tasks = returnedTasks.slice(0, maxInlineTasksPerMessage);
    const moreRemain =
      result?.has_more === true ||
      returnedTasks.length > maxInlineTasksPerMessage;

    if (!context.currentId) {
      return {
        kind: "text",
        text: "LOCAL_DEV_ERROR: current conversation id missing",
      };
    }

    if (
      result?.has_more === true &&
      (typeof result?.next_cursor !== "string" ||
        result.next_cursor.length === 0)
    ) {
      return {
        kind: "text",
        text: `LOCAL_DEV_ERROR: ${taskListTool} has_more is missing next_cursor`,
      };
    }

    if (tasks.length === 0) {
      return visibleMessage(
        context.currentId,
        moreRemain
          ? "当前页没有可展示的内部 Comma 资源，后面仍可能有更多结果。"
          : "没有找到内部 Comma 资源。",
      );
    }

    const extraContent = [];

    for (const [index, task] of tasks.entries()) {
      const ref = task?.task_ref;
      if (
        ref?.type !== "conversation_ref" ||
        typeof ref?.conversation_id !== "string" ||
        ref.conversation_id.length === 0 ||
        typeof ref?.kind !== "string" ||
        ref.kind.length === 0
      ) {
        return {
          kind: "text",
          text: `LOCAL_DEV_ERROR: ${taskListTool} result is missing task_ref`,
        };
      }

      if (index > 0) extraContent.push({ type: "text", text: "\n- " });
      extraContent.push(ref);
      extraContent.push({
        type: "text",
        text: `（${task.status || "unknown"}）`,
      });
    }
    if (moreRemain) {
      extraContent.push({
        type: "text",
        text: "\n后面仍可能有更多结果；需要时可继续读取 next_cursor。",
      });
    }
    return visibleMessage(
      context.currentId,
      "找到以下内部 Comma 资源：\n- ",
      extraContent,
    );
  }

  if (target === "im_api.internal.task.create") {
    const taskConversationId =
      deepFind(
        result,
        (value) => typeof value === "string" && value.startsWith("cnv1_"),
      ) || context.ids.find((id) => id !== context.currentId);

    if (!context.currentId || !taskConversationId) {
      return {
        kind: "text",
        text: "LOCAL_DEV_ERROR: task or current conversation id missing",
      };
    }

    return visibleMessage(context.currentId, "任务已经交给本地 Worker。", [
      {
        type: "conversation_ref",
        conversation_id: taskConversationId,
        kind: "agent_task",
        presentation: "inline",
      },
    ]);
  }

  if (target === "im_api.internal.update_conversation") {
    return { kind: "text", text: "LOCAL_RUNTIME_TURN_COMPLETE" };
  }

  if (target === "im_api.internal.send_message") {
    return { kind: "text", text: "LOCAL_RUNTIME_TURN_COMPLETE" };
  }

  if (target === "im_api.telegram.send_message") {
    return { kind: "text", text: "LOCAL_TELEGRAM_TURN_COMPLETE" };
  }

  const taskConversationId = context.currentId;

  if (conversationKind === "agent_task") {
    if (
      (participantRole === "delegator" || participantRole === "router") &&
      fromRole === "worker" &&
      taskConversationId
    ) {
      return toolCall("im_api.internal.update_conversation", {
        connect_id: "internal",
        conversation_id: taskConversationId,
        status: "ready_for_review",
      });
    }

    if (
      participantRole === "worker" &&
      fromRole !== "worker" &&
      taskConversationId
    ) {
      return visibleMessage(
        taskConversationId,
        "LOCAL_TASK_DONE：本地 Worker 已完成任务。",
      );
    }

    // Never turn an actor-to-actor Task delivery into an ordinary Chat reply.
    // This is the final guard against a local Worker replying to its own output.
    return { kind: "text", text: "LOCAL_RUNTIME_TURN_COMPLETE" };
  }

  if (/LOCAL_CREATE_TASK|创建任务/i.test(latestUserText)) {
    return toolCall("agent.list", { limit: 20 });
  }

  const pendingTaskList = pendingTaskListContinuation(messages);
  if (pendingTaskList && isTaskListContinuationRequest(latestUserText)) {
    return toolCall(taskListTool, {
      connect_id: "internal",
      limit: maxInlineTasksPerMessage,
      cursor: pendingTaskList.cursor,
    });
  }

  const listRequest = taskListRequest(latestUserText);
  if (listRequest) {
    return toolCall(taskListTool, {
      connect_id: "internal",
      limit: maxInlineTasksPerMessage,
      ...listRequest,
    });
  }

  if (sourceContextValue(sourceContext, "provider") === "telegram") {
    const connectId = sourceContextValue(sourceContext, "connect_id");
    const chatId = sourceContextValue(sourceContext, "chat_id");

    if (!connectId || !chatId) {
      return {
        kind: "text",
        text: "LOCAL_DEV_ERROR: Telegram source target is incomplete",
      };
    }

    return toolCall("im_api.telegram.send_message", {
      connect_id: connectId,
      chat_id: chatId,
      text: "LOCAL_CHAT_OK：Comma → Salix → Group Router 本地链路已响应。",
    });
  }

  if (conversationKind === "user_chat" && fromActorType === "user") {
    return visibleMessage(
      context.currentId,
      "LOCAL_CHAT_OK：Comma → Salix → Group Router 本地链路已响应。",
    );
  }

  if (context.currentId) {
    return visibleMessage(
      context.currentId,
      "LOCAL_CHAT_OK：Comma → Salix → Group Router 本地链路已响应。",
    );
  }

  return { kind: "text", text: "LOCAL_DEV_MOCK_READY" };
}

export function resetMockState() {
  requestNumber = 0;
  visibleSendCount = 0;
}

function textDeltas(text) {
  const characters = Array.from(text);
  const deltas = [];

  for (
    let index = 0;
    index < characters.length;
    index += streamedTextDeltaMaxCodePoints
  ) {
    deltas.push(
      characters.slice(index, index + streamedTextDeltaMaxCodePoints).join(""),
    );
  }

  return deltas;
}

function writeSseFrame(response, delta) {
  response.write(`data: ${JSON.stringify({ choices: [{ delta }] })}\n\n`);
}

function endSseAfterDelay(response, delayMs) {
  setTimeout(() => {
    if (response.destroyed || response.writableEnded) return;
    response.end("data: [DONE]\n\n");
  }, delayMs);
}

function writeSse(response, decision, textDeltaIntervalMs) {
  response.writeHead(200, {
    "content-type": "text/event-stream; charset=utf-8",
    "cache-control": "no-cache",
    connection: "keep-alive",
  });

  if (decision.kind === "tool") {
    const writeToolCall = () => {
      if (response.destroyed || response.writableEnded) return;

      writeSseFrame(response, {
        ...(!decision.text ? { role: "assistant", content: null } : {}),
        tool_calls: [
          {
            index: 0,
            id: decision.id,
            type: "function",
            function: {
              name: decision.name,
              arguments: JSON.stringify(decision.args),
            },
          },
        ],
      });
      response.end("data: [DONE]\n\n");
    };

    const deltas = textDeltas(decision.text || "");
    if (deltas.length === 0) {
      writeToolCall();
      return;
    }

    let index = 0;
    const writeNext = () => {
      if (response.destroyed || response.writableEnded) return;

      writeSseFrame(response, {
        ...(index === 0 ? { role: "assistant" } : {}),
        content: deltas[index],
      });
      index += 1;

      if (index < deltas.length) {
        setTimeout(writeNext, textDeltaIntervalMs);
      } else {
        setTimeout(writeToolCall, textDeltaIntervalMs);
      }
    };

    writeNext();
    return;
  }

  const deltas = textDeltas(decision.text);
  if (deltas.length === 0) {
    writeSseFrame(response, { role: "assistant", content: "" });
    endSseAfterDelay(response, textDeltaIntervalMs);
    return;
  }

  let index = 0;
  const writeNext = () => {
    if (response.destroyed || response.writableEnded) return;

    writeSseFrame(response, {
      ...(index === 0 ? { role: "assistant" } : {}),
      content: deltas[index],
    });
    index += 1;

    if (index < deltas.length) {
      setTimeout(writeNext, textDeltaIntervalMs);
    } else {
      endSseAfterDelay(response, textDeltaIntervalMs);
    }
  };

  writeNext();
}

function writeJson(response, decision) {
  const message = {
    role: "assistant",
    content: decision.text || null,
  };

  if (decision.kind === "tool") {
    message.tool_calls = [
      {
        id: decision.id,
        type: "function",
        function: {
          name: decision.name,
          arguments: JSON.stringify(decision.args),
        },
      },
    ];
  }

  response.writeHead(200, { "content-type": "application/json" });
  response.end(
    JSON.stringify({
      choices: [
        {
          message,
          finish_reason: decision.kind === "tool" ? "tool_calls" : "stop",
        },
      ],
    }),
  );
}

export function createMockServer({
  logPath,
  textDeltaIntervalMs = streamedTextDeltaIntervalMs,
} = {}) {
  const requestLogPath =
    logPath || process.env.LOG_PATH || "/tmp/comma-local-llm-requests.jsonl";
  const normalizedTextDeltaIntervalMs =
    Number.isFinite(textDeltaIntervalMs) && textDeltaIntervalMs >= 0
      ? textDeltaIntervalMs
      : streamedTextDeltaIntervalMs;

  return http.createServer((request, response) => {
    if (request.method === "GET" && request.url === "/health") {
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify({ status: "ok" }));
      return;
    }

    if (request.method !== "POST" || request.url !== "/chat/completions") {
      response.writeHead(404);
      response.end("not found");
      return;
    }

    let raw = "";
    request.setEncoding("utf8");
    request.on("data", (chunk) => {
      raw += chunk;
    });
    request.on("end", () => {
      requestNumber += 1;

      try {
        const body = JSON.parse(raw);
        const decision = settleTerminalText(body, decide(body));
        fs.appendFileSync(
          requestLogPath,
          `${JSON.stringify({
            requestNumber,
            at: new Date().toISOString(),
            body,
            decision,
          })}\n`,
        );

        if (body.stream)
          writeSse(response, decision, normalizedTextDeltaIntervalMs);
        else writeJson(response, decision);
      } catch (error) {
        fs.appendFileSync(
          requestLogPath,
          `${JSON.stringify({ requestNumber, error: String(error), raw })}\n`,
        );
        response.writeHead(400, { "content-type": "application/json" });
        response.end(JSON.stringify({ error: String(error) }));
      }
    });
  });
}

function isMainModule() {
  return Boolean(
    process.argv[1] &&
    fileURLToPath(import.meta.url) === path.resolve(process.argv[1]),
  );
}

if (isMainModule()) {
  const port = Number(process.env.PORT || 43123);
  createMockServer().listen(port, "0.0.0.0", () => {
    console.log(`Comma local mock LLM listening on ${port}`);
  });
}

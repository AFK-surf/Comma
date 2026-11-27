import {
  classifyCftShadowFlip,
  type CftShadowFlipCategory,
  type CftTriageObservation,
} from "./contracts";
import { extractCftDiversityKeys, type CftScenarioPayload } from "./dataset";
import {
  deterministicCftAIsCandidate,
  formatCftScenarioForJudge,
  type CftPairwiseWinner,
} from "./evaluation";

export interface CftBlindReviewPairInput {
  id: string;
  tags: readonly string[];
  payload: CftScenarioPayload;
  baseline: CftTriageObservation;
  candidate: CftTriageObservation;
  llmJudge?: {
    winner: CftPairwiseWinner;
    consistent: boolean;
    rationale: string;
  };
}

export interface CftBlindReviewSummary {
  baselineRevision: string;
  candidateRevision: string;
  model: string;
  totalItems: number;
  baselineIntervened: number;
  candidateIntervened: number;
  baselineReplied: number;
  candidateReplied: number;
  candidateWins: number;
  baselineWins: number;
  ties: number;
  swapConsistencyPct: number;
}

export interface CftBlindReviewDiversityOptions {
  includeBothSilent?: boolean;
  deduplicate?: boolean;
  maxPerThread?: number;
  maxPerRunId?: number;
  maxPerTemplate?: number;
  maxPerChannel?: number;
}

export interface BlindedCftCardPayload {
  id: string;
  layer: CftScenarioPayload["layer"];
  tags: readonly string[];
  contextText: string;
  flipType: CftShadowFlipCategory;
  aIsCandidate: boolean;
  A: CftTriageObservation;
  B: CftTriageObservation;
  collapsedCount: number;
  collapsedIds: string[];
  llmJudge?: CftBlindReviewPairInput["llmJudge"];
}

export function buildBlindedCftReviewPayload(
  pairs: readonly CftBlindReviewPairInput[],
  optionsOrIncludeBothSilent: boolean | CftBlindReviewDiversityOptions = false
): BlindedCftCardPayload[] {
  const opts: CftBlindReviewDiversityOptions =
    typeof optionsOrIncludeBothSilent === "boolean"
      ? { includeBothSilent: optionsOrIncludeBothSilent, deduplicate: true }
      : optionsOrIncludeBothSilent;

  const includeBothSilent = opts.includeBothSilent === true;
  const deduplicate = opts.deduplicate !== false;
  const maxPerThread = opts.maxPerThread ?? 1;
  const maxPerRunId = opts.maxPerRunId ?? 1;
  const maxPerTemplate = opts.maxPerTemplate ?? 1;
  const maxPerChannel = opts.maxPerChannel ?? 2;

  const cards: BlindedCftCardPayload[] = [];
  const byRun = new Map<string, BlindedCftCardPayload>();
  const byThread = new Map<string, BlindedCftCardPayload[]>();
  const byTemplate = new Map<string, BlindedCftCardPayload[]>();
  const byChannel = new Map<string, BlindedCftCardPayload[]>();

  for (const pair of pairs) {
    const flipType = classifyCftShadowFlip(pair.baseline, pair.candidate);
    if (flipType === "both_silent_no_delegation" && !includeBothSilent) continue;

    if (deduplicate) {
      const keys = extractCftDiversityKeys(pair.payload);
      const runOwner = maxPerRunId > 0 ? byRun.get(keys.runKey) : undefined;
      if (runOwner) {
        runOwner.collapsedCount += 1;
        runOwner.collapsedIds.push(pair.id);
        continue;
      }

      const threadGroup = keys.threadKey ? byThread.get(keys.threadKey) : undefined;
      if (threadGroup && threadGroup.length >= maxPerThread) {
        const rep = threadGroup[0]!;
        rep.collapsedCount += 1;
        rep.collapsedIds.push(pair.id);
        continue;
      }

      const templateGroup = byTemplate.get(keys.templateKey);
      if (templateGroup && templateGroup.length >= maxPerTemplate) {
        const rep = templateGroup[0]!;
        rep.collapsedCount += 1;
        rep.collapsedIds.push(pair.id);
        continue;
      }

      const channelGroup = keys.channelKey ? byChannel.get(keys.channelKey) : undefined;
      if (channelGroup && channelGroup.length >= maxPerChannel) {
        const rep = channelGroup[channelGroup.length - 1]!;
        rep.collapsedCount += 1;
        rep.collapsedIds.push(pair.id);
        continue;
      }

      const aIsCandidate = deterministicCftAIsCandidate(pair.id);
      const card: BlindedCftCardPayload = {
        id: pair.id,
        layer: pair.payload.layer,
        tags: pair.tags,
        contextText: formatCftScenarioForJudge(pair.payload).slice(0, 2600),
        flipType,
        aIsCandidate,
        A: aIsCandidate ? pair.candidate : pair.baseline,
        B: aIsCandidate ? pair.baseline : pair.candidate,
        collapsedCount: 0,
        collapsedIds: [],
        ...(pair.llmJudge ? { llmJudge: pair.llmJudge } : {}),
      };
      cards.push(card);

      byRun.set(keys.runKey, card);
      if (keys.threadKey) {
        const list = byThread.get(keys.threadKey) ?? [];
        list.push(card);
        byThread.set(keys.threadKey, list);
      }
      const tmplList = byTemplate.get(keys.templateKey) ?? [];
      tmplList.push(card);
      byTemplate.set(keys.templateKey, tmplList);
      if (keys.channelKey) {
        const chList = byChannel.get(keys.channelKey) ?? [];
        chList.push(card);
        byChannel.set(keys.channelKey, chList);
      }
      continue;
    }

    const aIsCandidate = deterministicCftAIsCandidate(pair.id);
    cards.push({
      id: pair.id,
      layer: pair.payload.layer,
      tags: pair.tags,
      contextText: formatCftScenarioForJudge(pair.payload).slice(0, 2600),
      flipType,
      aIsCandidate,
      A: aIsCandidate ? pair.candidate : pair.baseline,
      B: aIsCandidate ? pair.baseline : pair.candidate,
      collapsedCount: 0,
      collapsedIds: [],
      ...(pair.llmJudge ? { llmJudge: pair.llmJudge } : {}),
    });
  }
  return cards;
}

export function renderCftBlindReviewHtml(
  summary: CftBlindReviewSummary,
  pairs: readonly CftBlindReviewPairInput[],
  optionsOrIncludeBothSilent: boolean | CftBlindReviewDiversityOptions = false
): string {
  const opts: CftBlindReviewDiversityOptions =
    typeof optionsOrIncludeBothSilent === "boolean"
      ? { includeBothSilent: optionsOrIncludeBothSilent, deduplicate: true }
      : optionsOrIncludeBothSilent;

  const diverseItems = buildBlindedCftReviewPayload(pairs, {
    ...opts,
    deduplicate: true,
  });
  const rawItems = buildBlindedCftReviewPayload(pairs, {
    ...opts,
    deduplicate: false,
  });
  const defaultDiversified = opts.deduplicate !== false;
  const collapsedTotal = Math.max(rawItems.length - diverseItems.length, 0);
  const embeddedJson = JSON.stringify({
    summary,
    diverseItems,
    rawItems,
    defaultDiversified,
    collapsedTotal,
  }).replaceAll("</", "<\\/");

  return `<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>CFT Group-Chat Triage · Blind A/B Review</title>
<style>
  :root { --bg:#0f1117; --card:#171a23; --card2:#1d212d; --border:#2a3040; --text:#e8ecf5; --muted:#8f9bb3; --accent:#6c8cff; --green:#3ddc97; --amber:#f5b942; --red:#ff6b6b; }
  * { box-sizing:border-box; }
  body { margin:0; font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif; background:var(--bg); color:var(--text); line-height:1.5; }
  header { position:sticky; top:0; z-index:10; background:rgba(15,17,23,.94); border-bottom:1px solid var(--border); padding:14px 24px; display:flex; flex-wrap:wrap; justify-content:space-between; align-items:center; gap:12px; }
  h1 { margin:0; font-size:17px; }
  .sub { font-size:12px; color:var(--muted); }
  .bar { display:flex; gap:8px; flex-wrap:wrap; align-items:center; }
  button { background:var(--card2); color:var(--text); border:1px solid var(--border); border-radius:8px; padding:7px 12px; font-size:13px; cursor:pointer; }
  button.primary { background:var(--accent); color:#091022; border-color:var(--accent); font-weight:600; }
  button.active { border-color:var(--accent); background:rgba(108,140,255,.22); }
  main { max-width:1160px; margin:0 auto; padding:20px 24px 64px; }
  .card { background:var(--card); border:1px solid var(--border); border-radius:12px; padding:16px; margin-bottom:16px; }
  .meta { display:flex; gap:8px; flex-wrap:wrap; margin-bottom:8px; font-size:12px; color:var(--muted); }
  .pill { padding:2px 8px; border-radius:999px; background:#232838; color:#c8d2ea; font-size:11.5px; }
  .pill.reply { background:rgba(108,140,255,.22); color:#b9c9ff; }
  .pill.reaction { background:rgba(61,220,151,.2); color:#7ef0be; }
  .pill.silence { background:rgba(143,155,179,.2); color:#cbd5e1; }
  .pill.deleg { background:rgba(245,185,66,.22); color:#ffd67a; }
  .pill.cluster { background:rgba(245,185,66,.16); color:#f5b942; border:1px solid rgba(245,185,66,.35); }
  .ctx { background:#12151e; border:1px solid #222736; border-radius:8px; padding:10px 12px; font-size:12.5px; color:#c3cde0; white-space:pre-wrap; max-height:220px; overflow:auto; }
  .grid { display:grid; grid-template-columns:1fr 1fr; gap:12px; margin-top:12px; }
  @media (max-width:800px) { .grid { grid-template-columns:1fr; } }
  .side { background:var(--card2); border:1px solid var(--border); border-radius:10px; padding:12px; }
  .side.picked { border-color:var(--green); }
  .msg { white-space:pre-wrap; font-size:13.5px; margin-top:8px; }
  .extra { margin-top:8px; padding-top:8px; border-top:1px dashed var(--border); font-size:12px; color:var(--muted); white-space:pre-wrap; }
  .tags { display:flex; gap:6px; flex-wrap:wrap; align-items:center; margin-top:10px; }
  .tags-label { font-size:12px; color:var(--muted); margin-right:2px; }
  .tag-btn { font-size:11.5px; padding:4px 9px; border-radius:999px; }
  .tag-btn.on { border-color:var(--amber); background:rgba(245,185,66,.2); color:#ffe09c; }
  .reveal { display:none; margin-top:10px; padding:10px 12px; border-radius:8px; background:rgba(108,140,255,.1); border:1px solid rgba(108,140,255,.3); font-size:12.5px; }
  body.revealed .reveal { display:block; }
</style>
</head>
<body>
<header>
  <div>
    <h1>CFT Group-Chat Triage · Blind A/B Review</h1>
    <div class="sub" id="progress">盲测模式：揭晓前隐藏系统来源与决策方向。</div>
  </div>
  <div class="bar">
    <button id="modeDiverse" class="active">去重精选</button>
    <button id="modeRaw">全部原始</button>
    <button id="filterAll" class="active">All</button>
    <button id="filterUnvoted">Unvoted</button>
    <button id="revealBtn" class="primary">Reveal &amp; Score</button>
    <button id="exportBtn">Export JSON</button>
  </div>
</header>
<main>
  <div id="banner" class="card reveal"></div>
  <div id="list"></div>
</main>
<script>
const DATA = ${embeddedJson};
const STORAGE_KEY = "evalens_cft_triage_blind_ab_v2";
const saved = JSON.parse(localStorage.getItem(STORAGE_KEY) || '{"votes":{},"tags":{}}');
const votes = saved.votes || {};
const itemTags = saved.tags || {};
const QUICK_TAGS = [
  { label: "该闭嘴时闭嘴", hint: "胜出项克制沉默，避免误插嘴或告警刷屏" },
  { label: "该回答时答对了", hint: "胜出项给出有效回答，另一边漏答或没帮上" },
  { label: "有理有据不瞎猜", hint: "胜出项紧扣已有上下文证据，没有编造或过度推论" },
  { label: "简洁自然像同事", hint: "胜出项直接好读，另一边太啰嗦、像客服或说教" },
  { label: "后续跟进更合理", hint: "是否创建或停止定时复查（follow-up / 后台自查）更合理" },
  { label: "两边都不太行", hint: "两边都有明显问题（适合选平局或标记待改进）" },
];
const NEUTRAL_TAG_LABELS = {
  ambient: "普通群消息",
  recheck: "定时复查",
  scheduled_recheck: "定时复查",
  context_extraction: "上下文提炼",
};
let filterMode = "all";
let diversified = DATA.defaultDiversified;

const esc = s => String(s ?? "").replace(/[&<>"]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));
const persist = () => localStorage.setItem(STORAGE_KEY, JSON.stringify({ votes, tags: itemTags }));
const activeItems = () => diversified ? DATA.diverseItems : DATA.rawItems;

window.pick = (id, choice) => { votes[id] = choice; persist(); render(); };
window.toggleTag = (id, tag) => {
  const cur = new Set(itemTags[id] || []);
  if (cur.has(tag)) cur.delete(tag); else cur.add(tag);
  itemTags[id] = [...cur];
  persist();
  render();
};

function renderSide(it, letter) {
  const s = it[letter];
  const badgeClass = s.communicationKind;
  const headerBadge = '<span class="pill ' + badgeClass + '">' + esc(s.communicationKind.toUpperCase()) + (s.silenceReason ? " · " + esc(s.silenceReason) : "") + '</span>';
  const delegBadge = s.delegationCount > 0 ? ' <span class="pill deleg" title="后台派给 Comma 内部 Task Agent 做只读排查，不会私信同事或在群里发消息">后台自查 ×' + s.delegationCount + '</span>' : "";
  const body = s.communicationKind === "reply"
    ? esc(s.replyText || "")
    : s.communicationKind === "reaction"
      ? "<em>Reaction: :" + esc(s.reactionEmoji || "") + ":</em>"
      : "<em>[SILENT] " + esc(s.explanation || s.silenceReason || "") + "</em>";
  const extras = [];
  if (s.delegationTasks && s.delegationTasks.length) {
    extras.push("后台自查任务（派给内部 AI Task Agent，不私信任何人）：\\n" + s.delegationTasks.map(t => "• " + t).join("\\n"));
  }
  if (s.contextCandidates && s.contextCandidates.length) {
    extras.push("Context Candidates:\\n" + s.contextCandidates.map(c => "• [" + c.kind + (c.followUpBasis ? "/" + c.followUpBasis : "") + "] " + c.subject + ": " + c.value).join("\\n"));
  }
  return '<div class="side ' + (votes[it.id] === letter ? "picked" : "") + '">' +
    '<div><strong>Option ' + letter + '</strong> ' + headerBadge + delegBadge + '</div>' +
    '<div class="msg">' + body + '</div>' +
    (extras.length ? '<div class="extra">' + esc(extras.join("\\n\\n")) + '</div>' : '') +
  '</div>';
}

function render() {
  const items = activeItems();
  let cw = 0, bw = 0, ties = 0, voted = 0, agree = 0, compared = 0;
  for (const it of items) {
    const v = votes[it.id];
    if (!v) continue;
    voted++;
    let humanWinner = "tie";
    if (v === "tie") ties++;
    else if ((v === "A" && it.aIsCandidate) || (v === "B" && !it.aIsCandidate)) { cw++; humanWinner = "candidate"; }
    else { bw++; humanWinner = "baseline"; }
    if (it.llmJudge) {
      compared++;
      if (it.llmJudge.winner === humanWinner) agree++;
    }
  }
  document.getElementById("modeDiverse").classList.toggle("active", diversified);
  document.getElementById("modeRaw").classList.toggle("active", !diversified);
  document.getElementById("modeDiverse").textContent = "去重精选 (" + DATA.diverseItems.length + ")";
  document.getElementById("modeRaw").textContent = "全部原始 (" + DATA.rawItems.length + ")";
  document.getElementById("progress").textContent =
    "已评 " + voted + "/" + items.length + (diversified && DATA.collapsedTotal > 0 ? "（已按线程/模板/频道折叠 " + DATA.collapsedTotal + " 条同类样本）" : "") + " · Model: " + DATA.summary.model;
  const pct = (cw + bw) > 0 ? ((cw / (cw + bw)) * 100).toFixed(1) + "%" : "—";
  document.getElementById("banner").innerHTML =
    "<strong>Human Blind Score:</strong> Candidate <strong>" + cw + "W</strong> / " + ties + "T / " + bw + "L (excl. ties: " + pct + ")" +
    (compared > 0 ? " · Human↔LLM Judge exact agreement: " + agree + "/" + compared + " (" + ((agree / compared) * 100).toFixed(0) + "%)" : "") +
    "<div class='sub' style='margin-top:4px'>Baseline: " + esc(DATA.summary.baselineRevision) + " (intervened " + DATA.summary.baselineIntervened + ", replied " + DATA.summary.baselineReplied + ") → Candidate: " + esc(DATA.summary.candidateRevision) + " (intervened " + DATA.summary.candidateIntervened + ", replied " + DATA.summary.candidateReplied + ")</div>";

  const visible = items.filter(it => filterMode === "all" || !votes[it.id]);
  document.getElementById("list").innerHTML = visible.map((it, i) => {
    const activeTags = new Set(itemTags[it.id] || []);
    const layerLabel = it.layer === "worker_participation" ? "Worker 群聊决策" : "Native 评估层";
    const neutralPills = [...new Set((it.tags || []).map(t => NEUTRAL_TAG_LABELS[t]).filter(Boolean))];
    const clusterPill = it.collapsedCount > 0 ? '<span class="pill cluster">+' + it.collapsedCount + ' 条同类已折叠</span>' : '';
    return '<div class="card">' +
      '<div class="meta"><span class="pill">#' + (i + 1) + '</span><span class="pill">' + esc(layerLabel) + '</span>' + neutralPills.map(t => '<span class="pill">' + esc(t) + '</span>').join("") + clusterPill + '<span>' + esc(it.id) + '</span></div>' +
      '<div class="ctx">' + esc(it.contextText) + '</div>' +
      '<div class="grid">' + renderSide(it, "A") + renderSide(it, "B") + '</div>' +
      '<div style="margin-top:10px;display:flex;gap:8px;flex-wrap:wrap">' +
        '<button class="' + (votes[it.id] === "A" ? "active" : "") + '" onclick="pick(\\'' + esc(it.id) + '\\',\\'A\\')">选 A 更好</button>' +
        '<button class="' + (votes[it.id] === "tie" ? "active" : "") + '" onclick="pick(\\'' + esc(it.id) + '\\',\\'tie\\')">差不多 (Tie)</button>' +
        '<button class="' + (votes[it.id] === "B" ? "active" : "") + '" onclick="pick(\\'' + esc(it.id) + '\\',\\'B\\')">选 B 更好</button>' +
      '</div>' +
      '<div class="tags"><span class="tags-label">选择理由（可选，针对胜出项）：</span>' + QUICK_TAGS.map(t => '<button class="tag-btn ' + (activeTags.has(t.label) ? 'on' : '') + '" title="' + esc(t.hint) + '" onclick="toggleTag(\\'' + esc(it.id) + '\\',\\'' + esc(t.label) + '\\')">' + esc(t.label) + '</button>').join("") + '</div>' +
      '<div class="reveal"><strong>A = ' + (it.aIsCandidate ? "Candidate" : "Baseline") + '</strong> · <strong>B = ' + (it.aIsCandidate ? "Baseline" : "Candidate") + '</strong> · flip=<code>' + esc(it.flipType) + '</code>' + (it.tags && it.tags.length ? ' · tags=<code>' + esc(it.tags.join(", ")) + '</code>' : '') + (it.llmJudge ? '<br/>LLM Judge: <strong>' + esc(it.llmJudge.winner) + '</strong> (swapConsistent=' + it.llmJudge.consistent + ') — ' + esc(it.llmJudge.rationale) : '') + '</div>' +
    '</div>';
  }).join("");
}

document.getElementById("modeDiverse").addEventListener("click", () => { diversified = true; render(); });
document.getElementById("modeRaw").addEventListener("click", () => { diversified = false; render(); });
document.getElementById("filterAll").addEventListener("click", () => {
  filterMode = "all";
  document.getElementById("filterAll").classList.add("active");
  document.getElementById("filterUnvoted").classList.remove("active");
  render();
});
document.getElementById("filterUnvoted").addEventListener("click", () => {
  filterMode = "unvoted";
  document.getElementById("filterUnvoted").classList.add("active");
  document.getElementById("filterAll").classList.remove("active");
  render();
});
document.getElementById("revealBtn").addEventListener("click", () => { document.body.classList.toggle("revealed"); render(); });
document.getElementById("exportBtn").addEventListener("click", () => {
  const blob = new Blob([JSON.stringify({ summary: DATA.summary, diversified, votes, tags: itemTags }, null, 2)], { type: "application/json" });
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = "cft-triage-blind-ab-votes.json";
  a.click();
});
render();
</script>
</body>
</html>`;
}

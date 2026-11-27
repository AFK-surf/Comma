import {
  classifyShadowFlip,
  type ProactiveObservation,
  type ShadowFlipCategory,
} from "./contracts";
import type { ProactiveSourceItem } from "./dataset";
import { deterministicAIsCandidate, type PairwiseWinner } from "./evaluation";

export interface BlindReviewPairInput {
  id: string;
  sourceItem: ProactiveSourceItem;
  baseline: ProactiveObservation;
  candidate: ProactiveObservation;
  llmJudge?: {
    winner: PairwiseWinner;
    consistent: boolean;
    rationale: string;
  };
}

export interface BlindReviewSummary {
  baselineRevision: string;
  candidateRevision: string;
  model: string;
  totalItems: number;
  baselineRouted: number;
  candidateRouted: number;
  candidateWins: number;
  baselineWins: number;
  ties: number;
  swapConsistencyPct: number;
}

interface BlindedCardPayload {
  id: string;
  toolkit: string;
  relationship: string;
  title: string;
  excerpt: string;
  screenedAt: string;
  flipType: ShadowFlipCategory;
  aIsCandidate: boolean;
  A: ProactiveObservation;
  B: ProactiveObservation;
  llmJudge?: BlindReviewPairInput["llmJudge"];
}

export function buildBlindedReviewPayload(
  pairs: readonly BlindReviewPairInput[],
  includeBothQuiet = false
): BlindedCardPayload[] {
  const cards: BlindedCardPayload[] = [];
  for (const pair of pairs) {
    const flipType = classifyShadowFlip(pair.baseline, pair.candidate);
    if (flipType === "both_quiet" && !includeBothQuiet) continue;
    const aIsCandidate = deterministicAIsCandidate(pair.id);
    cards.push({
      id: pair.id,
      toolkit: pair.sourceItem.toolkit,
      relationship: pair.sourceItem.relationship,
      title: pair.sourceItem.title,
      excerpt: pair.sourceItem.excerpt.slice(0, 800),
      screenedAt: pair.sourceItem.screenedAt ?? pair.sourceItem.firstSeenAt,
      flipType,
      aIsCandidate,
      A: aIsCandidate ? pair.candidate : pair.baseline,
      B: aIsCandidate ? pair.baseline : pair.candidate,
      ...(pair.llmJudge ? { llmJudge: pair.llmJudge } : {}),
    });
  }
  return cards;
}

export function renderBlindReviewHtml(
  summary: BlindReviewSummary,
  pairs: readonly BlindReviewPairInput[],
  includeBothQuiet = false
): string {
  const items = buildBlindedReviewPayload(pairs, includeBothQuiet);
  const embeddedJson = JSON.stringify({ summary, items }).replaceAll("</", "<\\/");

  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Proactive Shadow Replay Blind A/B Review</title>
<style>
  :root { --bg:#0f1117; --card:#171a23; --card2:#1d212d; --border:#2a3040; --text:#e8ecf5; --muted:#8f9bb3; --accent:#6c8cff; --green:#3ddc97; --amber:#f5b942; --red:#ff6b6b; }
  * { box-sizing:border-box; }
  body { margin:0; font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif; background:var(--bg); color:var(--text); line-height:1.5; }
  header { position:sticky; top:0; z-index:10; background:rgba(15,17,23,.94); border-bottom:1px solid var(--border); padding:14px 24px; display:flex; flex-wrap:wrap; justify-content:space-between; align-items:center; gap:12px; }
  h1 { margin:0; font-size:17px; }
  .sub { font-size:12px; color:var(--muted); }
  button { background:var(--card2); color:var(--text); border:1px solid var(--border); border-radius:8px; padding:7px 12px; font-size:13px; cursor:pointer; }
  button.primary { background:var(--accent); color:#091022; border-color:var(--accent); font-weight:600; }
  button.active { border-color:var(--accent); background:rgba(108,140,255,.22); }
  main { max-width:1120px; margin:0 auto; padding:20px 24px 60px; }
  .card { background:var(--card); border:1px solid var(--border); border-radius:12px; padding:16px; margin-bottom:16px; }
  .grid { display:grid; grid-template-columns:1fr 1fr; gap:12px; margin-top:12px; }
  @media (max-width:780px) { .grid { grid-template-columns:1fr; } }
  .side { background:var(--card2); border:1px solid var(--border); border-radius:10px; padding:12px; }
  .side.picked { border-color:var(--green); }
  .excerpt { background:#12151e; border:1px solid #222736; border-radius:8px; padding:10px; font-size:13px; color:#b9c3d9; white-space:pre-wrap; max-height:140px; overflow:auto; }
  .msg { white-space:pre-wrap; font-size:13.5px; margin-top:8px; }
  .reveal { display:none; margin-top:10px; padding:10px; border-radius:8px; background:rgba(108,140,255,.1); border:1px solid rgba(108,140,255,.3); font-size:12.5px; }
  body.revealed .reveal { display:block; }
</style>
</head>
<body>
<header>
  <div>
    <h1>Proactive Shadow Replay · Blind A/B Review</h1>
    <div class="sub">System identities hidden until reveal.</div>
  </div>
  <div>
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
const votes = JSON.parse(localStorage.getItem("evalens_proactive_blind_ab") || "{}");
const esc = s => String(s ?? "").replace(/[&<>"]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));
window.pick = (id, choice) => {
  votes[id] = choice;
  localStorage.setItem("evalens_proactive_blind_ab", JSON.stringify(votes));
  render();
};
function renderSide(it, letter) {
  const s = it[letter];
  const body = s.outcome === "routed" ? esc(s.message || "") : "<em>[QUIET: " + esc(s.decision) + "]</em>";
  return '<div class="side ' + (votes[it.id] === letter ? "picked" : "") + '"><strong>Option ' + letter + ' (' + esc(s.outcome + ":" + s.decision) + ')</strong><div class="msg">' + body + '</div></div>';
}
function render() {
  let cw = 0, bw = 0, ties = 0;
  for (const it of DATA.items) {
    const v = votes[it.id];
    if (v === "tie") ties++;
    else if ((v === "A" && it.aIsCandidate) || (v === "B" && !it.aIsCandidate)) cw++;
    else if (v) bw++;
  }
  document.getElementById("banner").innerHTML = "<strong>Human Blind Score:</strong> Candidate " + cw + "W / " + ties + "T / " + bw + "L (" + esc(DATA.summary.candidateRevision) + " vs " + esc(DATA.summary.baselineRevision) + ")";
  document.getElementById("list").innerHTML = DATA.items.map((it, i) => (
    '<div class="card">' +
      '<div class="sub">#' + (i + 1) + ' · ' + esc(it.toolkit) + ' · ' + esc(it.relationship) + ' · ' + esc(it.flipType) + '</div>' +
      '<h3>' + esc(it.title) + '</h3>' +
      '<div class="excerpt">' + esc(it.excerpt) + '</div>' +
      '<div class="grid">' + renderSide(it, "A") + renderSide(it, "B") + '</div>' +
      '<div style="margin-top:10px;display:flex;gap:8px">' +
        '<button class="' + (votes[it.id] === "A" ? "active" : "") + '" onclick="pick(\\'' + esc(it.id) + '\\',\\'A\\')">A Better</button>' +
        '<button class="' + (votes[it.id] === "tie" ? "active" : "") + '" onclick="pick(\\'' + esc(it.id) + '\\',\\'tie\\')">Tie</button>' +
        '<button class="' + (votes[it.id] === "B" ? "active" : "") + '" onclick="pick(\\'' + esc(it.id) + '\\',\\'B\\')">B Better</button>' +
      '</div>' +
      '<div class="reveal">A = ' + (it.aIsCandidate ? "Candidate" : "Baseline") + ', B = ' + (it.aIsCandidate ? "Baseline" : "Candidate") + (it.llmJudge ? ' · Judge: ' + esc(it.llmJudge.winner) + ' (' + esc(it.llmJudge.rationale) + ')' : '') + '</div>' +
    '</div>'
  )).join("");
}
document.getElementById("revealBtn").addEventListener("click", () => { document.body.classList.toggle("revealed"); render(); });
document.getElementById("exportBtn").addEventListener("click", () => {
  const blob = new Blob([JSON.stringify({ summary: DATA.summary, votes }, null, 2)], { type: "application/json" });
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = "proactive-blind-ab-votes.json";
  a.click();
});
render();
</script>
</body>
</html>`;
}
